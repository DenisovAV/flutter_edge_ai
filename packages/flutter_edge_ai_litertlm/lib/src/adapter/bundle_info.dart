// The package's public bundle-info types, over the runtime's
// (bundle/litertlm_bundle_info.dart). The runtime cannot name core's
// NpuTarget, which LiteRtLmNpuTarget is, so these wrap the runtime's
// BundleInfo / BundleSection / NpuStamp and keep the public API as it was.
// Plain Dart, exported on every platform.

import 'package:flutter_edge_ai/engine.dart' show NpuTarget, NpuVendor;
import 'package:meta/meta.dart' show internal;

import 'package:litertlm_dart/internal.dart' hide ActivationDataType;

/// The SoC a `.litertlm` bundle's compiled sections target.
///
/// It is the core [NpuTarget] of a catalog variant compiled for an NPU, with
/// the vendor and SoC spelled as the compiler stamped them.
final class LiteRtLmNpuTarget extends NpuTarget {
  const LiteRtLmNpuTarget({required this.vendor, required this.soc});

  /// The public target for the runtime's [stamp].
  @internal
  LiteRtLmNpuTarget.fromStamp(NpuStamp stamp)
    : vendor = stamp.vendor,
      soc = stamp.soc;

  /// The SoC manufacturer as the compiler stamped it: `Qualcomm`, `Google`,
  /// `MediaTek`, `IntelOpenVINO`.
  final String vendor;

  /// The SoC model as the compiler stamped it, e.g. `SM8850`, `QCS8275`,
  /// `PTL`, `Tensor_G5`.
  final String soc;

  /// This target as the runtime names it.
  @internal
  NpuStamp get stamp => NpuStamp(vendor: vendor, soc: soc);

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

  bool get isQualcomm => stamp.isQualcomm;

  /// Compiled by LiteRT's OpenVINO plugin for an Intel NPU: Google's
  /// `…_Intel_PTL` bundles are stamped `IntelOpenVINO` / `PTL` (read from the
  /// published 270m, 440m and 740m, revisions 9be6e8b9, e301f74d, 24d962e9).
  bool get isIntel => stamp.isIntel;

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

/// One section of a `.litertlm` container.
final class LiteRtLmSection {
  LiteRtLmSection({
    required String dataType,
    required int begin,
    required int end,
    Map<String, Object?> items = const {},
    LiteRtLmNpuTarget? npuTarget,
  }) : _section = BundleSection(
         dataType: dataType,
         begin: begin,
         end: end,
         items: items,
         npuTarget: npuTarget?.stamp,
       );

  LiteRtLmSection._(this._section);

  final BundleSection _section;

  late final LiteRtLmNpuTarget? _npuTarget = switch (_section.npuTarget) {
    final stamp? => LiteRtLmNpuTarget.fromStamp(stamp),
    null => null,
  };

  /// The section's `AnySectionDataType` as the schema names it:
  /// `TFLiteModel`, `SP_Tokenizer`, `LlmMetadataProto`, `HF_Tokenizer_Zlib`,
  /// `TFLiteWeights`, … — or `unknown(<n>)` for a value this version of the
  /// package does not know.
  String get dataType => _section.dataType;

  /// Byte offsets of the section in the file: `[begin, end)`.
  int get begin => _section.begin;
  int get end => _section.end;

  /// The section's key-value items as the file writes them: `String`, `int`,
  /// `double` or `bool` values.
  Map<String, Object?> get items => _section.items;

  /// The NPU this section was compiled for: the `LiteRtStamp` LiteRT's
  /// ahead-of-time compiler writes into every model it compiles. Null for a
  /// section that is not compiled for an NPU, for a section that is not a
  /// TFLite model, and on the web, where only the header is read.
  LiteRtLmNpuTarget? get npuTarget => _npuTarget;

  int get length => _section.length;

  /// The `model_type` item of a `TFLiteModel` section, lowercased as
  /// LiteRT-LM compares it: `tf_lite_prefill_decode`, `tf_lite_vision_encoder`,
  /// `tf_lite_audio_encoder_hw`, `tf_lite_aux`, `tf_lite_mtp_drafter`, …
  String? get modelType => _section.modelType;

  /// The backends the section declares it runs on (`backend_constraint`, a
  /// comma-separated list LiteRT-LM checks the requested backend against),
  /// lowercased; null when it declares none.
  List<String>? get backendConstraint => _section.backendConstraint;

