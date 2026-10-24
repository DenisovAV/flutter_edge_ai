// The native reader of `LiteRtLmBundleInfo`: the container header, then the
// `LiteRtStamp` of each `TFLiteModel` section — a few hundred bytes each, never
// the sections themselves, so a multi-gigabyte bundle is read in milliseconds.

import 'dart:io';
import 'dart:typed_data';

import '../embedding/litertlm_npu_target.dart' show readLiteRtLmSectionStamps;
import 'litertlm_bundle_info.dart';

/// Larger than any header seen (a few KB); a bigger value is a corrupt file,
/// not one to read into memory.
const _maxHeaderBytes = 1 << 20;

/// What the `.litertlm` file at [path] says about itself: its container
/// version, system metadata and sections, each `TFLiteModel` section with the
/// NPU it was compiled for. Reads the header and a few hundred bytes per
/// compiled section, never the weights.
///
/// A file shorter than its sections (a download that stopped early) is read
/// as far as it goes: [LiteRtLmBundleInfo.isComplete] is false, and the
/// sections past its end carry no NPU target.
///
/// Throws [FileSystemException] when the file cannot be opened, and
/// [LiteRtLmBundleException] when it is not a `.litertlm` container
/// ([LiteRtLmBundleProblem.notLitertlm]), is of a container version this
/// package does not read ([LiteRtLmBundleProblem.unsupportedVersion]), ends
/// inside its own header ([LiteRtLmBundleProblem.incomplete]), or has a header
/// or compiler stamp out of range ([LiteRtLmBundleProblem.malformed]).
Future<LiteRtLmBundleInfo> readLiteRtLmBundleInfo(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    final preamble = await _read(file, 0, length < 32 ? length : 32);
    final version = litertlmContainerVersion(preamble, path: path);
    final low = ByteData.sublistView(preamble).getUint32(24, Endian.little);
    final high = ByteData.sublistView(preamble).getUint32(28, Endian.little);
    final headerEnd = high * 0x100000000 + low;
    if (high != 0 || headerEnd < 32 || headerEnd - 32 > _maxHeaderBytes) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.malformed,
        '$path: the .litertlm header end $headerEnd is out of range',
        path: path,
      );
    }
    if (headerEnd > length) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.incomplete,
        '$path is $length bytes and ends inside its own header '
        '($headerEnd bytes): the download is incomplete',
        path: path,
      );
    }
    final header = await _read(file, 32, headerEnd - 32);
    // Parsed twice: once for the section ranges, then with their stamps. The
    // header is a few KB.
    final ranges = parseLitertlmHeader(
      header,
      version: version,
      fileLength: length,
      path: path,
    ).sections.where((s) => s.dataType == 'TFLiteModel');
    final Map<(int, int), LiteRtLmNpuTarget?> stamps;
    try {
      stamps = await readLiteRtLmSectionStamps(file, length, [
        for (final section in ranges) (section.begin, section.end),
      ]);
    } on Object catch (e) {
      if (e is! FormatException && e is! RangeError) rethrow;
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.malformed,
        '$path: a compiled section could not be read ($e)',
        path: path,
      );
    }
    final targets = stamps.values.whereType<LiteRtLmNpuTarget>().toSet();
    if (targets.length > 1) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.malformed,
        '$path has sections compiled for ${targets.join(' and for ')}',
        path: path,
      );
    }
    return parseLitertlmHeader(
      header,
      version: version,
      fileLength: length,
      npuTargets: stamps,
      path: path,
    );
  } finally {
    await file.close();
  }
}

Future<Uint8List> _read(RandomAccessFile file, int position, int count) async {
  await file.setPosition(position);
  return file.read(count);
}
