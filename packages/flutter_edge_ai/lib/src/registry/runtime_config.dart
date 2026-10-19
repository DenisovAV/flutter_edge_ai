import 'package:meta/meta.dart' show immutable;
import 'package:flutter_edge_ai/src/domain/multimodal_order.dart'
    show MultimodalOrder;
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show ActivationDataType, PreferredBackend;
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';

/// Runtime config for building a model — the per-call params `getActiveModel`
/// collects, kept as a small holder so the provider contract stays stable as
/// params evolve.
class RuntimeConfig {
  const RuntimeConfig({
    required this.maxTokens,
    required this.modelPath,
    this.tokenizerPath,
    this.preferredBackend,
    this.preferredVisionBackend,
    this.preferredAudioBackend,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxNumImages,
    this.multimodalOrder,
    this.enableSpeculativeDecoding,
    this.activationDataType,
    this.maxConcurrentSessions,
    this.loraRanks,
    this.artifactPaths,
    this.language,
  }) : assert(maxTokens >= 0, 'maxTokens must not be negative'),
       assert(
         maxNumImages == null || maxNumImages >= 0,
         'maxNumImages must not be negative',
       ),
       assert(
         maxConcurrentSessions == null || maxConcurrentSessions > 0,
         'maxConcurrentSessions must be positive when set',
       );

  final int maxTokens;

  /// Resolved on-disk path to the model file. Core's platform `createModel`
  /// preamble resolves it from the active spec via the model manager and passes
  /// it here so the engine package never touches core's file-path resolution.
  ///
  /// Empty on web: the web engines resolve the model source themselves via
  /// `WebModelSourceResolver` (there is no on-disk path), so this is `''` there.
  /// Hence there is no non-empty assert on it.
  final String modelPath;

  /// Resolved on-disk path to the tokenizer. Used by embedding and STT
  /// backends; null for inference, and null for a self-contained embedder
  /// (`EmbeddingModelSpec.isSelfContained`, e.g. a `.litertlm` bundle that
  /// carries its own tokenizer). The spec carries source *identities*
  /// (network/asset/file); core resolves them to on-disk paths via the model
  /// manager and passes the resolved tokenizer path here (install-vs-runtime
  /// separation).
  final String? tokenizerPath;

  final PreferredBackend? preferredBackend;

  /// Backend for the VISION encoder, independent of [preferredBackend] (the
  /// text/decoder backend). Null lets the engine choose: the native LiteRT-LM
  /// engine follows the bundle — the encoder's declared `backend_constraint`
  /// (the CPU when that allows it), else the NPU it is compiled for, else the
  /// CPU, because the vision encoder's `STABLEHLO_COMPOSITE` ops fail to
  /// prepare on the Metal/WebGPU delegates (LiteRT-LM#2461) — and reports its
  /// choice in `InferenceModel.activeVisionBackend`. Set one only where the
  /// section allows it (`readLiteRtLmBundleInfo(path).visionEncoder` in
  /// `flutter_edge_ai_litertlm` shows its `backend_constraint`); a backend it
  /// excludes is refused before the model loads. Ignored by the MediaPipe
  /// engine (whole-model backend, no per-encoder split).
  final PreferredBackend? preferredVisionBackend;

  /// Backend for the AUDIO encoder, independent of [preferredBackend]. Null
  /// lets the engine choose, as for [preferredVisionBackend], and the native
  /// LiteRT-LM engine reports it in `InferenceModel.activeAudioBackend`. Set
  /// one only where the section allows it: the published Gemma 4 and Gemma 3n
  /// audio encoders declare `backend_constraint` cpu, so
  /// `PreferredBackend.gpu` is refused for them
  /// (`readLiteRtLmBundleInfo(path).audioEncoder?.backendConstraint` shows
  /// it). Ignored by MediaPipe.
  final PreferredBackend? preferredAudioBackend;

  /// Inference: whether the model is created with vision. Embedders: the
  /// media the caller declared (`getActiveEmbedder(supportImage:)`), widened
  /// by core to everything the cached embedder already served.
  final bool supportImage;

  /// Inference: whether the model is created with audio. Embedders: as
  /// [supportImage], for audio.
  final bool supportAudio;
  final int? maxNumImages;

  /// The order of a user message's images, audio and text. Core always sets
  /// it: `getActiveModel` resolves an omitted one with
  /// [MultimodalOrder.forModelType], and a null in a config built by hand
  /// means the same. Honored by the native LiteRT-LM engine; the other
  /// engines ignore it (MediaPipe sends images, audio, then text).
  final MultimodalOrder? multimodalOrder;
  final bool? enableSpeculativeDecoding;

