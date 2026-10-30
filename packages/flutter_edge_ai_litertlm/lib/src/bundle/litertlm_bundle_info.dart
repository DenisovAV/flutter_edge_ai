// What a `.litertlm` file says about itself: its container header (LiteRT-LM
// `schema/core/litertlm_header_schema.fbs`, pin b2f686e2) and, read natively by
// `readLiteRtLmBundleInfo`, the NPU each compiled section was built for.
//
// The types here are plain Dart, exported on every platform so code that names
// them compiles on the web too; reading a file needs `dart:io`
// (`litertlm_bundle_reader.dart`). The LLM load uses the same reading to decide
// where a bundle runs before any engine exists (`litertlm_load_plan.dart`).

import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart' show NpuTarget, NpuVendor;

import '../litertlm_flatbuffer.dart';
import '../npu_stacks.dart' show NpuStack;

/// The SoC a `.litertlm` bundle's compiled sections target.
///
/// It is the core [NpuTarget] of a catalog variant compiled for an NPU, with
/// the vendor and SoC spelled as the compiler stamped them.
final class LiteRtLmNpuTarget extends NpuTarget {
  const LiteRtLmNpuTarget({required this.vendor, required this.soc});

  /// The SoC manufacturer as the compiler stamped it: `Qualcomm`, `Google`,
  /// `MediaTek`, `IntelOpenVINO`.
  final String vendor;

  /// The SoC model as the compiler stamped it, e.g. `SM8850`, `QCS8275`,
  /// `PTL`, `Tensor_G5`.
  final String soc;

  /// The vendor by core's name, through the one table of stamps
  /// ([NpuStack]); null for a stamp this package has no stack for.
  @override
  NpuVendor? get npuVendor => switch (NpuStack.forStamp(vendor)) {
    NpuStack.qualcomm => NpuVendor.qualcomm,
    NpuStack.googleTensor => NpuVendor.googleTensor,
    NpuStack.mediatek => NpuVendor.mediatek,
    NpuStack.intel => NpuVendor.intel,
    null => null,
  };

  /// [soc], as the compiler stamped it.
  @override
  String get socModel => soc;

  bool get isQualcomm => npuVendorOf(this) == NpuStack.qualcomm;

  /// Compiled by LiteRT's OpenVINO plugin for an Intel NPU: Google's
  /// `…_Intel_PTL` bundles are stamped `IntelOpenVINO` / `PTL` (read from the
  /// published 270m, 440m and 740m, revisions 9be6e8b9, e301f74d, 24d962e9).
  bool get isIntel => npuVendorOf(this) == NpuStack.intel;

  /// The same stamp as written. [sameSoc] is the comparison that ignores
  /// case (a stamp's case is the compiler's, not the SoC's).
  @override
  bool operator ==(Object other) =>
      other is LiteRtLmNpuTarget && other.vendor == vendor && other.soc == soc;

  @override
  int get hashCode => Object.hash(vendor, soc);

  @override
  String toString() => '$vendor $soc';
}

/// The vendor this package dispatches a bundle stamped [target] to, or null
/// when it has no dispatch for that vendor. Internal: not in the package's
/// `show` list, so [NpuStack] stays out of the public API.
NpuStack? npuVendorOf(LiteRtLmNpuTarget target) =>
    NpuStack.forStamp(target.vendor);

/// One section of a `.litertlm` container.
final class LiteRtLmSection {
  LiteRtLmSection({
    required this.dataType,
    required this.begin,
    required this.end,
    Map<String, Object?> items = const {},
    this.npuTarget,
  }) : items = Map.unmodifiable(items);

  /// The section's `AnySectionDataType` as the schema names it:
  /// `TFLiteModel`, `SP_Tokenizer`, `LlmMetadataProto`, `HF_Tokenizer_Zlib`,
  /// `TFLiteWeights`, … — or `unknown(<n>)` for a value this version of the
  /// package does not know.
  final String dataType;

  /// Byte offsets of the section in the file: `[begin, end)`.
  final int begin;
  final int end;

  /// The section's key-value items as the file writes them: `String`, `int`,
  /// `double` or `bool` values.
  final Map<String, Object?> items;

  /// The NPU this section was compiled for: the `LiteRtStamp` LiteRT's
  /// ahead-of-time compiler writes into every model it compiles. Null for a
  /// section that is not compiled for an NPU, for a section that is not a
  /// TFLite model, and on the web, where only the header is read.
  final LiteRtLmNpuTarget? npuTarget;

