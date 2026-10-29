// The models this package runs, from the project's model registry
// (model_registry/ in the repository): every file pinned to a Hugging Face
// commit and checked against its bytes. The data is generated into
// generated/litert_catalog.g.dart; this file holds the types and the rule
// for where a variant runs, which follows the loader's own tables.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../bundle/litertlm_bundle_info.dart' show LiteRtLmNpuTarget;
import '../native_hosts.dart';
import '../npu_stacks.dart' show NpuStack;
import 'catalog_host_web.dart'
    if (dart.library.ffi) 'catalog_host_io.dart'
    as host;

part 'generated/litert_catalog.g.dart';

/// Replaces the runtime [backendsHere] answers for: an `Abi.current()`
/// string, or null for the web. Tests only.
@visibleForTesting
String? Function()? debugLiteRtCatalogHost;

String? get _abi => (debugLiteRtCatalogHost ?? () => host.catalogHostAbi)();

/// A catalog of this package's models.
final class LiteRtCatalog extends ModelCatalog {
  const LiteRtCatalog._(this.name, this.models);

  @override
  final String name;

  @override
  final List<CatalogModel> models;
}

/// An LLM this package runs. Each model is its own class, with a getter per
/// variant: `LiteRtLmModels.gemma4E2bIt.npuSm8750`.
final class LiteRtLmModel extends CatalogModel {
  const LiteRtLmModel._({
    required this.id,
    required this.displayName,
    required this.family,
    required this.archClass,
    required this.license,
    required this.licenseUrl,
    required this.variants,
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final String family;

  @override
  final String archClass;

  @override
  final String license;

  @override
  final String licenseUrl;

  @override
  final List<LiteRtLmVariant> variants;

  @override
  LiteRtLmVariant? variantFor({PreferredBackend? backend, NpuTarget? npu}) =>
      super.variantFor(backend: backend, npu: npu) as LiteRtLmVariant?;
}

/// One `.litertlm` file of a [LiteRtLmModel].
final class LiteRtLmVariant extends InferenceVariant {
  const LiteRtLmVariant._({
    required this.id,
    required this.modelId,
    required this.file,
    required this.modelType,
    required this.runtimeDefaults,
    required this.supportsImage,
    required this.supportsAudio,
    required this.supportsFunctionCalls,
    required this.supportsThinking,
    required this.isWebBundle,
    required Set<PreferredBackend> textBackends,
    this.npuTarget,
    this.requiredMaxTokens,
    Set<PreferredBackend> withheld = const {},
  }) : _textBackends = textBackends,
       _withheld = withheld;

  /// Backends the registry withholds this variant from (all of them for a
  /// withheld variant, which stays in the catalog, deprecated, so code that
  /// names it still compiles).
  final Set<PreferredBackend> _withheld;

  @override
  final String id;

  @override
  final String modelId;

  @override
  String get catalogName => 'flutter_edge_ai_litertlm';

  @override
  final ModelArtifact file;

  @override
  final ModelType modelType;

  @override
  ModelFileType get fileType => ModelFileType.litertlm;

  @override
  final ModelRuntimeDefaults runtimeDefaults;

  @override
  final int? requiredMaxTokens;

  @override
  final bool supportsImage;

  @override
  final bool supportsAudio;

  @override
  final bool supportsFunctionCalls;

  @override
  final bool supportsThinking;

  /// The NPU the file is compiled for, as its compiler stamped it.
  @override
  final LiteRtLmNpuTarget? npuTarget;

  /// A bundle exported for the web engine, which runs only there.
  final bool isWebBundle;

  /// The backends the text model runs on, read from the file: the NPU for a
  /// build compiled for one, else its `backend_constraint`, else the GPU and
  /// the CPU. Backends a release withheld are not in it.
  final Set<PreferredBackend> _textBackends;

  /// A web bundle runs on the web only, on the GPU; every other file runs
  /// natively only, on a host this package's native archive is published for
  /// (Android arm64, iOS arm64 — device and Apple-Silicon simulator —, macOS
  /// arm64, Linux x64 and arm64, Windows x64): none on any other. A file compiled for an NPU runs where this package has
  /// that vendor's dispatch: Qualcomm on Android arm64 and Linux arm64,
  /// Google Tensor on Android arm64, Intel on Windows x64 (whether the app
  /// bundled the vendor's stack, which Qualcomm and Google Tensor make
  /// opt-in, is known only at load).
  /// A withheld backend is in none of these answers.
  @override
  Set<PreferredBackend> get backendsHere => _runsOn.difference(_withheld);

  Set<PreferredBackend> get _runsOn {
    final abi = _abi;
    if (abi == null) {
      return isWebBundle ? const {PreferredBackend.gpu} : const {};
    }
    if (isWebBundle || !liteRtLmNativeAbis.contains(abi)) return const {};
    return _npuRuns(npuTarget, abi) ?? _textBackends;
  }
}

/// An embedding model this package runs.
final class LiteRtEmbedderModel extends CatalogModel {
  const LiteRtEmbedderModel._({
    required this.id,
    required this.displayName,
    required this.family,
    required this.license,
    required this.licenseUrl,
    required this.variants,
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final String family;

  @override
  String get archClass => 'encoder';

  @override
  final String license;

  @override
  final String licenseUrl;

  @override
  final List<LiteRtEmbedderVariant> variants;

  @override
  LiteRtEmbedderVariant? variantFor({
    PreferredBackend? backend,
    NpuTarget? npu,
  }) => super.variantFor(backend: backend, npu: npu) as LiteRtEmbedderVariant?;
}

/// One file of a [LiteRtEmbedderModel]: a `.litertlm` bundle (EmbeddingGemma
/// 2) or a `.tflite` model with its tokenizer.
final class LiteRtEmbedderVariant extends EmbedderVariant {
  const LiteRtEmbedderVariant._({
    required this.id,
    required this.modelId,
    required this.model,
    required this.ragProfileId,
    required this.dimension,
    required this.maxInputTokens,
    required this.modalities,
    this.tokenizer,
    this.imageRagProfileId,
    this.npuTarget,
    Set<PreferredBackend> withheld = const {},
  }) : _withheld = withheld;

  /// Backends the registry withholds this variant from (see
  /// [LiteRtLmVariant]).
  final Set<PreferredBackend> _withheld;

  @override
  final String id;

  @override
  final String modelId;

  @override
  String get catalogName => 'flutter_edge_ai_litertlm';

  @override
  final ModelArtifact model;

  @override
  final ModelArtifact? tokenizer;

  @override
  final String ragProfileId;

  @override
  final String? imageRagProfileId;

  @override
  final int dimension;

  @override
  final int maxInputTokens;

  @override
  final Set<EmbeddingModality> modalities;

  /// The NPU the file is compiled for, as its compiler stamped it.
  @override
  final LiteRtLmNpuTarget? npuTarget;

  @override
  PreferredBackend? get preferredBackend =>
      npuTarget == null ? null : PreferredBackend.npu;

  /// Whether the model is a `.litertlm` bundle, which carries its tokenizer.
  bool get isBundle => tokenizer == null;

  /// A `.litertlm` bundle runs on the CPU natively — and on the GPU where
  /// that is measured, Linux x64 — and on the GPU (WebGPU) on the web; none
  /// natively on a host this package's archive is not published for; one compiled for an NPU runs on that NPU where this package has
  /// its vendor's dispatch (the rule [LiteRtLmVariant.backendsHere] states),
  /// never on the web. A `.tflite` model runs on the CPU natively (the GPU
  /// delegate returns zero vectors for EmbeddingGemma's weights) and where
  /// LiteRT.js puts it on the web; this version runs no `.tflite` compiled
  /// for an NPU.
  /// A withheld backend is in none of these answers.
  @override
  Set<PreferredBackend> get backendsHere => _runsOn.difference(_withheld);

  Set<PreferredBackend> get _runsOn {
    final abi = _abi;
    final compiled = npuTarget != null;
    if (abi == null) {
      if (compiled) return const {};
      return isBundle
          ? const {PreferredBackend.gpu}
          : const {PreferredBackend.cpu, PreferredBackend.gpu};
    }
    if (!liteRtLmNativeAbis.contains(abi)) return const {};
    if (!isBundle) return compiled ? const {} : const {PreferredBackend.cpu};
    return _npuRuns(npuTarget, abi) ??
        (liteRtLmEmbeddingGpuAbis.contains(abi)
            ? const {PreferredBackend.cpu, PreferredBackend.gpu}
            : const {PreferredBackend.cpu});
  }
}

/// For a file compiled for [target]: `{npu}` when [abi] is a host of the
/// vendor's dispatch, else none. Null for a file compiled for no NPU.
Set<PreferredBackend>? _npuRuns(LiteRtLmNpuTarget? target, String abi) {
  if (target == null) return null;
  final stack = NpuStack.forStamp(target.vendor);
  return stack != null && stack.abis.contains(abi)
      ? const {PreferredBackend.npu}
      : const {};
}