  /// Activation type for the native LiteRT-LM engine's text decoder. Null
  /// leaves it to the model file (except a `ModelType.functionGemma` bundle
  /// that declares no `prefer_activation_type`, which gets float32 on its GPU
  /// attempt); when set, it overrides LiteRT-LM's own
  /// choice (float16 on GPU by default). Set [ActivationDataType.float32]
  /// when a GPU writes wrong digits
  /// (LiteRT-LM#2814, #3012). The vision and audio encoders keep the model's
  /// own type; MediaPipe, ONNX, built-in AI and the web engines ignore it.
  final ActivationDataType? activationDataType;
  final int? maxConcurrentSessions;

  /// LoRA ranks for the MediaPipe path; null falls back to the platform's
  /// `supportedLoraRanks`. Carried in the config so the (cached) default-engine
  /// build closure reads it per call instead of capturing a stale local.
  final List<int>? loraRanks;

  /// filename → on-disk path for a multi-file model bundle (TTS). The bundle
  /// backend resolves each graph/dictionary/embedding file by name from this
  /// map. Null for single-file models (inference/embedding/STT).
  final Map<String, String>? artifactPaths;

  /// The output language, for the two model kinds that have one. Null
  /// everywhere else, and null means "the backend's own default".
  ///
  /// ⚠️ The two consumers use INCOMPATIBLE vocabularies, and nothing here can
  /// tell them apart — the active model decides which one applies:
  ///
  /// - **TTS (Qwen3)**: a full lowercase language NAME — one of
  ///   `flutter_edge_ai_speech`'s `qwen3SupportedLanguages`, or `'auto'`
  ///   (`'english'`, `'german'`). Null defaults to `'english'`. Matcha ignores
  ///   it; its locale comes from `TtsModelProfile.locale`.
  /// - **STT (Whisper)**: a bare lowercase ISO CODE (`'en'`, `'de'`) — the
  ///   decoder-prompt language token. Null leaves the profile's `'en'`.
  ///   moonshine and parakeet have no language token and REJECT a non-null
  ///   value rather than ignoring it.
  ///
  /// So `'english'` is right for one and an error for the other. Splitting this
  /// into `ttsLanguage`/`sttLanguage` would say that in the type; it is left as
  /// one field for now because a single `RuntimeConfig` is only ever built for
  /// one model kind.
  ///
  /// Not validated here — each backend rejects an unsupported value with
  /// `ArgumentError` before loading the model.
  final String? language;
}

/// The runtime knobs a caller passes to `getActiveModel`, captured so a second
/// call can tell whether the cached singleton still satisfies the request.
///
/// This exists because the check was written twice and drifted. Mobile compared
/// nothing beyond the model name, so `getActiveModel(preferredBackend: cpu)`
/// after a GPU creation silently returned the GPU model; desktop compared three
/// of the nine parameters, so the other six were equally silent there. Two
/// copies of one rule is how the copies stop agreeing — keep the comparison
/// here and let both shells call it.
class ActiveModelParams {
  const ActiveModelParams({
    required this.maxTokens,
    this.preferredBackend,
    this.preferredVisionBackend,
    this.preferredAudioBackend,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxNumImages,
    this.multimodalOrder,
    this.enableSpeculativeDecoding,
    this.activationDataType,
    this.maxConcurrentSessions,
    this.loraRanks,
  });

  final int maxTokens;
  final PreferredBackend? preferredBackend;
  final PreferredBackend? preferredVisionBackend;
  final PreferredBackend? preferredAudioBackend;
  final bool supportImage;
  final bool supportAudio;
  final int? maxNumImages;

  /// The shells resolve an omitted order with [MultimodalOrder.forModelType]
  /// before building this, so an omitted order and the model type's own
  /// order spelled out compare equal.
  final MultimodalOrder? multimodalOrder;
  final bool? enableSpeculativeDecoding;
  final ActivationDataType? activationDataType;
  final int? maxConcurrentSessions;

  /// MediaPipe LoRA ranks. Forwarded to the engine by `createModel`, so a
  /// change must rebuild — it was the tenth knob and the comparison had nine.
  final List<int>? loraRanks;

