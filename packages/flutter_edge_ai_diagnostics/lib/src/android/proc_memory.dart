import 'dart:convert';
import 'dart:io';

import '../gpu_memory_reading.dart';
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

/// `Private_Clean + Shared_Clean` from the text of `/proc/self/smaps_rollup`:
/// resident clean pages (mapped files, and on some GPU backends GPU driver
/// buffers; see [MemorySnapshot.fileBackedBytes]). Clean anonymous pages can
/// also be included, for example after a read from zram or `MADV_FREE`.
///
/// Null unless both fields are present, for the same reason as
/// [anonymousBytesFromSmapsRollup]. `Pss_File` reports proportional file-backed
/// memory and was added in mainline Linux 5.3; vendor backports may differ.
int? fileBackedBytesFromSmapsRollup(String text) {
  final fields = parseProcKbFields(text);
  final privateClean = fields['Private_Clean'];
  final sharedClean = fields['Shared_Clean'];
  if (privateClean == null || sharedClean == null) return null;
  return privateClean + sharedClean;
}

/// A mapping header line of `/proc/self/smaps`:
/// `start-end perms offset dev inode  path`. The path is the rest of the line,
/// empty for an anonymous mapping. `dotAll`, so a path with a `\r` in it still
/// matches.
final RegExp _smapsHeader = RegExp(
  r'^[0-9a-f]+-[0-9a-f]+\s+\S{4}\s+[0-9a-f]+\s+[0-9a-f]+:[0-9a-f]+\s+\d+\s*(.*)$',
  dotAll: true,
);

final RegExp _smapsField = RegExp(
  r'^(Private_Dirty|Private_Clean|Shared_Clean):\s+(\d+) kB$',
);

/// Whether a mapping's path is the Qualcomm driver's GPU memory. Matched the way
/// AOSP's libmeminfo does: `kgsl-3d0` anywhere in the name, because some
/// kernels may name the mapping `/kgsl-3d0` instead of `/dev/kgsl-3d0` (AOSP
/// added the case for kernel 6.6; a 6.12 Galaxy S26+ still shows
/// `/dev/kgsl-3d0`), and a mapping whose file was unlinked carries a trailing
/// ` (deleted)`.
bool _isKgslMapping(String path) => path.contains('kgsl-3d0');

/// The summed private-dirty and clean bytes of the `kgsl-3d0` mappings.
typedef KgslTotals = ({int privateDirtyBytes, int cleanBytes});

/// Sums `Private_Dirty` and `Private_Clean + Shared_Clean` over the `kgsl-3d0`
/// mappings of `/proc/self/smaps`, or null when the process maps none (headers
/// were read, none is a GPU mapping).
///
/// Throws [FormatException] for anything that would otherwise report a number
/// that means something else: a line that starts like a header but is not one
/// (the end of the mapping before it is then unknown), no header at all, and a
/// GPU mapping without each of the three fields, with one repeated, or with one
/// whose unit is not `kB`. `Shared_Dirty` of these mappings is in neither sum:
/// the same as in `anonymousBytes` and `fileBackedBytes`.
///
/// A hand-written scan, not a regex per line: a Flutter app with a model loaded
/// has thousands of mappings and tens of thousands of lines (about 4,200
/// mappings with a model loaded on a vivo 1933), and only a header line needs
/// the regex.
KgslTotals? kgslTotalsFromSmaps(String text) {
  var headers = 0;
  var found = false;
  var inKgsl = false;
  var seen = 0; // bit 0 Private_Dirty, 1 Private_Clean, 2 Shared_Clean
  var dirty = 0;
  var clean = 0;
  var kgslHeader = '';
  void closeMapping() {
    if (inKgsl && seen != 7) {
      throw FormatException(
        'the kgsl mapping "$kgslHeader" lacks Private_Dirty, Private_Clean or '
        'Shared_Clean',
      );
    }
  }

  final end = text.length;
  var at = 0;
  while (at < end) {
    var next = text.indexOf('\n', at);
    if (next < 0) next = end;
    if (next > at) {
      final c = text.codeUnitAt(at);
      final isHex = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66);
      if (isHex) {
        // A mapping header; field lines start with an upper-case letter.
        final header = _smapsHeader.firstMatch(text.substring(at, next));
        if (header == null) {
          throw FormatException(
            'not a mapping header: ${text.substring(at, next)}',
          );
        }
        closeMapping();
        headers++;
        inKgsl = _isKgslMapping(header.group(1)!);
        if (inKgsl) {
          found = true;
          kgslHeader = text.substring(at, next);
        }
        seen = 0;
      } else if (inKgsl) {
        final key = c == 0x50 /* P */ || c == 0x53 /* S */;
        if (key &&
            (text.startsWith('Private_Dirty:', at) ||
                text.startsWith('Private_Clean:', at) ||
                text.startsWith('Shared_Clean:', at))) {
          final match = _smapsField.firstMatch(text.substring(at, next).trim());
          if (match == null) {
            throw FormatException(
              'unreadable field: ${text.substring(at, next)}',
            );
          }
          final bytes = int.parse(match.group(2)!) * 1024;
          final bit = switch (match.group(1)) {
            'Private_Dirty' => 1,
            'Private_Clean' => 2,
            _ => 4,
          };
          if (seen & bit != 0) {
            throw FormatException(
              'the kgsl mapping "$kgslHeader" repeats ${match.group(1)}',
            );
          }
          seen |= bit;
          if (bit == 1) {
            dirty += bytes;
          } else {
            clean += bytes;
          }
        }
      }
    }
    at = next + 1;
  }
  closeMapping();
  if (headers == 0) throw const FormatException('no mapping header');
  return found ? (privateDirtyBytes: dirty, cleanBytes: clean) : null;
}

