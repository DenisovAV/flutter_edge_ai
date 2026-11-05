// The native reader of `LiteRtLmBundleInfo`: the container header, then the
// `LiteRtStamp` of each `TFLiteModel` section — a few hundred bytes each, never
// the sections themselves, so a multi-gigabyte bundle is read in milliseconds.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../embedding/litertlm_npu_target.dart'
    show
        readLiteRtLmLinearAttentionState,
        readLiteRtLmPrefillLengths,
        readLiteRtLmSectionStamps;
import '../litertlm_bundle_sampler.dart'
    show executorMetadataHasLinearAttention;
import 'litertlm_bundle_info.dart';

/// Larger than any header seen (a few KB); a bigger value is a corrupt file,
/// not one to read into memory.
const _maxHeaderBytes = 1 << 20;

/// Larger than any executor metadata seen (a few hundred bytes); a bigger
/// value is a corrupt file.
const _maxExecutorMetadataBytes = 1 << 20;

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

/// The prefill lengths of the `.litertlm` LLM at [path]: those of its main
/// model section (`tf_lite_prefill_decode`), as LiteRT-LM's CPU/GPU executor
/// reads them ([readLiteRtLmPrefillLengths]). With fewer entries left in the
/// context window than the smallest, LiteRT-LM refuses any input, however
/// short (`GetOptimizedPrefillWorkGroups`; §23 reports it as `context_full`),
/// so a conversation that has filled up to there needs a new one, not a
/// rewind (see [liteRtLmPrefillFits]). Empty when the bundle has no main
/// section, its main section is compiled for an NPU (that executor prefills
/// in its own context groups), or it has no prefill signature.
///
/// Throws as [readLiteRtLmBundleInfo] for a file that is not a `.litertlm`
/// container, and [LiteRtLmBundleException] ([LiteRtLmBundleProblem.malformed])
/// for a main model it cannot walk.
Future<List<int>> readLiteRtLmPrefillSignatureLengths(String path) async {
  final info = await readLiteRtLmBundleInfo(path);
  final main = info.textModel;
  // A main model compiled for an NPU runs LiteRT-LM's NPU executor, which
  // prefills in its own context groups, not by these signatures.
  if (main == null || main.npuTarget != null) return const [];
  final file = await File(path).open();
  try {
    return await readLiteRtLmPrefillLengths(
      file,
      await file.length(),
      main.begin,
      main.end,
    );
  } on Object catch (e) {
    if (e is! FormatException && e is! RangeError) rethrow;
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.malformed,
      '$path: the prefill signatures of its main model could not be read ($e)',
      path: path,
    );
  } finally {
    await file.close();
  }
}

/// Whether the main model of the `.litertlm` LLM at [path] keeps linear
/// attention state ([readLiteRtLmLinearAttentionState]): a hybrid model such
/// as LFM2.5: a `TYPE_LINEAR_ATTENTION` state buffer in the bundle's executor
/// metadata, or else a main-model input named as LiteRT-LM names that state.
/// A conversation on such a model is never rewound to an earlier
/// step, which would restore its KV cache but not that state (core 2.6.0
/// design §6.4b); it is rebuilt from text instead. False when the bundle has
/// no main section.
///
/// Throws as [readLiteRtLmBundleInfo] for a file that is not a `.litertlm`
/// container, and [LiteRtLmBundleException] ([LiteRtLmBundleProblem.malformed])
/// for a main model it cannot walk.
Future<bool> readLiteRtLmHasLinearAttentionState(String path) async {
  final info = await readLiteRtLmBundleInfo(path);
  final main = info.textModel;
  final file = await File(path).open();
  try {
    final length = await file.length();
    // A bundle with executor metadata has its state built from it, under any
    // tensor names (`LitertState::MetadataBasedCreate`).
    for (final section in info.sections) {
      if (section.dataType != 'ExecutorMetadataProto') continue;
      if (section.end <= section.begin ||
          section.end > length ||
          section.end - section.begin > _maxExecutorMetadataBytes) {
        throw RangeError(
          'ExecutorMetadata section ${section.begin}..'
          '${section.end}',
        );
      }
      final bytes = await _read(
        file,
        section.begin,
        section.end - section.begin,
      );
      if (executorMetadataHasLinearAttention(bytes)) return true;
    }
    if (main == null) return false;
    return await readLiteRtLmLinearAttentionState(
      file,
      length,
      main.begin,
      main.end,
    );
  } on Object catch (e) {
    if (e is! FormatException && e is! RangeError) rethrow;
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.malformed,
      '$path: the inputs of its main model could not be read ($e)',
      path: path,
    );
  } finally {
    await file.close();
  }
}

/// Whether a conversation of [tokenCount] tokens in a context window of
/// [maxNumTokens] can still take an input: LiteRT-LM's prefill drops every
/// prefill signature longer than the entries left, and refuses any input when
/// none is left. False when [prefillLengths] is empty (nothing to prefill
/// with).
bool liteRtLmPrefillFits({
  required int maxNumTokens,
  required int tokenCount,
  required List<int> prefillLengths,
}) =>
    prefillLengths.isNotEmpty &&
    maxNumTokens - tokenCount >= prefillLengths.reduce(math.min);

Future<Uint8List> _read(RandomAccessFile file, int position, int count) async {
  await file.setPosition(position);
  return file.read(count);
}