  /// The same request with every value the engines normalise away already
  /// applied, so two requests that build a bit-identical engine compare equal.
  ///
  /// Comparing the RAW arguments caused spurious rebuilds — and a rebuild here
  /// unloads and reloads multi-gigabyte weights, so it is expensive and very
  /// visible. One knob is normalised downstream:
  ///
  ///   * `maxNumImages` is `maxNumImages ?? 1` when vision is on and discarded
  ///     entirely when it is off, in both engines. So null and 1 are the same
  ///     request, and with `supportImage: false` the value is dead.
  ///
  /// `preferredVisionBackend` / `preferredAudioBackend` are dropped when their
  /// encoder is off, and otherwise kept as given: null lets the engine choose
  /// from the model file (the NPU for an encoder compiled for one), so it is
  /// not the same request as an explicit CPU.
  ///
  /// `maxTokens` is NOT normalised here: the `.litertlm` engine clamps it up to
  /// 1024 but MediaPipe does not, so the effective value depends on which
  /// engine `canHandle` picks and core cannot know it. A caller who asks for
  /// 512 and then for the default 1024 still rebuilds on the litertlm path
  /// even though both engines end up at 1024. Fixing that means moving the
  /// clamp out of the engine and into core; it is left alone rather than
  /// guessed at.
  ActiveModelParams normalized() => ActiveModelParams(
    maxTokens: maxTokens,
    preferredBackend: preferredBackend,
    preferredVisionBackend: supportImage ? preferredVisionBackend : null,
    preferredAudioBackend: supportAudio ? preferredAudioBackend : null,
    supportImage: supportImage,
    supportAudio: supportAudio,
    maxNumImages: supportImage ? (maxNumImages ?? 1) : null,
    multimodalOrder: multimodalOrder,
    enableSpeculativeDecoding: enableSpeculativeDecoding,
    activationDataType: activationDataType,
    maxConcurrentSessions: maxConcurrentSessions,
    loraRanks: loraRanks,
  );

  /// Name of the first parameter that differs from [other], or null when the
  /// cached model can be reused. Both sides are [normalized] first.
  ///
  /// Returns the NAME rather than a bool so the caller can say which knob
  /// forced the reload. "Model recreation: paramsChanged=true" tells nobody
  /// what to change.
  String? firstDifference(ActiveModelParams other) {
    final a = normalized();
    final b = other.normalized();
    return a._rawDifference(b);
  }

  static bool _sameRanks(List<int>? a, List<int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String? _rawDifference(ActiveModelParams other) {
    if (maxTokens != other.maxTokens) return 'maxTokens';
    if (preferredBackend != other.preferredBackend) return 'preferredBackend';
    // Before the encoder backends, which mean something only while their
    // encoder is on (normalized drops them otherwise).
    if (supportImage != other.supportImage) return 'supportImage';
    if (supportAudio != other.supportAudio) return 'supportAudio';
    if (preferredVisionBackend != other.preferredVisionBackend) {
      return 'preferredVisionBackend';
    }
    if (preferredAudioBackend != other.preferredAudioBackend) {
      return 'preferredAudioBackend';
    }
    if (maxNumImages != other.maxNumImages) return 'maxNumImages';
    if (multimodalOrder != other.multimodalOrder) return 'multimodalOrder';
    if (enableSpeculativeDecoding != other.enableSpeculativeDecoding) {
      return 'enableSpeculativeDecoding';
    }
    if (activationDataType != other.activationDataType) {
      return 'activationDataType';
    }
    if (maxConcurrentSessions != other.maxConcurrentSessions) {
      return 'maxConcurrentSessions';
    }
    if (!_sameRanks(loraRanks, other.loraRanks)) return 'loraRanks';
    return null;
  }
}

/// The runtime knobs a caller passes to `getActiveEmbedder`, captured so a
/// second call can tell whether the cached singleton still satisfies it.
///
/// Its own record rather than [ActiveModelParams], which carries ten inference
/// knobs and no identity at all: `maxTokens` is required there and compared
/// first, and `normalized()` would apply vision and audio defaults to a model
/// that has no encoders. (The `maxTokens: 0` filler in the web shell is on
/// [RuntimeConfig], not on that class — no shell builds an `ActiveModelParams`
/// for an embedder.)
///
/// The empirical reason, which is the same one that justified the neighbour:
/// the reuse check was written three times and disagreed. Mobile compared the
/// spec NAME, so reinstalling a same-named embedder to a new path was
/// invisible; web kept its own record with both paths nullable; desktop
/// compared the name too. All three call this now.
///
/// Only three values decide what an embedder IS — [modelPath],
/// [tokenizerPath] and [activeBackend]; `==`, `hashCode` and
/// [firstDifference] compare those. [media] — the declared media — decides
/// only whether the embedder can SERVE a request ([canServe]): an embedder
/// loaded for images serves a text-only caller too, so a text index and an
/// image index over one model never close each other's embedder (R5 §4.6).
/// Everything else a caller can vary is per-call — `taskType` is an argument
/// to `embed`, not a property of the model.
@immutable
class ActiveEmbedderParams {
  /// Internal cache identity. The loader supplies core's accelerator
  /// key with [normalizeBackend] false; direct legacy users keep the old
  /// CPU/NPU normalisation by default. Empty paths never identify a model.
  ActiveEmbedderParams({
    required this.modelPath,
    this.tokenizerPath,
    PreferredBackend? preferredBackend,
    Set<EmbeddingModality> media = const {},
    bool normalizeBackend = true,
  }) : activeBackend = normalizeBackend
           ? _resolvedBackend(preferredBackend)
           : preferredBackend,
       media = Set.unmodifiable({
         for (final m in media)
           if (m != EmbeddingModality.text) m,
       }) {
    if (modelPath.isEmpty) {
      throw ArgumentError.value(
        modelPath,
        'modelPath',
        'identifies the embedder, so it cannot be empty',
      );
    }
  }

