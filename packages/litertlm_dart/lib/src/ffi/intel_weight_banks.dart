// Weight banks the Intel NPU dispatch leaves in the temp directory.
//
// For a bundle whose NPU blobs carry no weights, the dispatch copies the
// bundle's shared weight pool to `<temp>\litert_ov_bank_<16 hex>.bin` during
// the engine create — 5.55 GB for Intel's Gemma 4 12B for Panther Lake, 74.5 MB
// for EmbeddingGemma 2 270m `_Intel_PTL` — under a random name, and deletes it
// only when the engine is destroyed (LiteRT `weight_bank_runtime.cc`). A
// process that exits without closing its model (`exit()`, a kill, a crash)
// leaves the file behind; one evening of runs left 44 GB. (Measured on Panther
// Lake, 2026-10-21: one bank per load, written inside the create; the 12B
// writes none after it, through three sends.)
//
// The dispatch holds no handle on the file once the create has returned — a
// sweep deleted a live 12B's bank, and that engine went on generating
// (Panther Lake, 2026-10-20) — so an open handle cannot tell a live process's
// bank from a dead one's. Each process therefore claims the banks its load
// wrote with a lock file of its own, `<bank>.<pid>.owner`, held open for as
// long as the engine lives. Windows refuses to delete a file another handle
// holds without FILE_SHARE_DELETE, which Dart's `File.open` does not pass, and
// the system closes the handle however the process ends: a lock that deletes
// is the lock of a process that is gone. A bank without a lock (an app on a
// version without locks, the LiteRT-LM CLI, a load whose claim failed) is
// deleted only once the PC has restarted since it was written: before that,
// its process may still be running.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The name the Windows dispatch gives a bank.
final intelWeightBankName = RegExp(r'^litert_ov_bank_[0-9a-f]{16}\.bin$');

/// A lock file: the bank's name, the owner's pid, `.owner`.
final _lockName = RegExp(r'^(litert_ov_bank_[0-9a-f]{16}\.bin)\.\d+\.owner$');

String _nameOf(FileSystemEntity e) => e.uri.pathSegments.last;

/// The directories the dispatch may write a bank to: Dart's
/// `Directory.systemTemp` (GetTempPathW) and, where Windows has it,
/// GetTempPath2W, which the C++ library's `temp_directory_path` may call
/// instead. They differ only for a process running as SYSTEM.
List<Directory> intelWeightBankDirs() {
  final dirs = [Directory.systemTemp];
  if (!Platform.isWindows) return dirs;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  if (!kernel32.providesSymbol('GetTempPath2W')) return dirs;
  final getTempPath2 = kernel32
      .lookupFunction<
        Uint32 Function(Uint32, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>)
      >('GetTempPath2W');
  const capacity = 261; // MAX_PATH + 1, the documented maximum.
  final buf = calloc<Uint16>(capacity);
  try {
    final n = getTempPath2(capacity, buf.cast());
    if (n == 0 || n >= capacity) return dirs;
    final path = buf.cast<Utf16>().toDartString(length: n);
    String norm(String p) =>
        p.replaceAll('/', r'\').replaceFirst(RegExp(r'\\+$'), '').toLowerCase();
    if (norm(path) != norm(dirs.first.path)) dirs.add(Directory(path));
  } finally {
    calloc.free(buf);
  }
  return dirs;
}

/// When Windows last started (now minus GetTickCount64), or null off Windows.
/// A Fast Startup shutdown is not a start: it hibernates the kernel, and the
/// count goes on.
DateTime? windowsBootTime() {
  if (!Platform.isWindows) return null;
  final ticks = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<Uint64 Function(), int Function()>('GetTickCount64')();
  return DateTime.now().subtract(Duration(milliseconds: ticks));
}

/// The banks in [dirs] ([intelWeightBankDirs] by default), by full path; null
/// when a directory cannot be listed, which is printed.
Set<String>? listIntelWeightBanks({List<Directory>? dirs}) {
  final banks = <String>{};
  for (final dir in dirs ?? intelWeightBankDirs()) {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && intelWeightBankName.hasMatch(_nameOf(e))) {
          banks.add(e.path);
        }
      }
    } on FileSystemException catch (e) {
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] Could not list ${dir.path} for Intel NPU '
        'weight banks: $e',
      );
      return null;
    }
  }
  return banks;
}

final class _BankLock {
  _BankLock(this.bank, this.lock, this.handle);

  final String bank;
  final File lock;
  final RandomAccessFile handle;
}

/// The banks one engine's load wrote, each held by this process's open lock
/// file until [release].
class IntelWeightBankClaim {
  IntelWeightBankClaim._(this._locks);