  int get length => end - begin;

  /// The `model_type` item of a `TFLiteModel` section, lowercased as
  /// LiteRT-LM compares it: `tf_lite_prefill_decode`, `tf_lite_vision_encoder`,
  /// `tf_lite_audio_encoder_hw`, `tf_lite_aux`, `tf_lite_mtp_drafter`, …
  String? get modelType => switch (_item('model_type')) {
    final String type => type.toLowerCase(),
    _ => null,
  };

  /// The backends the section declares it runs on (`backend_constraint`, a
  /// comma-separated list LiteRT-LM checks the requested backend against),
  /// lowercased; null when it declares none.
  List<String>? get backendConstraint => switch (_item('backend_constraint')) {
    final String list => [
      for (final name in list.split(','))
        if (name.trim().isNotEmpty) name.trim().toLowerCase(),
    ],
    _ => null,
  };

  /// LiteRT-LM reads item keys case-insensitively.
  Object? _item(String key) {
    for (final MapEntry(key: k, :value) in items.entries) {
      if (k.toLowerCase() == key) return value;
    }
    return null;
  }

  @override
  String toString() =>
      'LiteRtLmSection($dataType${modelType == null ? '' : ' $modelType'}, '
      '$begin..$end${npuTarget == null ? '' : ', compiled for $npuTarget'})';
}

/// What a `.litertlm` file says about itself, read before any engine exists:
/// its container version, its system metadata, and its sections with their
/// declared constraints and the NPU each compiled section targets.
///
/// Natively, read it with `readLiteRtLmBundleInfo(path)`.
final class LiteRtLmBundleInfo {
  LiteRtLmBundleInfo({
    required this.majorVersion,
    required this.minorVersion,
    required this.patchVersion,
    required Map<String, Object?> systemMetadata,
    required List<LiteRtLmSection> sections,
    required this.fileLength,
  }) : systemMetadata = Map.unmodifiable(systemMetadata),
       sections = List.unmodifiable(sections);

  /// The container format version (`1.5.0` for the Gemma 4 bundles).
  final int majorVersion;
  final int minorVersion;
  final int patchVersion;

  /// The file's system metadata as written: keys differ between bundles
  /// (`author`, `Authors`, `model_name`, `uuid`, `creation_timestamp`, …).
  final Map<String, Object?> systemMetadata;

  /// Every section, in header order.
  final List<LiteRtLmSection> sections;

  /// The length of the file the header was read from.
  final int fileLength;

  /// Where the last section ends: the length a complete file has.
  int get expectedLength =>
      sections.fold(0, (end, section) => section.end > end ? section.end : end);

  /// Whether the file holds every section its header lists. False for a
  /// download that stopped early: LiteRT-LM would fail on it with an error
  /// that does not say so.
  bool get isComplete => fileLength >= expectedLength;

  /// The first `TFLiteModel` section whose `model_type` is [modelType]. A
  /// `TFLiteModel` section without a `model_type` is a
  /// `tf_lite_prefill_decode`, as LiteRT-LM reads it (`litert_lm_loader.cc`);
  /// a section of another data type (`TFLiteWeights`, a tokenizer) is never
  /// one, whatever `model_type` it carries.
  LiteRtLmSection? sectionOf(String modelType) {
    final type = modelType.toLowerCase();
    for (final section in sections) {
      if (section.dataType != _tfliteModel) continue;
      if ((section.modelType ?? _prefillDecode) == type) return section;
    }
    return null;
  }

  /// The text model, whose backend is the model's `preferredBackend`.
  LiteRtLmSection? get textModel => sectionOf(_prefillDecode);

  /// The vision encoder, whose backend is `preferredVisionBackend`; null for a
  /// bundle without vision.
  LiteRtLmSection? get visionEncoder => sectionOf(_visionEncoder);

  /// The audio encoder, whose backend is `preferredAudioBackend`; null for a
  /// bundle without audio.
  LiteRtLmSection? get audioEncoder => sectionOf(_audioEncoder);

  /// Whether the bundle carries a multi-token-prediction drafter, which
  /// speculative decoding uses.
  bool get hasMtpDrafter => sectionOf('tf_lite_mtp_drafter') != null;

  /// Whether the bundle carries a `tf_lite_aux` section. LiteRT-LM takes this
  /// as the mark of a model compiled ahead of time for an NPU and runs it with
  /// its NPU executor (`litert_compiled_model_executor_utils.cc`); every
  /// per-SoC bundle published so far has one, and no GPU or CPU bundle does.
  bool get hasNpuAux => sectionOf('tf_lite_aux') != null;