  /// The file the compiled model opens. Compared instead of the spec NAME,
  /// which is what the shells compared before: reinstalling a same-named model
  /// to a new path was invisible to them.
  final String modelPath;

  /// Resolved by core and baked into the embedding worker at spawn. Null for
  /// a self-contained embedder.
  final String? tokenizerPath;

  /// The media the embedder is (to be) loaded with; text is implied whenever
  /// the model has a text tower, so it is never listed here.
  final Set<EmbeddingModality> media;

  /// Core's accelerator key: the loaded backend for an accelerator-aware
  /// provider, except that an NPU request always retains a distinct NPU key.
  /// Null represents an automatic selection whose placement is not yet known.
  /// Read EmbeddingModel.activeBackend for the loaded accelerator.
  final PreferredBackend? activeBackend;

  /// Legacy CPU/NPU normalisation for direct users of this value type.
  static PreferredBackend _resolvedBackend(PreferredBackend? requested) =>
      requested == PreferredBackend.npu
      ? PreferredBackend.npu
      : PreferredBackend.cpu;

  /// Name of the first field that differs from [other], or null when the cached
  /// identity matches. Media coverage is checked separately by [canServe].
  String? firstDifference(ActiveEmbedderParams other) {
    if (modelPath != other.modelPath) return 'modelPath';
    if (tokenizerPath != other.tokenizerPath) return 'tokenizerPath';
    if (activeBackend != other.activeBackend) return 'activeBackend';
    return null;
  }

  /// Whether an embedder built from these params can serve [requested]: the
  /// same embedder, loaded with every medium [requested] declares.
  bool canServe(ActiveEmbedderParams requested) =>
      firstDifference(requested) == null && media.containsAll(requested.media);

  /// The same embedder, declared with [media] instead.
  ActiveEmbedderParams withMedia(Set<EmbeddingModality> media) =>
      ActiveEmbedderParams(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: activeBackend,
        normalizeBackend: false,
        media: media,
      );

  /// True when [requested] asks for something a legacy CPU-only backend ignores — `gpu` —
  /// so a caller can be told once that it changed nothing. `npu` is not
  /// "ignored" here: whether it ran is the backend's answer, read from the
  /// built model's `activeBackend` (`noticeEmbedderNpuNotApplied`).
  ///
  /// Only for legacy notices; provider capabilities and loaded placement
  /// determine the shared loader's cache key.
  static bool isIgnoredBackend(PreferredBackend? requested) =>
      requested != null && _resolvedBackend(requested) != requested;

  /// Delegates to [firstDifference] rather than repeating its three
  /// comparisons: two copies of one rule is how the copies stop agreeing, and a
  /// fourth field would otherwise have to be remembered in both.
  @override
  bool operator ==(Object other) =>
      other is ActiveEmbedderParams && firstDifference(other) == null;

  /// The same three fields [firstDifference] compares, because `==` delegates
  /// to it — so a fourth field goes in BOTH places, not "both" of `==` and
  /// [firstDifference]. Core resolves automatic reuse and capabilities before
  /// comparing these values; equality itself does not choose an accelerator.
  @override
  int get hashCode => Object.hash(modelPath, tokenizerPath, activeBackend);
}