  /// Claims the banks in [after] that are not in [before], the listings
  /// ([listIntelWeightBanks]) taken right before and right after the engine
  /// was created. A bank another process wrote in the same moment is claimed
  /// too: it then outlives its owner until this process releases it, which
  /// is the safe side. A listing that failed (null) claims nothing: the
  /// load's banks are then kept until the next restart, whatever happens to
  /// this process.
  factory IntelWeightBankClaim.newSince(
    Set<String>? before,
    Set<String>? after,
  ) {
    final locks = <_BankLock>[];
    if (before == null || after == null) {
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] The Intel NPU weight banks of this load '
        'are not claimed: a temp directory could not be listed. If the app '
        'exits without closing the model, they stay until the PC restarts.',
      );
      return IntelWeightBankClaim._(locks);
    }
    for (final bank in after.difference(before)) {
      final lock = File('$bank.$pid.owner');
      try {
        // Empty: the name says whose it is, and only the open handle counts.
        locks.add(_BankLock(bank, lock, lock.openSync(mode: FileMode.write)));
      } on FileSystemException catch (e) {
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] Could not claim Intel NPU weight bank '
          '$bank ($e): if the app exits without closing the model, it stays '
          'until the PC restarts.',
        );
      }
    }
    return IntelWeightBankClaim._(locks);
  }

  final List<_BankLock> _locks;

  /// The banks claimed, by full path.
  List<String> get banks => [for (final l in _locks) l.bank];

  /// Closes and deletes the lock files. After the engine is deleted: the
  /// dispatch deletes its bank then, and a bank that outlives it (a failed
  /// delete) goes at the next sweep, its lock being gone.
  void release() {
    for (final l in _locks) {
      try {
        l.handle.closeSync();
      } on FileSystemException {
        // Closed with the process at the latest.
      }
      try {
        l.lock.deleteSync();
      } on FileSystemException {
        // A lock left behind deletes at the next sweep.
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

bool _isKeep(File bank, String? keep) {
  if (keep == null) return false;
  try {
    // Volume and file id on Windows: case, 8.3 names and slashes do not matter.
    return FileSystemEntity.identicalSync(bank.path, keep);
  } on FileSystemException {
    return false;
  }
}

/// Deletes the weight banks in [dirs] ([intelWeightBankDirs] by default)
/// whose owner is gone, and returns how many bytes it freed.
///
/// A bank with lock files is deleted when every one of them deletes: a lock
/// that does not is held by a live process. A bank without one is deleted
/// only when it was last written before [bootedAt] ([windowsBootTime] by
/// default; null keeps every such bank): written by a process that has not
/// claimed it, it may belong to one that is still running. Lock files whose
/// bank is gone are deleted too. [keep] is a bank an app staged itself
/// (`LITERT_OV_WEIGHTS_PATH`), never deleted. [deleteLock] is the delete a
/// lock is tried with: on Windows a held one refuses, the only place the
/// sweep runs.
int sweepStaleIntelWeightBanks({
  List<Directory>? dirs,
  DateTime? Function() bootedAt = windowsBootTime,
  String? keep,
  bool Function(File lock) deleteLock = _tryDelete,
}) {
  final boot = bootedAt();
  var freed = 0;
  for (final dir in dirs ?? intelWeightBankDirs()) {
    freed += _sweep(dir, boot, keep, deleteLock);
  }
  return freed;
}

int _sweep(
  Directory dir,
  DateTime? boot,
  String? keep,
  bool Function(File lock) deleteLock,
) {
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException catch (e) {
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] Could not list ${dir.path} for stale Intel '
      'NPU weight banks: $e',
    );
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
  var orphaned = (count: 0, bytes: 0);
  var unclaimed = (count: 0, bytes: 0);
  final failed = <String>[];
  for (final MapEntry(key: name, value: bank) in banks.entries) {
    final held = locks.remove(name);
    if (_isKeep(bank, keep)) continue;
    final FileStat stat;
    try {
      stat = bank.statSync();
    } on FileSystemException {
      continue; // Gone already.
    }
    if (held != null) {
      // Every lock is tried: the dead owners' ones go either way.
      if (!held.map(deleteLock).toList().every((deleted) => deleted)) {
        continue;
      }
    } else if (boot == null || !stat.modified.isBefore(boot)) {
      continue;
    }
    try {
      bank.deleteSync();
    } on FileSystemException catch (e) {
      failed.add(
        '${bank.path} (${(stat.size / (1 << 30)).toStringAsFixed(2)} GiB): '
        '${e.osError?.message ?? e.message}',
      );
      continue;
    }
    if (held != null) {
      orphaned = (count: orphaned.count + 1, bytes: orphaned.bytes + stat.size);
    } else {
      unclaimed = (
        count: unclaimed.count + 1,
        bytes: unclaimed.bytes + stat.size,
      );
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
    'left by a process that exited without closing its NPU model.',
  );
  report(
    unclaimed,
    'claimed by no process and written before the PC last started.',
  );
  for (final f in failed) {
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] Could not delete the stale Intel NPU '
      'weight bank $f',
    );
  }
  return orphaned.bytes + unclaimed.bytes;
}
