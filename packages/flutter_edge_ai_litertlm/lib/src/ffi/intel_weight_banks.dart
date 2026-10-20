// Weight banks the Intel NPU dispatch leaves in the temp directory.
//
// For a bundle compiled without weights (Gemma 4 12B for Panther Lake), the
// dispatch writes the weights to `%TEMP%\litert_ov_bank_<16 hex>.bin` at every
// load — 5.55 GB for that model — and deletes the file only when the engine
// is destroyed (LiteRT `weight_bank_runtime.cc`). A process that exits without
// closing its model (`exit()`, a kill, a crash) leaves the file behind; one
// evening of runs left 44 GB.

import 'dart:io';

/// The name the Windows dispatch gives a bank.
final intelWeightBankName = RegExp(r'^litert_ov_bank_[0-9a-f]{16}\.bin$');

/// Deletes the weight banks in [temp] (the system temp directory by default)
/// that no process holds, and returns how many bytes it freed.
///
/// A bank in use cannot be deleted on Windows (the NPU plugin maps it), so a
/// failed delete is a bank someone holds and is skipped. A bank written in
/// the last [minAge] is skipped too: between the dispatch's write and its
/// map, another process's bank is held by nothing. [keep] is a bank an app
/// staged itself (`LITERT_OV_WEIGHTS_PATH`), never deleted.
int sweepStaleIntelWeightBanks({
  Directory? temp,
  DateTime? now,
  Duration minAge = const Duration(minutes: 10),
  String? keep,
}) {
  final dir = temp ?? Directory.systemTemp;
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  var freed = 0;
  var count = 0;
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return 0;
  }
  for (final entry in entries) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    if (!intelWeightBankName.hasMatch(name)) continue;
    if (keep != null && File(keep).absolute.path == entry.absolute.path) {
      continue;
    }
    try {
      final stat = entry.statSync();
      if (stat.modified.isAfter(cutoff)) continue;
      entry.deleteSync();
      freed += stat.size;
      count++;
    } on FileSystemException {
      // Held by a live process, or gone already.
    }
  }
  if (count > 0) {
    // A release build is where 44 GB of temp files get noticed.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] Deleted $count Intel NPU weight '
      'bank${count == 1 ? '' : 's'} (${(freed / (1 << 30)).toStringAsFixed(2)} '
      'GiB) from ${dir.path}: left by a process that exited without closing '
      'its NPU model.',
    );
  }
  return freed;
}