  @override
  String toString() =>
      _section.toString().replaceFirst('BundleSection(', 'LiteRtLmSection(');
}

/// What a `.litertlm` file says about itself, read before any engine exists:
/// its container version, its system metadata, and its sections with their
/// declared constraints and the NPU each compiled section targets.
///
/// Natively, read it with `readLiteRtLmBundleInfo(path)`.
final class LiteRtLmBundleInfo {
  LiteRtLmBundleInfo({
    required int majorVersion,
    required int minorVersion,
    required int patchVersion,
    required Map<String, Object?> systemMetadata,
    required List<LiteRtLmSection> sections,
    required int fileLength,
  }) : this._(
         BundleInfo(
           majorVersion: majorVersion,
           minorVersion: minorVersion,
           patchVersion: patchVersion,
           systemMetadata: systemMetadata,
           sections: [for (final s in sections) s._section],
           fileLength: fileLength,
         ),
         sections,
       );

  /// The public info for the runtime's [info].
  @internal
  LiteRtLmBundleInfo.of(BundleInfo info)
    : this._(info, [for (final s in info.sections) LiteRtLmSection._(s)]);

  LiteRtLmBundleInfo._(this.info, List<LiteRtLmSection> sections)
    : sections = List.unmodifiable(sections);

  /// This info as the runtime names it.
  @internal
  final BundleInfo info;

  /// The container format version (`1.5.0` for the Gemma 4 bundles).
  int get majorVersion => info.majorVersion;
  int get minorVersion => info.minorVersion;
  int get patchVersion => info.patchVersion;

  /// The file's system metadata as written: keys differ between bundles
  /// (`author`, `Authors`, `model_name`, `uuid`, `creation_timestamp`, …).
  Map<String, Object?> get systemMetadata => info.systemMetadata;

  /// Every section, in header order.
  final List<LiteRtLmSection> sections;

  /// The length of the file the header was read from.
  int get fileLength => info.fileLength;

  /// Where the last section ends: the length a complete file has.
  int get expectedLength => info.expectedLength;

  /// Whether the file holds every section its header lists. False for a
  /// download that stopped early: LiteRT-LM would fail on it with an error
  /// that does not say so.
  bool get isComplete => info.isComplete;

  /// The first `TFLiteModel` section whose `model_type` is [modelType]. A
  /// `TFLiteModel` section without a `model_type` is a
  /// `tf_lite_prefill_decode`, as LiteRT-LM reads it (`litert_lm_loader.cc`);
  /// a section of another data type (`TFLiteWeights`, a tokenizer) is never
  /// one, whatever `model_type` it carries.
  LiteRtLmSection? sectionOf(String modelType) =>
      _wrapSection(info.sectionOf(modelType));

  /// The wrapper in [sections] of the runtime's [section], so a section reads
  /// as the same object however it is reached.
  LiteRtLmSection? _wrapSection(BundleSection? section) {
    if (section == null) return null;
    for (final wrapper in sections) {
      if (identical(wrapper._section, section)) return wrapper;
    }
    return LiteRtLmSection._(section);
  }

  /// The text model, whose backend is the model's `preferredBackend`.
  LiteRtLmSection? get textModel => _wrapSection(info.textModel);

  /// The vision encoder, whose backend is `preferredVisionBackend`; null for a
  /// bundle without vision.
  LiteRtLmSection? get visionEncoder => _wrapSection(info.visionEncoder);

  /// The audio encoder, whose backend is `preferredAudioBackend`; null for a
  /// bundle without audio.
  LiteRtLmSection? get audioEncoder => _wrapSection(info.audioEncoder);

  /// Whether the bundle carries a multi-token-prediction drafter, which
  /// speculative decoding uses.
  bool get hasMtpDrafter => info.hasMtpDrafter;

  /// Whether the bundle carries a `tf_lite_aux` section. LiteRT-LM takes this
  /// as the mark of a model compiled ahead of time for an NPU and runs it with
  /// its NPU executor (`litert_compiled_model_executor_utils.cc`); every
  /// per-SoC bundle published so far has one, and no GPU or CPU bundle does.
  bool get hasNpuAux => info.hasNpuAux;

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
  bool get isCompiledForNpu => info.isCompiledForNpu;

  @override
  String toString() =>
      info.toString().replaceFirst('BundleInfo(', 'LiteRtLmBundleInfo(');
}