/// `MemAvailable` from the text of `/proc/meminfo`, or null if absent.
int? availableBytesFromMeminfo(String text) =>
    parseProcKbFields(text)['MemAvailable'];

/// Reads the three memory values from `/proc`, the same files on Android and
/// Linux.
///
/// An absent `smaps_rollup` means `anonymousBytes` and `fileBackedBytes` are
/// unavailable. Availability depends on kernel support, including backports.
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
    fileBackedBytes: rollup == null
        ? null
        : _require(
            fileBackedBytesFromSmapsRollup(rollup),
            smapsRollupPath,
            'Private_Clean and Shared_Clean',
          ),
    availableBytes: _require(
      availableBytesFromMeminfo(meminfo),
      meminfoPath,
      'MemAvailable',
    ),
    takenAt: DateTime.now(),
  );
}

/// A GPU memory reading from [smapsPath]. When the process maps no `kgsl-3d0`
/// the answer comes from the device: a zero reading if [gpuNodePath] exists
/// (an Adreno phone whose process has not used the GPU yet), null if it does
/// not (no reader for this device, a Mali GPU for one). The node is tested with
/// `existsSync`: `typeSync` and `statSync` report `notFound` for it from an app.
/// `smaps` exists on every Android kernel, so an absent or unparseable one is a
/// failed read, not a null.
///
/// The file is read as Latin-1, so a byte that is not UTF-8 in an unrelated path
/// cannot fail the read; every field this parses is ASCII. The read is
/// asynchronous; decoding and scanning the text run on the calling isolate.
Future<GpuMemoryReading?> readGpuMemoryReading({
  String smapsPath = '/proc/self/smaps',
  String gpuNodePath = '/dev/kgsl-3d0',
}) async {
  final text = (await _readProcFile(
    smapsPath,
    absentMeansUnavailable: false,
    encoding: latin1,
  ))!;
  final KgslTotals? totals;
  try {
    totals = kgslTotalsFromSmaps(text);
  } on FormatException catch (e) {
    throw MemoryReadException(
      'could not parse $smapsPath: ${e.message}',
      cause: e,
    );
  }
  final dirty = totals?.privateDirtyBytes;
  final clean = totals?.cleanBytes;
  if (totals == null && !File(gpuNodePath).existsSync()) return null;
  return GpuMemoryReading(
    source: GpuMemorySource.adrenoKgslMappings,
    inAnonymousBytes: dirty ?? 0,
    inFileBackedBytes: clean ?? 0,
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
  Encoding encoding = utf8,
}) async {
  try {
    return await File(path).readAsString(encoding: encoding);
  } on PathNotFoundException catch (e) {
    if (absentMeansUnavailable) return null;
    throw MemoryReadException('$path does not exist', cause: e);
  } on FileSystemException catch (e) {
    throw MemoryReadException('could not read $path', cause: e);
  }
}

int _require(int? value, String path, String fields) =>
    value ?? (throw MemoryReadException('$path exists but has no $fields'));
