import 'dart:io';

import '../memory_read_exception.dart';
import '../memory_snapshot.dart';

/// `Key:   1234 kB`: the shape of every size line in `smaps_rollup` and
/// `meminfo`. Lines without a `kB` unit (the rollup header, `HugePages_Total`)
/// do not match and are skipped.
final RegExp _kbLine = RegExp(r'^([A-Za-z0-9_()]+):\s+(\d+) kB$');

/// Parses every `Key: N kB` line of a `/proc` memory file into bytes.
Map<String, int> parseProcKbFields(String text) {
  final fields = <String, int>{};
  for (final line in text.split('\n')) {
    final match = _kbLine.firstMatch(line.trim());
    if (match == null) continue;
    fields[match.group(1)!] = int.parse(match.group(2)!) * 1024;
  }
  return fields;
}

/// `Private_Dirty + SwapPss` from the text of `/proc/self/smaps_rollup`.
///
/// Null unless both fields are present. Summing whatever happens to be there
/// would report a plausible number that means something else.
int? anonymousBytesFromSmapsRollup(String text) {
  final fields = parseProcKbFields(text);
  final privateDirty = fields['Private_Dirty'];
  final swapPss = fields['SwapPss'];
  if (privateDirty == null || swapPss == null) return null;
  return privateDirty + swapPss;
}

/// `MemAvailable` from the text of `/proc/meminfo`, or null if absent.
int? availableBytesFromMeminfo(String text) =>
    parseProcKbFields(text)['MemAvailable'];

/// Reads both values from `/proc`.
///
/// The one documented null: `smaps_rollup` does not exist on kernels older
/// than 4.14, so an absent file means the value is not available here.
/// Anything else is a failed read and throws [MemoryReadException]: a
/// permission or I/O error, a missing `meminfo`, or a file that exists but
/// lacks the field it always carries. The paths are parameters only so tests
/// can point at fixtures.
///
/// The files are read asynchronously and one after the other, so a caller on
/// the UI isolate is not blocked while the kernel walks the page tables. That
/// moves the wait off the isolate; the kernel's own cost is unchanged.
Future<MemorySnapshot> readProcMemorySnapshot({
  String smapsRollupPath = '/proc/self/smaps_rollup',
  String meminfoPath = '/proc/meminfo',
}) async {
  final rollup = await _readProcFile(
    smapsRollupPath,
    absentMeansUnavailable: true,
  );
  final meminfo = (await _readProcFile(
    meminfoPath,
    absentMeansUnavailable: false,
  ))!;
  return MemorySnapshot(
    anonymousBytes: rollup == null
        ? null
        : _require(
            anonymousBytesFromSmapsRollup(rollup),
            smapsRollupPath,
            'Private_Dirty and SwapPss',
          ),
    availableBytes: _require(
      availableBytesFromMeminfo(meminfo),
      meminfoPath,
      'MemAvailable',
    ),
    takenAt: DateTime.now(),
  );
}

/// The file's text; null only when it is absent and that is a documented gap.
///
/// The `await` sits inside the `try`: returning the future un-awaited would let
/// the error escape the handlers below and a missing file would stop mapping to
/// null.
Future<String?> _readProcFile(
  String path, {
  required bool absentMeansUnavailable,
}) async {
  try {
    return await File(path).readAsString();
  } on PathNotFoundException catch (e) {
    if (absentMeansUnavailable) return null;
    throw MemoryReadException('$path does not exist', cause: e);
  } on FileSystemException catch (e) {
    throw MemoryReadException('could not read $path', cause: e);
  }
}

int _require(int? value, String path, String fields) =>
    value ?? (throw MemoryReadException('$path exists but has no $fields'));