  /// The NPU the bundle's compiled sections target, or null for a bundle with
  /// no compiled section. Always null when only the header was read.
  LiteRtLmNpuTarget? get npuTarget {
    for (final section in sections) {
      if (section.npuTarget case final target?) return target;
    }
    return null;
  }

  /// Whether the text model runs on an NPU only: the bundle has a
  /// [hasNpuAux] section or its [textModel] is compiled for an NPU. Such a
  /// bundle fails to load on the GPU and the CPU ("Failed to create engine").
  /// An encoder compiled for an NPU does not make the text model NPU-only.
  bool get isCompiledForNpu => hasNpuAux || textModel?.npuTarget != null;

  @override
  String toString() =>
      'LiteRtLmBundleInfo($majorVersion.$minorVersion.$patchVersion, '
      '${sections.length} sections, $fileLength of $expectedLength bytes'
      '${npuTarget == null ? '' : ', compiled for $npuTarget'})';
}

/// Why a `.litertlm` file cannot be read or loaded as asked.
enum LiteRtLmBundleProblem {
  /// The file does not start with the `LITERTLM` magic.
  notLitertlm,

  /// The container's major version is not one this package reads.
  unsupportedVersion,

  /// The header or a compiled section's metadata is out of range.
  malformed,

  /// The file is shorter than its sections: a download that stopped early.
  incomplete,

  /// The bundle cannot run on the backend that was asked for: an NPU-compiled
  /// model on the GPU or the CPU, a text model or encoder whose
  /// `backend_constraint` excludes the backend, a text model or encoder asked
  /// for the NPU it is not compiled for — also when its `backend_constraint`
  /// names the NPU; a text model whose constraint names only the NPU has
  /// nothing to run on.
  wrongBackend,

  /// The text model, or an encoder the load turns on, is compiled for an NPU
  /// this package has no dispatch for on this platform (a bundle of an NPU
  /// vendor this package does not know, a Qualcomm bundle on Windows, a
  /// Google Tensor or MediaTek bundle off Android); the sections the load
  /// turns on are compiled for two different NPUs (one load
  /// runs one NPU's dispatch); or an encoder the load turns on runs on the NPU
  /// while the text model is not tried on the NPU alone: this package runs an
  /// encoder on the NPU only together with a text model on the NPU (a bundle
  /// compiled for the NPU throughout). An encoder that is off is not checked.
  unsupportedNpu,
}

/// A `.litertlm` file that cannot be read, or cannot run as asked — thrown
/// before any engine is created.
final class LiteRtLmBundleException implements Exception {
  const LiteRtLmBundleException(this.problem, this.message, {this.path});

  final LiteRtLmBundleProblem problem;
  final String message;

  /// The file, when known.
  final String? path;

  @override
  String toString() => 'LiteRtLmBundleException(${problem.name}): $message';
}

const _tfliteModel = 'TFLiteModel';
const _prefillDecode = 'tf_lite_prefill_decode';
const _visionEncoder = 'tf_lite_vision_encoder';
const _audioEncoder = 'tf_lite_audio_encoder_hw';

/// `AnySectionDataType`, in schema order.
const _dataTypes = [
  'NONE',
  'GenericBinaryData',
  'Deprecated',
  'TFLiteModel',
  'SP_Tokenizer',
  'LlmMetadataProto',
  'HF_Tokenizer_Zlib',
  'TFLiteWeights',
  'EmbeddingMetadataProto',
  'ExecutorMetadataProto',
  'TtsMetadataProto',
  'AsrMetadataProto',
];

/// `AnySectionDataType.TFLiteModel`.
const litertlmTfliteModelType = 3;

/// The container version, from the 32-byte preamble: the magic `LITERTLM`,
/// then major, minor and patch as uint32 (LiteRT-LM `litertlm_read.cc`).
/// Throws [LiteRtLmBundleException] for a file that is not a container or
/// one whose major version this package does not read.
({int major, int minor, int patch}) litertlmContainerVersion(
  Uint8List preamble, {
  String? path,
}) {
  if (preamble.length < 32 ||
      String.fromCharCodes(preamble.sublist(0, 8)) != 'LITERTLM') {
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.notLitertlm,
      '${path ?? 'the file'} is not a .litertlm container (no LITERTLM magic)',
      path: path,
    );
  }
  final data = ByteData.sublistView(preamble);
  final version = (
    major: data.getUint32(8, Endian.little),
    minor: data.getUint32(12, Endian.little),
    patch: data.getUint32(16, Endian.little),
  );
  if (version.major != 1) {
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.unsupportedVersion,
      '${path ?? 'the file'} is a version ${version.major} .litertlm '
      'container; this package reads version 1',
      path: path,
    );
  }
  return version;
}

