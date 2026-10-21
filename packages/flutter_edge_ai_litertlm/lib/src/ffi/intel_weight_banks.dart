// Weight banks the Intel NPU dispatch leaves in the temp directory.
//
// For a bundle compiled without weights (Gemma 4 12B for Panther Lake), the
// dispatch writes the weights to `%TEMP%\litert_ov_bank_<16 hex>.bin` at every
// load — 5.55 GB for that model, under a random name — and deletes the file
// only when the engine is destroyed (LiteRT `weight_bank_runtime.cc`). A
// process that exits without closing its model (`exit()`, a kill, a crash)
// leaves the file behind; one evening of runs left 44 GB.
//
// The dispatch does not keep the file open once it has read it, so an open
// handle cannot tell a live process's bank from a dead one's: a sweep that
// went by that deleted a live 12B's bank (Panther Lake, 2026-10-20). Each
// process therefore claims the banks its load wrote with a lock file of its
// own, `<bank>.<pid>.owner`, held open for as long as the engine lives.
// Windows refuses to delete a file another handle holds without
// FILE_SHARE_DELETE, which Dart's `File.open` does not pass, and the system
// closes the handle however the process ends: a lock that deletes is the
// lock of a process that is gone.

import 'dart:io';

/// The name the Windows dispatch gives a bank.
final intelWeightBankName = RegExp(r'^litert_ov_bank_[0-9a-f]{16}\.bin$');

/// A lock file: the bank's name, the owner's pid, `.owner`.
final _lockName = RegExp(r'^(litert_ov_bank_[0-9a-f]{16}\.bin)\.\d+\.owner$');

String _nameOf(FileSystemEntity e) => e.uri.pathSegments.last;

/// The banks in [temp] (the system temp directory by default), by file name.
Set<String> listIntelWeightBanks({Directory? temp}) {
  final dir = temp ?? Directory.systemTemp;
  try {
    return {
      for (final e in dir.listSync(followLinks: false))
        if (e is File && intelWeightBankName.hasMatch(_nameOf(e))) _nameOf(e),
    };
  } on FileSystemException {
    return const {};
  }
}

/// The banks one engine's load wrote, each held by this process's open lock
/// file until [release].
class IntelWeightBankClaim {
  IntelWeightBankClaim._(this._locks);

  /// Claims the banks in [temp] that were not in [before], the listing taken
  /// right before the engine was created. A bank another process wrote in
  /// the same moment is claimed too: it then outlives its owner until this
  /// process releases it, which is the safe side.
  factory IntelWeightBankClaim.newSince(Set<String> before, {Directory? temp}) {
    final dir = temp ?? Directory.systemTemp;
    final locks = <(File, RandomAccessFile)>[];
    for (final name in listIntelWeightBanks(temp: dir).difference(before)) {
      final lock = File('${dir.path}${Platform.pathSeparator}$name.$pid.owner');
      try {
        final raf = lock.openSync(mode: FileMode.write)
          ..writeStringSync('$pid\n');
        locks.add((lock, raf));
      } on FileSystemException catch (e) {
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] Could not claim Intel NPU weight bank '
          '$name ($e): another process may delete it after ten minutes.',
        );
      }
    }
    return IntelWeightBankClaim._(locks);
  }

  final List<(File, RandomAccessFile)> _locks;

  /// The banks claimed, by file name.
  List<String> get banks => [
    for (final (lock, _) in _locks)
      _lockName.firstMatch(_nameOf(lock))!.group(1)!,
  ];

  /// Closes and deletes the lock files. After the engine is deleted: the
  /// dispatch deletes its bank then, and a bank that outlives it (a failed
  /// delete) is left to the next sweep's age rule.
  void release() {
    for (final (lock, raf) in _locks) {
      try {
        raf.closeSync();
        lock.deleteSync();
      } on FileSystemException {
        // Gone already; a lock left behind deletes at the next sweep.
      }
    }
    _locks.clear();
  }
}

bool _tryDelete(File f) {
  try {
    f.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Deletes the weight banks in [temp] (the system temp directory by default)
/// whose owner is gone, and returns how many bytes it freed.
///
/// A bank with lock files is deleted when every one of them deletes: a lock
/// that does not is held by a live process. A bank without one was written
/// by a load that failed, or by an app on a version of this package without
/// locks; it is deleted once it is older than [minAge], which also spares a
/// load still in progress, before its claim. Lock files whose bank is gone
/// are deleted too. [keep] is a bank an app staged itself
/// (`LITERT_OV_WEIGHTS_PATH`), never deleted. [deleteLock] is the delete a
/// lock is tried with: on Windows a held one refuses, the only place the
/// sweep runs.
int sweepStaleIntelWeightBanks({
  Directory? temp,
  DateTime? now,
  Duration minAge = const Duration(minutes: 10),
  String? keep,
  bool Function(File lock) deleteLock = _tryDelete,
}) {
  final dir = temp ?? Directory.systemTemp;
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return 0;
  }
  final banks = <String, File>{};
  final locks = <String, List<File>>{};
  for (final e in entries) {
    if (e is! File) continue;
    final name = _nameOf(e);
    if (intelWeightBankName.hasMatch(name)) {
      banks[name] = e;
    } else if (_lockName.firstMatch(name) case final m?) {
      (locks[m.group(1)!] ??= []).add(e);
    }
  }
  final keepPath = keep == null ? null : File(keep).absolute.path;
  var orphaned = (count: 0, bytes: 0);
  var unclaimed = (count: 0, bytes: 0);
  for (final MapEntry(key: name, value: bank) in banks.entries) {
    final held = locks.remove(name);
    if (bank.absolute.path == keepPath) continue;
    try {
      final stat = bank.statSync();
      if (held != null) {
        // Every lock is tried: the dead owners' ones go either way.
        if (!held.map(deleteLock).toList().every((deleted) => deleted)) {
          continue;
        }
        bank.deleteSync();
        orphaned = (
          count: orphaned.count + 1,
          bytes: orphaned.bytes + stat.size,
        );
      } else {
        if (stat.modified.isAfter(cutoff)) continue;
        bank.deleteSync();
        unclaimed = (
          count: unclaimed.count + 1,
          bytes: unclaimed.bytes + stat.size,
        );
      }
    } on FileSystemException {
      // Gone already, or open in another process right now.
    }
  }
  // Locks whose bank no longer exists.
  for (final lock in locks.values.expand((l) => l)) {
    deleteLock(lock);
  }
  // A release build is where 44 GB of temp files get noticed.
  void report(({int count, int bytes}) n, String why) {
    if (n.count == 0) return;
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] Deleted ${n.count} Intel NPU weight '
      'bank${n.count == 1 ? '' : 's'} '
      '(${(n.bytes / (1 << 30)).toStringAsFixed(2)} GiB) from ${dir.path}: '
      '$why',
    );
  }

  report(
    orphaned,
    'left by a process that exited without closing its NPU '
    'model.',
  );
  report(
    unclaimed,
    'claimed by no process and older than ${minAge.inMinutes} minutes '
    '(a failed load, or an app on a version without weight-bank locks).',
  );
  return orphaned.bytes + unclaimed.bytes;
}
