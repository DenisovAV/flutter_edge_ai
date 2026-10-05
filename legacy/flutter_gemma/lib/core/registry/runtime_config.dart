import 'package:meta/meta.dart' show immutable;
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show ActivationDataType, PreferredBackend;

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
  /// backends; null for inference. The spec carries source *identities*
  /// (network/asset/file); core
  /// resolves them to on-disk paths via the model manager and passes the
  /// resolved tokenizer path here (install-vs-runtime separation).
  final String? tokenizerPath;

  final PreferredBackend? preferredBackend;

  /// Backend for the VISION encoder, independent of [preferredBackend] (the
  /// text/decoder backend). Null defaults to CPU in the LiteRT-LM engine,
  /// because the vision encoder's `STABLEHLO_COMPOSITE` ops fail to prepare on
  /// the Metal/WebGPU delegates (LiteRT-LM#2461). Set it (e.g. to
  /// `PreferredBackend.gpu`) only for a model whose vision section bakes a
  /// gpu-only `backend_constraint`. Ignored by the MediaPipe engine (whole-model
  /// backend, no per-encoder split).
  final PreferredBackend? preferredVisionBackend;

  /// Backend for the AUDIO encoder, independent of [preferredBackend]. Null
  /// defaults to CPU in the LiteRT-LM engine as a conservative default — but,
  /// unlike the vision encoder, the audio encoder runs fine on GPU and is often
  /// faster there (Gemma 3n audio is ~2× CPU on Metal), so set it to
  /// `PreferredBackend.gpu` for speed. Ignored by MediaPipe.
  final PreferredBackend? preferredAudioBackend;
  final bool supportImage;
  final bool supportAudio;
  final int? maxNumImages;
  final bool? enableSpeculativeDecoding;

  /// Activation type for the native LiteRT-LM engine's text decoder. Null
  /// leaves it to the model file; when set, it overrides LiteRT-LM's own
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
  ///   `flutter_gemma_speech`'s `qwen3SupportedLanguages`, or `'auto'`
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
  /// visible. Three knobs are normalised downstream:
  ///
  ///   * `maxNumImages` is `maxNumImages ?? 1` when vision is on and discarded
  ///     entirely when it is off, in both engines. So null and 1 are the same
  ///     request, and with `supportImage: false` the value is dead.
  ///   * `preferredVisionBackend` / `preferredAudioBackend` default to CPU
  ///     (`encoderBackendWireName(null) == 'cpu'`), which the facade's own doc
  ///     tells callers — so writing the value explicitly followed the
  ///     documentation into a reload.
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
    preferredVisionBackend: preferredVisionBackend ?? PreferredBackend.cpu,
    preferredAudioBackend: preferredAudioBackend ?? PreferredBackend.cpu,
    supportImage: supportImage,
    supportAudio: supportAudio,
    maxNumImages: supportImage ? (maxNumImages ?? 1) : null,
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
    if (preferredVisionBackend != other.preferredVisionBackend) {
      return 'preferredVisionBackend';
    }
    if (preferredAudioBackend != other.preferredAudioBackend) {
      return 'preferredAudioBackend';
    }
    if (supportImage != other.supportImage) return 'supportImage';
    if (supportAudio != other.supportAudio) return 'supportAudio';
    if (maxNumImages != other.maxNumImages) return 'maxNumImages';
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
/// Only three values decide what an embedder IS. Everything else a caller can
/// vary is per-call — `taskType` is an argument to `generateEmbedding`, not a
/// property of the model.
@immutable
class ActiveEmbedderParams {
  /// The requested backend is normalised HERE rather than in a method a caller
  /// has to remember, so [activeBackend] always means "the backend this embedder
  /// was built for" and there is no way to compare un-normalised values by
  /// accident.
  ///
  /// `modelPath` is checked with a throw, not an `assert`. An assert is stripped
  /// in release, and the release failure is not a crash: an empty path makes
  /// every embedder compare equal to every other, so the cache hands back a
  /// stale model's vectors — the exact silent-wrong-data failure this type was
  /// created to prevent. `RuntimeConfig.modelPath` in this same file documents
  /// `''` as the ordinary value on web, so an adopter wiring it straight in is
  /// the reachable route.
  ActiveEmbedderParams({
    required this.modelPath,
    this.tokenizerPath,
    PreferredBackend? preferredBackend,
  }) : activeBackend = _resolvedBackend(preferredBackend) {
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

  /// Resolved by core and baked into the embedding worker at spawn.
  final String? tokenizerPath;

  /// What the embedder actually runs on, which is CPU whatever was asked — ON
  /// NATIVE. The web shell builds this object too, and there it still holds
  /// `cpu` while `EmbeddingModel.activeBackend` is null and the runtime may be
  /// on WebGPU. That is harmless because this field is a cache KEY: it is a
  /// constant, so it can never trigger a rebuild. Read the model's own
  /// `activeBackend` for the answer; do not read this one.
  ///
  /// Named for the answer, not the request — deliberately unlike the
  /// `preferredBackend` on [ActiveModelParams] and `RuntimeConfig`, which do
  /// hold the raw request. The shells build this object and a `RuntimeConfig`
  /// from the same local a few lines apart, so two fields with one name and
  /// opposite meanings is a trap; this one matches
  /// `EmbeddingModel.activeBackend`, which is where the value surfaces.
  final PreferredBackend activeBackend;

  /// The single place the "embeddings run on CPU" fact is written.
  ///
  ///   * LiteRT is CPU-only by decision, not by omission — the GPU delegate
  ///     compiles and then returns all-zero vectors for EmbeddingGemma's int4
  ///     weights (removed in `ab3df2bf`).
  ///   * ONNX never appends an execution provider, so it runs ORT's default
  ///     CPU provider.
  ///
  /// Two requests differing only in the requested backend therefore build the
  /// same model and must NOT rebuild — a rebuild would unload and reload a
  /// bit-identical model at the 570-780 ms compile measured in
  /// `docs/issue-299-embedding-ui-isolate.md`.
  ///
  /// The day a backend honours the value, THREE things change together and this
  /// is only the first: return `requested ?? PreferredBackend.cpu` here (never
  /// the raw value — null and an explicit `cpu` are the same request, which is
  /// why the neighbour normalises its encoder backends the same way), thread the
  /// value into the backend that now reads it, and drop [isIgnoredBackend] so
  /// callers stop being told it did nothing.
  static PreferredBackend _resolvedBackend(PreferredBackend? requested) =>
      PreferredBackend.cpu;

  /// Name of the first field that differs from [other], or null when the cached
  /// embedder can be reused. No normalisation step to forget: the constructor
  /// already did it.
  String? firstDifference(ActiveEmbedderParams other) {
    if (modelPath != other.modelPath) return 'modelPath';
    if (tokenizerPath != other.tokenizerPath) return 'tokenizerPath';
    if (activeBackend != other.activeBackend) return 'activeBackend';
    return null;
  }

  /// True when [requested] asks for something other than what an embedder
  /// actually uses, so a caller can be told once that it changed nothing.
  ///
  /// Derived from [_resolvedBackend] rather than repeating the CPU constant, so
  /// the fact still has exactly one site: the day that method returns the
  /// request, this stops speaking on its own.
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
  /// [firstDifference]. And if [firstDifference] ever normalises its inputs, as
  /// [ActiveModelParams.firstDifference] does, hash the normalised values too,
  /// or two objects would compare equal with different hashes and break every
  /// `Map` and `Set` holding them. This one is safe today only because it
  /// normalises in the constructor instead.
  @override
  int get hashCode => Object.hash(modelPath, tokenizerPath, activeBackend);
}