/// Parses the container [header] — the flatbuffer from byte 32 to the header
/// end — of a file of [fileLength] bytes. [npuTargetOf] gives each
/// `TFLiteModel` section's stamp (`[begin, end)`), or null; without it no
/// section has one.
///
/// Native only for the section offsets (`uint64`). Throws
/// [LiteRtLmBundleException] ([LiteRtLmBundleProblem.malformed]) when the
/// flatbuffer is out of range.
LiteRtLmBundleInfo parseLitertlmHeader(
  Uint8List header, {
  required ({int major, int minor, int patch}) version,
  required int fileLength,
  Map<(int, int), LiteRtLmNpuTarget?> npuTargets = const {},
  String? path,
}) {
  try {
    final fb = LitertlmFlatBuffer(header);
    final root = fb.root();
    // LiteRTLMMetaData: system_metadata = 0, section_metadata = 1.
    final system = <String, Object?>{};
    if (fb.table(root, 0) case final systemMetadata?) {
      // SystemMetadata.entries = 0.
      if (fb.vector(systemMetadata, 0) case final entries?) {
        _readItems(fb, entries, system);
      }
    }
    final sections = <LiteRtLmSection>[];
    final sectionMetadata = fb.table(root, 1);
    final objects = sectionMetadata == null
        ? null
        : fb.vector(sectionMetadata, 0);
    if (objects != null) {
      for (var i = 0; i < fb.length(objects); i++) {
        final section = fb.element(objects, i);
        // SectionObject: items = 0, begin_offset = 1, end_offset = 2,
        // data_type = 3.
        final items = <String, Object?>{};
        if (fb.vector(section, 0) case final vector?) {
          _readItems(fb, vector, items);
        }
        final type = fb.uint8(section, 3);
        final begin = fb.uint64(section, 1);
        final end = fb.uint64(section, 2);
        sections.add(
          LiteRtLmSection(
            dataType: type < _dataTypes.length
                ? _dataTypes[type]
                : 'unknown($type)',
            begin: begin,
            end: end,
            items: items,
            npuTarget: npuTargets[(begin, end)],
          ),
        );
      }
    }
    return LiteRtLmBundleInfo(
      majorVersion: version.major,
      minorVersion: version.minor,
      patchVersion: version.patch,
      systemMetadata: system,
      sections: sections,
      fileLength: fileLength,
    );
  } on RangeError catch (e) {
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.malformed,
      '${path ?? 'the file'}: the .litertlm header is out of range ($e)',
      path: path,
    );
  }
}

/// `VData` union discriminators (NONE is 0), in schema order.
const _uInt8 = 1,
    _int8 = 2,
    _uInt16 = 3,
    _int16 = 4,
    _uInt32 = 5,
    _int32 = 6,
    _float32 = 7,
    _bool = 8,
    _string = 9,
    _uInt64 = 10,
    _int64 = 11,
    _double = 12;

/// Reads a vector of `KeyValuePair`s (key = 0; the `value` union takes two
/// slots, value_type = 1 and value = 2; each value table keeps its value in
/// field 0) into [out].
void _readItems(LitertlmFlatBuffer fb, int vector, Map<String, Object?> out) {
  for (var j = 0; j < fb.length(vector); j++) {
    final item = fb.element(vector, j);
    final key = fb.string(item, 0);
    if (key == null) continue;
    final value = fb.table(item, 2);
    out[key] = value == null
        ? null
        : switch (fb.uint8(item, 1)) {
            _string => fb.string(value, 0),
            _bool => fb.uint8(value, 0) != 0,
            _uInt8 => fb.uint8(value, 0),
            _int8 => fb.int8(value, 0),
            _uInt16 => fb.uint16(value, 0),
            _int16 => fb.int16(value, 0),
            _uInt32 => fb.uint32(value, 0),
            _int32 => fb.int32(value, 0),
            _uInt64 || _int64 => fb.int64(value, 0),
            _float32 => fb.float32(value, 0),
            _double => fb.float64(value, 0),
            _ => null,
          };
  }
}
