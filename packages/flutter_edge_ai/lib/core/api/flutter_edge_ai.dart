import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter_edge_ai/core/api/inference_installation_builder.dart';
import 'package:flutter_edge_ai/core/api/embedding_installation_builder.dart';
import 'package:flutter_edge_ai/core/api/stt_installation_builder.dart';
import 'package:flutter_edge_ai/core/api/tts_installation_builder.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/services/file_system_service.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/domain/web_storage_mode.dart';
import 'package:flutter_edge_ai/core/infrastructure/web_download_service_stub.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/core/infrastructure/web_download_service.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/stt_registry.dart';
import 'package:flutter_edge_ai/core/registry/tts_registry.dart';
import 'package:flutter_edge_ai/core/registry/skill_executor_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_source.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_tokenizer_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_tokenizer_registry.dart';
import 'package:flutter_edge_ai/core/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/skill_executor_provider.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';

/// Modern API facade for Flutter Edge AI
///
/// Provides clean, type-safe API for model management and inference.
///
/// ## Initialization
///
/// Initialize once at app startup:
/// ```dart
/// void main() {
///   FlutterEdgeAi.initialize(
///     huggingFaceToken: 'hf_...',     // Optional: for gated models
///     maxDownloadRetries: 10,         // Optional: default is 10
///   );
///   runApp(MyApp());
/// }
/// ```
///
/// ## Install Models
///
/// ```dart
/// // From network
/// final installation = await FlutterEdgeAi.installModel(
///   modelType: ModelType.gemmaIt,
/// )
///   .fromNetwork('https://huggingface.co/.../model.bin')
///   .withProgress((progress) => print('Progress: $progress%'))
///   .install();
///
/// // From asset
/// await FlutterEdgeAi.installModel(
///   modelType: ModelType.gemmaIt,
/// )
///   .fromAsset('models/gemma.bin')
///   .install();
///
/// // From bundled resource
/// await FlutterEdgeAi.installModel(
///   modelType: ModelType.gemmaIt,
/// )
///   .fromBundled('gemma.bin')
///   .install();
///
/// // From external file
/// await FlutterEdgeAi.installModel(
///   modelType: ModelType.gemmaIt,
/// )
///   .fromFile('/path/to/model.bin')
///   .install();
/// ```
///
/// ## Load Models
///
/// ```dart
/// // Get active model after installation
/// final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
/// final session = await model.createSession();
/// final response = await session.getResponse();
/// ```
class FlutterEdgeAi {
  /// Controls flutter_edge_ai's internal log verbosity.
  ///
  /// Debug builds only -- release builds are always silent regardless of this
  /// value (no model output / prompts leak into logcat/syslog). Default
  /// [EdgeAiLogLevel.info]. Use [EdgeAiLogLevel.verbose] to see model output and
  /// prompts while debugging, or [EdgeAiLogLevel.none] to silence the plugin.
  ///
  /// Note: this is a process-global, per-isolate setting; set it once at
  /// startup. Background isolates snapshot the value at spawn time.
  static EdgeAiLogLevel get logLevel => edgeAiLogLevel;
  static set logLevel(EdgeAiLogLevel value) => edgeAiLogLevel = value;

  /// Initialize Flutter Edge AI
  ///
  /// Call this once at app startup before using any other API.
  ///
  /// Parameters:
  /// - [huggingFaceToken]: Optional HuggingFace API token for authenticated downloads
  /// - [maxDownloadRetries]: Maximum retry attempts for transient errors (default: 10)
  ///   Note: Auth errors (401/403/404) always fail after 1 attempt
  /// - [webStorageMode]: Storage mode for web platform (default: WebStorageMode.cacheApi)
  ///   - cacheApi: Cache API with Blob URLs (for models <2GB)
  ///   - streaming: OPFS with streaming (for models >2GB like E4B, 7B, 27B)
  ///   - none: No caching (ephemeral, for development)
  ///   Note: This parameter only affects web platform, ignored on mobile
  /// - [enableWebCache]: DEPRECATED - Use webStorageMode instead.
  ///   Converts to webStorageMode internally; still accepted in 2.0.
  ///
  /// Example:
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///
  ///   // For small models (<2GB) - default
  ///   await FlutterEdgeAi.initialize();
  ///
  ///   // For large models (>2GB)
  ///   await FlutterEdgeAi.initialize(
  ///     webStorageMode: WebStorageMode.streaming,
  ///   );
  ///
  ///   runApp(MyApp());
  /// }
  /// ```
  static Future<void> initialize({
    String? huggingFaceToken,
    int maxDownloadRetries = 10,
    WebStorageMode webStorageMode = WebStorageMode.cacheApi,
    @Deprecated('Use webStorageMode instead.') bool? enableWebCache,
    // Opt-in registration. Engines/backends are FULLY opt-in: core registers
    // NONE by default. Pass the providers from the packages you use, e.g.
    // `LiteRtLmEngine()` (flutter_edge_ai_litertlm), `MediaPipeEngine()`
    // (flutter_edge_ai_mediapipe), `LiteRtEmbeddingBackend()`
    // (flutter_edge_ai_litertlm), `GemmaEmbeddingTokenizers()`
    // (flutter_edge_ai_embeddings). If the lists are empty, the first
    // createModel / createEmbeddingModel throws a clear "add the engine
    // package" StateError.
    List<InferenceEngineProvider> inferenceEngines = const [],
    List<EmbeddingBackendProvider> embeddingBackends = const [],
    // Which tokenizer a model needs is a property of the MODEL, not of the
    // engine running it, so the engine asks for one instead of naming one.
    // Implementations live in flutter_edge_ai_embeddings (they pull
    // dart_sentencepiece_tokenizer); core holds only the contract. Empty
    // default: an app that never embeds passes nothing and pays nothing.
    List<EmbeddingTokenizerProvider> embeddingTokenizers = const [],
    List<SttBackendProvider> sttBackends = const [],
    List<TtsBackendProvider> ttsBackends = const [],
    // Opt-in agentic "skills" runtime, provided by the `flutter_edge_ai_agent`
    // package (each executor `implements SkillExecutorProvider`). Core holds
    // only this list + the probe-chain [SkillExecutorRegistry]; the concrete
    // `SkillExecutor` / `SkillResult` types live in the agent package so core
    // stays dependency-free (no webview_flutter / url_launcher). Empty default
    // is a no-op — existing apps are unaffected.
    List<SkillExecutorProvider> skillExecutors = const [],
    // Opt-in resolvers that turn a Hugging Face repo id into a
    // [ResolvedHfModel] by reading that repo's deployment metadata (e.g.
    // flutter_edge_ai_litertlm reads `litertlm_manifest.json`). Consumed by
    // [resolveHuggingFace]; empty default is a no-op (that call then throws a
    // clear "no resolver registered" error).
    List<HuggingFaceResolver> huggingFaceResolvers = const [],

    /// Optional host-provided broadcast of download task updates (mobile).
    ///
    /// On iOS/Android, events must be [TaskUpdate] values from
    /// `package:background_downloader` — the same shape as
    /// [FileDownloader.updates]. Ignored on web.
    ///
    /// **You almost certainly do not need this.** When omitted, flutter_edge_ai
    /// registers callbacks scoped to its own task group and never touches
    /// `FileDownloader().updates`, so the stream stays entirely yours (#445).
    ///
    /// Do NOT pass a stream sourced from `FileDownloader().updates` itself:
    /// that stream takes a single subscription, so forwarding it here recreates
    /// the exact conflict this option once existed to work around. Pass a hub
    /// only if you genuinely synthesise task updates from somewhere else.
    Stream<Object>? downloadUpdatesStream,

    /// Optional custom model file storage (e.g. outside Documents).
    ///
    /// [FileSystemService] is exported from the public barrel
    /// (`package:flutter_edge_ai/flutter_edge_ai.dart`); pass an
    /// implementation from your app or tests.
    FileSystemService? fileSystemService,
  }) async {
    // Migration: enableWebCache takes precedence if provided (for backward compatibility)
    final effectiveStorageMode = enableWebCache != null
        ? (enableWebCache ? WebStorageMode.cacheApi : WebStorageMode.none)
        : webStorageMode;

    await ServiceRegistry.initialize(
      huggingFaceToken: huggingFaceToken,
      maxDownloadRetries: maxDownloadRetries,
      webStorageMode: effectiveStorageMode,
      downloadUpdatesStream: downloadUpdatesStream,
      fileSystemService: fileSystemService,
    );

    if (inferenceEngines.isNotEmpty) {
      EngineRegistry.instance.registerAll(inferenceEngines);
    }
    if (embeddingBackends.isNotEmpty) {
      EmbeddingRegistry.instance.registerAll(embeddingBackends);
    }
    if (embeddingTokenizers.isNotEmpty) {
      EmbeddingTokenizerRegistry.instance.registerAll(embeddingTokenizers);
    }
    if (sttBackends.isNotEmpty) {
      SttRegistry.instance.registerAll(sttBackends);
    }
    if (ttsBackends.isNotEmpty) {
      TtsRegistry.instance.registerAll(ttsBackends);
    }
    if (skillExecutors.isNotEmpty) {
      SkillExecutorRegistry.instance.registerAll(skillExecutors);
    }
    if (huggingFaceResolvers.isNotEmpty) {
      HuggingFaceResolverRegistry.instance.registerAll(huggingFaceResolvers);
    }
    // Auto-register resolvers that ride on the engines themselves (an engine
    // that `implements HuggingFaceResolverSource` — LiteRtLmEngine, OnnxEngine,
    // BuiltInAiEngine). Registered AFTER the explicit list so an app-supplied
    // resolver wins the equal-priority tie (findFor: first-registered). Dedup
    // is handled by registerAll (a `const` resolver passed both explicitly and
    // via its engine is the same instance → registered once).
    final engineResolvers = engineHuggingFaceResolvers(inferenceEngines);
    if (engineResolvers.isNotEmpty) {
      HuggingFaceResolverRegistry.instance.registerAll(engineResolvers);
    }

    // Single-flight model-manager init: restore the previously-active model
    // identity from storage before the app reads it (#227/#314). Awaited here
    // so the first getActiveModel/isModelInstalled after initialize() can't
    // race an in-flight restore. Restore failure degrades to no-active-model.
    await FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
  }

  /// Start building an inference model installation
  ///
  /// Returns type-safe builder for installing inference models with optional LoRA weights.
  /// The model will be automatically set as the active inference model after installation.
  ///
  /// Parameters:
  /// - [modelType]: Model type (gemmaIt, deepSeek, qwen, etc.) - Required
  /// - [fileType]: File type (task or binary) - Defaults to task
  ///
  /// Example:
  /// ```dart
  /// // Install Gemma model
  /// await FlutterEdgeAi.installModel(
  ///   modelType: ModelType.gemmaIt,
  /// )
  ///   .fromNetwork('https://example.com/model.task', token: 'hf_...')
  ///   .withProgress((p) => print('$p%'))
  ///   .install();
  ///
  /// // Install DeepSeek with LoRA weights
  /// await FlutterEdgeAi.installModel(
  ///   modelType: ModelType.deepSeek,
  /// )
  ///   .fromNetwork('https://example.com/model.task')
  ///   .withLoraFromNetwork('https://example.com/lora.bin')
  ///   .install();
  /// ```
  static InferenceInstallationBuilder installModel({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
  }) {
    return InferenceInstallationBuilder(
      modelType: modelType,
      fileType: fileType,
    );
  }

  /// Start building an embedding model installation
  ///
  /// Returns type-safe builder for installing embedding models (requires model + tokenizer).
  /// The model will be automatically set as the active embedding model after installation.
  ///
  /// Example:
  /// ```dart
  /// await FlutterEdgeAi.installEmbedder()
  ///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
  ///   .tokenizerFromNetwork('https://example.com/tokenizer.model', token: 'hf_...')
  ///   .withModelProgress((p) => print('Model: $p%'))
  ///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
  ///   .install();
  /// ```
  static EmbeddingInstallationBuilder installEmbedder() {
    return EmbeddingInstallationBuilder();
  }

  /// Start building an STT (speech-to-text) model installation
  ///
  /// Returns a type-safe builder for installing STT models (requires model +
  /// tokenizer + [SttInstallationBuilder.ofType]). The model will be
  /// automatically set as the active STT model after installation.
  ///
  /// Example:
  /// ```dart
  /// await FlutterEdgeAi.installStt()
  ///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
  ///   .tokenizerFromNetwork('https://example.com/tokenizer.json', token: 'hf_...')
  ///   .ofType(SttModelType.moonshine)
  ///   .withModelProgress((p) => print('Model: $p%'))
  ///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
  ///   .install();
  /// ```
  static SttInstallationBuilder installStt() {
    return SttInstallationBuilder();
  }

  /// Start building a TTS (text-to-speech) model installation
  ///
  /// Returns a type-safe builder for installing TTS models (a bundle of
  /// files, see [TtsInstallationBuilder.ofType]). The model will be
  /// automatically set as the active TTS model after installation.
  ///
  /// Example:
  /// ```dart
  /// await FlutterEdgeAi.installTts()
  ///   .fromNetwork('https://example.com/matcha/', token: 'hf_...')
  ///   .ofType(TtsModelType.matcha)
  ///   .withProgress((p) => print('$p%'))
  ///   .install();
  /// ```
  static TtsInstallationBuilder installTts() {
    return TtsInstallationBuilder();
  }

  /// Check if a model is installed
  ///
  /// Parameters:
  /// - [modelId]: Model filename (e.g., 'gemma-2b-it-cpu-int4.bin')
  static Future<bool> isModelInstalled(String modelId) async {
    final repository = ServiceRegistry.instance.modelRepository;
    return await repository.isInstalled(modelId);
  }

  /// List all installed models
  static Future<List<String>> listInstalledModels() async {
    final repository = ServiceRegistry.instance.modelRepository;
    final models = await repository.listInstalled();
    return models.map((m) => m.id).toList();
  }

  /// Get the active inference model as a ready-to-use InferenceModel
  ///
  /// Returns an InferenceModel configured with runtime parameters.
  /// The model type and file type come from the active InferenceModelSpec.
  ///
  /// Runtime parameters:
  /// - [maxTokens]: Maximum context size (default: 1024)
  /// - [preferredBackend]: CPU or GPU preference (optional)
  /// - [preferredVisionBackend]: vision-encoder backend override; null
  /// defaults to CPU (optional)
  /// - [preferredAudioBackend]: audio-encoder backend override; null defaults to CPU (optional)
  /// - [supportImage]: Enable multimodal image support (default: false)
  /// - [supportAudio]: Enable audio input support for Gemma 3n E4B (default: false)
  /// - [maxNumImages]: Maximum number of images if supportImage is true
  /// - [activationDataType]: activation type for the text decoder of native
  ///   `.litertlm` models (Android, iOS, desktop); null honors the model file,
  ///   and a value overrides LiteRT-LM's own choice (float16 on GPU by
  ///   default). Pass
  ///   [ActivationDataType.float32] if the GPU writes wrong digits — it needs
  ///   more GPU memory, and a GPU engine that cannot be created falls back to
  ///   CPU silently, so check `activeBackend` afterwards. MediaPipe, ONNX,
  ///   built-in AI and the web engines ignore it (optional)
  /// - [defaults]: overridable runtime defaults from a HF manifest (see
  ///   [resolveHuggingFace] / [ResolvedHfModel.runtime]). Each explicit argument
  ///   above wins over the matching field here, which in turn wins over the SDK
  ///   default — so `getActiveModel(defaults: r.runtime)` applies the manifest's
  ///   guidance and `getActiveModel()` behaves exactly as before. NOTE: the two
  ///   session-level fields (`thinkingDeclared`, `minOutputTokens`) are NOT applied
  ///   here — forward them to `createSession` yourself.
  ///
  /// Throws:
  /// - [StateError] if no active inference model is set
  ///
  /// Example:
  /// ```dart
  /// // Install model first
  /// await FlutterEdgeAi.installModel(
  ///   modelType: ModelType.gemmaIt,
  /// ).fromNetwork('https://example.com/model.task').install();
  ///
  /// // Create with short context
  /// final shortModel = await FlutterEdgeAi.getActiveModel(
  ///   maxTokens: 512,
  /// );
  ///
  /// // Create with long context and GPU
  /// final longModel = await FlutterEdgeAi.getActiveModel(
  ///   maxTokens: 4096,
  ///   preferredBackend: PreferredBackend.gpu,
  /// );
  ///
  /// // Create with audio support (Gemma 3n E4B only)
  /// final audioModel = await FlutterEdgeAi.getActiveModel(
  ///   supportAudio: true,
  /// );
  /// ```
  static Future<InferenceModel> getActiveModel({
    ModelRuntimeDefaults? defaults,
    int? maxTokens,
    PreferredBackend? preferredBackend,
    PreferredBackend? preferredVisionBackend,
    PreferredBackend? preferredAudioBackend,
    bool? supportImage,
    bool? supportAudio,
    int? maxNumImages,
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeInferenceModel;

    if (activeSpec == null) {
      throw StateError(
        'No active inference model set. Use FlutterEdgeAi.installModel() first.',
      );
    }

    if (activeSpec is! InferenceModelSpec) {
      throw StateError(
        'Active model is not an InferenceModelSpec. '
        'Expected InferenceModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    // Merge precedence: explicit argument > manifest [defaults] > SDK default.
    // maxTokens keeps its historical 1024 fallback, so an omitted arg with no
    // defaults behaves exactly as before. The .litertlm engine still clamps
    // this value downstream (clampLitertlmContextTokens) — a manifest cannot
    // set a context window the engine rejects (guards #318).
    final effMaxTokens = mergeRuntimeDefault(
      maxTokens,
      defaults?.maxTokens,
      1024,
    );
    final effPreferredBackend = preferredBackend ?? defaults?.preferredBackend;
    final effSupportImage = mergeRuntimeDefault(
      supportImage,
      defaults?.supportImage,
      false,
    );
    final effSupportAudio = mergeRuntimeDefault(
      supportAudio,
      defaults?.supportAudio,
      false,
    );

    // [defaults] also carries two SESSION-level fields (thinkingDeclared,
    // minOutputTokens) that this model-level call cannot apply. Warn (debug
    // builds) so a caller who passes `defaults:` here and forgets to forward
    // them to createSession finds out, instead of a reasoning model silently
    // truncating mid-<think>.
    if (defaults != null &&
        (defaults.thinkingDeclared != null || defaults.minOutputTokens != null)) {
      edgeAiLog(
        '[flutter_edge_ai] getActiveModel: manifest defaults carry session-level '
        'fields (thinkingDeclared/minOutputTokens) that getActiveModel does not apply '
        '— forward them to createSession(enableThinking:, maxOutputTokens:).',
      );
    }

    // Create InferenceModel using identity from spec + runtime params
    return await FlutterEdgeAiPlugin.instance.createModel(
      modelType: activeSpec.modelType,
      fileType: activeSpec.fileType,
      maxTokens: effMaxTokens,
      preferredBackend: effPreferredBackend,
      preferredVisionBackend: preferredVisionBackend,
      preferredAudioBackend: preferredAudioBackend,
      supportImage: effSupportImage,
      supportAudio: effSupportAudio,
      maxNumImages: maxNumImages,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      activationDataType: activationDataType,
      maxConcurrentSessions: maxConcurrentSessions,
    );
  }

  /// The Hugging Face resolvers contributed by [engines] that implement
  /// [HuggingFaceResolverSource] (e.g. `LiteRtLmEngine` → `LitertlmManifestResolver`).
  /// [initialize] registers these AFTER the explicit `huggingFaceResolvers:`
  /// list, so an app's explicit resolver wins the equal-priority tie. An engine
  /// that does not implement [HuggingFaceResolverSource] contributes nothing.
  /// Extracted so the derivation is unit-testable without a full [initialize].
  @visibleForTesting
  static List<HuggingFaceResolver> engineHuggingFaceResolvers(
    List<InferenceEngineProvider> engines,
  ) {
    final resolvers = <HuggingFaceResolver>[];
    for (final e in engines) {
      // Bind via pattern: HuggingFaceResolverSource is not a subtype of
      // InferenceEngineProvider, so a plain `is` check would not promote `e`.
      if (e case final HuggingFaceResolverSource source) {
        resolvers.add(source.huggingFaceResolver);
      }
    }
    return resolvers;
  }

  /// Three-tier runtime-default merge used by [getActiveModel]: an explicit
  /// argument wins over a manifest [ModelRuntimeDefaults] value, which wins over
  /// the SDK default. Extracted so the precedence rule is stated — and tested —
  /// in one place.
  @visibleForTesting
  static T mergeRuntimeDefault<T>(T? explicit, T? manifest, T sdkDefault) =>
      explicit ?? manifest ?? sdkDefault;

  /// Resolves a Hugging Face repo id into a [ResolvedHfModel] by reading that
  /// repo's deployment metadata (e.g. `litertlm_manifest.json`), using a
  /// resolver registered via `initialize` — either passed in
  /// `huggingFaceResolvers:` or auto-derived from a registered engine that ships
  /// one (LiteRtLmEngine, OnnxEngine, BuiltInAiEngine).
  ///
  /// This is the INSPECT-ONLY path (resolve, then install yourself). To resolve
  /// AND install in one call, use `installModel(...).fromHuggingFace(repo)` with
  /// no `file:` — it resolves the manifest internally, installs the
  /// revision-pinned variant, and returns the runtime defaults on
  /// `InferenceInstallation.runtime`.
  ///
  /// [fileType] tells the registry which resolver to pick (the litertlm
  /// resolver claims `ModelFileType.litertlm`); it is the only deterministic
  /// selection signal a resolver has before it fetches the manifest.
  ///
  /// The result carries install identity ([ResolvedHfModel.modelType] /
  /// [ResolvedHfModel.fileType] for [installModel], and [ResolvedHfModel.url]
  /// for the download) plus overridable [ResolvedHfModel.runtime] defaults.
  /// Apply the model-level defaults with `getActiveModel(defaults:)`; forward
  /// the two session-level fields to `createSession` yourself. Install from
  /// [ResolvedHfModel.url] (not `fromHuggingFace(repo, file:)`) so a resolver's
  /// pinned revision is honoured — the plugin still auto-applies the HF token
  /// to `huggingface.co` hosts:
  ///
  /// ```dart
  /// final r = await FlutterEdgeAi.resolveHuggingFace(
  ///     repo, fileType: ModelFileType.litertlm);
  /// await FlutterEdgeAi.installModel(
  ///       modelType: r.modelType ?? ModelType.general,
  ///       fileType: r.fileType,
  ///     )
  ///     .fromNetwork(r.url)
  ///     .install();
  /// final model = await FlutterEdgeAi.getActiveModel(defaults: r.runtime);
  /// // minOutputTokens is a FLOOR, not a cap — leave maxOutputTokens unset (or
  /// // keep it >= r.runtime.minOutputTokens); passing the floor AS the cap
  /// // would truncate a reasoning model mid-thought.
  /// final session = await model.createSession(
  ///   enableThinking: r.runtime.thinkingDeclared ?? false,
  /// );
  /// ```
  ///
  /// [token] defaults to the token passed to [initialize]. Throws [StateError]
  /// if no registered resolver handles [repo] — add the engine package that
  /// provides one (e.g. flutter_edge_ai_litertlm for `.litertlm` manifests).
  static Future<ResolvedHfModel> resolveHuggingFace(
    String repo, {
    ModelFileType? fileType,
    String? token,
    PreferredBackend? preferredBackend,
  }) async {
    final resolver = HuggingFaceResolverRegistry.instance.findFor(
      repo,
      fileType: fileType,
    );
    if (resolver == null) {
      throw StateError(
        'No Hugging Face resolver registered for "$repo" (fileType: $fileType). '
        'Register the engine that provides one — its resolver auto-registers via '
        'HuggingFaceResolverSource (e.g. LiteRtLmEngine ships the litertlm '
        'manifest resolver) — or pass one explicitly to '
        'FlutterEdgeAi.initialize(huggingFaceResolvers: [...]).',
      );
    }
    return resolver.resolve(
      repo,
      token: token ?? ServiceRegistry.instance.huggingFaceToken,
      platform: _currentPlatformKey(),
      preferredBackend: preferredBackend,
    );
  }

  /// Lowercase platform key passed to [HuggingFaceResolver.resolve] so a
  /// resolver can honour per-platform recommendations. Returns `'unknown'` for
  /// any host not in the resolver contract's documented set (e.g. a future
  /// `TargetPlatform`); resolvers treat that as "no per-platform hint".
  static String _currentPlatformKey() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        edgeAiLog(
          '[flutter_edge_ai] resolveHuggingFace: no platform key for '
          '$defaultTargetPlatform — passing "unknown" to the resolver, which '
          'will fall back to its default (no per-platform recommendation).',
        );
        return 'unknown';
    }
  }

  /// Check if there's an active inference model
  ///
  /// Returns true if an inference model has been installed and set as active.
  ///
  /// Example:
  /// ```dart
  /// if (FlutterEdgeAi.hasActiveModel()) {
  ///   final model = await FlutterEdgeAi.getActiveModel();
  ///   // Use model...
  /// } else {
  ///   // Install model first
  /// }
  /// ```
  static bool hasActiveModel() {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    return manager.activeInferenceModel is InferenceModelSpec;
  }

  /// Get the active embedding model as a ready-to-use EmbeddingModel
  ///
  /// Returns an EmbeddingModel configured with runtime parameters.
  /// The model and tokenizer paths come from the active EmbeddingModelSpec.
  ///
  /// Runtime parameters:
  /// - [preferredBackend]: accepted for symmetry with [getActiveModel], and
  ///   **not applied**. On native every backend runs the forward pass on CPU:
  ///   LiteRT's GPU delegate returns all-zero vectors for EmbeddingGemma's
  ///   int4 weights, and the ONNX client appends no execution provider. On web
  ///   the runtime chooses for itself and the argument is equally ignored.
  ///   Passing anything other than [PreferredBackend.cpu] logs a line once per
  ///   isolate in debug builds; read [EmbeddingModel.activeBackend] for the
  ///   backend in use, which is available in release builds too.
  ///
  /// Throws:
  /// - [StateError] if no active embedding model is set
  /// - `TimeoutException` if the previous embedder is still closing after
  ///   60 s; its close keeps running, and a later call succeeds once it ends.
  ///
  /// Example:
  /// ```dart
  /// // Install embedding model first
  /// await FlutterEdgeAi.installEmbedder()
  ///   .modelFromNetwork('https://example.com/model.tflite')
  ///   .tokenizerFromNetwork('https://example.com/tokenizer.model')
  ///   .install();
  ///
  /// final embedder = await FlutterEdgeAi.getActiveEmbedder();
  ///
  /// // Where the backend matters, ask — do not assume the argument took.
  /// // Native answers PreferredBackend.cpu; web answers null, because there
  /// // the accelerator is not known until the first embedding.
  /// debugPrint('embedding on ${embedder.activeBackend}');
  /// ```
  static Future<EmbeddingModel> getActiveEmbedder({
    PreferredBackend? preferredBackend,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeEmbeddingModel;

    if (activeSpec == null) {
      throw StateError(
        'No active embedding model set. Use FlutterEdgeAi.installEmbedder() first.',
      );
    }

    if (activeSpec is! EmbeddingModelSpec) {
      throw StateError(
        'Active model is not an EmbeddingModelSpec. '
        'Expected EmbeddingModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    // Create EmbeddingModel using active spec (paths resolved automatically)
    return await FlutterEdgeAiPlugin.instance.createEmbeddingModel(
      preferredBackend: preferredBackend,
    );
  }

  /// Check if there's an active embedding model
  ///
  /// Returns true if an embedding model has been installed and set as active.
  ///
  /// Example:
  /// ```dart
  /// if (FlutterEdgeAi.hasActiveEmbedder()) {
  ///   final model = await FlutterEdgeAi.getActiveEmbedder();
  ///   // Use model...
  /// } else {
  ///   // Install model first
  /// }
  /// ```
  static bool hasActiveEmbedder() {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    return manager.activeEmbeddingModel is EmbeddingModelSpec;
  }

  /// Get the active STT model as a ready-to-use [SpeechRecognizer]
  ///
  /// Returns a [SpeechRecognizer] configured with runtime parameters. The
  /// model and tokenizer paths come from the active [SttModelSpec].
  ///
  /// Runtime parameters:
  /// - [preferredBackend]: CPU or GPU preference (optional)
  /// - [language]: the OUTPUT language for transcripts (Whisper only) — a bare
  ///   lowercase code such as `'en'` or `'de'`. Sets
  ///   [SpeechRecognizer.language], and retargets the recognizer if one already
  ///   exists, so it takes effect on every call and not just the first.
  ///   Override a single transcription with
  ///   [SpeechRecognizer.transcribe]'s own `language` instead.
  ///
  /// Throws:
  /// - [StateError] if no active STT model is set
  /// - [ArgumentError] for a malformed [language], or for any [language] on a
  ///   model whose decoder prompt has no language token (moonshine, parakeet)
  ///
  /// Example:
  /// ```dart
  /// // Install STT model first
  /// await FlutterEdgeAi.installStt()
  ///   .modelFromNetwork('https://example.com/model.tflite')
  ///   .tokenizerFromNetwork('https://example.com/tokenizer.json')
  ///   .ofType(SttModelType.moonshine)
  ///   .install();
  ///
  /// // Create with default backend
  /// final recognizer = await FlutterEdgeAi.getActiveStt();
  ///
  /// // Whisper: transcribe German, then French, on the SAME recognizer —
  /// // nothing is reloaded between the two.
  /// final de = await FlutterEdgeAi.getActiveStt(language: 'de');
  /// final german = await de.transcribe(germanPcm);
  /// final french = await de.transcribe(frenchPcm, language: 'fr');
  /// ```
  static Future<SpeechRecognizer> getActiveStt({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeSttModel;

    if (activeSpec == null) {
      throw StateError(
        'No active STT model set. Use FlutterEdgeAi.installStt() first.',
      );
    }

    if (activeSpec is! SttModelSpec) {
      throw StateError(
        'Active model is not an SttModelSpec. '
        'Expected SttModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    // Create SpeechRecognizer using active spec (paths resolved automatically)
    return await FlutterEdgeAiPlugin.instance.createSttModel(
      preferredBackend: preferredBackend,
      language: language,
    );
  }

  /// Check if there's an active STT model
  ///
  /// Returns true if an STT model has been installed and set as active.
  static bool hasActiveStt() {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    return manager.activeSttModel is SttModelSpec;
  }

  /// Get the active TTS model as a ready-to-use [SpeechSynthesizer]
  ///
  /// Returns a [SpeechSynthesizer] configured with runtime parameters. The
  /// bundle paths come from the active [TtsModelSpec].
  ///
  /// Runtime parameters:
  /// - [preferredBackend]: CPU or GPU preference (optional)
  /// - [language]: TTS-only (Qwen3; ignored by Matcha, whose locale comes
  ///   from its bundle instead) — one of `flutter_edge_ai_speech`'s
  ///   `qwen3SupportedLanguages`, or `'auto'`; defaults to `'english'` when
  ///   null. An unsupported value throws `ArgumentError` before the model
  ///   loads. A previously-created synthesizer for the same active model is
  ///   reused across calls (create-time singleton) — to pick up a new
  ///   [language], [close][SpeechSynthesizer.close] it first.
  ///
  /// Throws:
  /// - [StateError] if no active TTS model is set
  ///
  /// Example:
  /// ```dart
  /// // Install TTS model first
  /// await FlutterEdgeAi.installTts()
  ///   .fromNetwork('https://example.com/matcha/')
  ///   .ofType(TtsModelType.matcha)
  ///   .install();
  ///
  /// // Create with default backend
  /// final synthesizer = await FlutterEdgeAi.getActiveTts();
  /// ```
  static Future<SpeechSynthesizer> getActiveTts({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeTtsModel;

    if (activeSpec == null) {
      throw StateError(
        'No active TTS model set. Use FlutterEdgeAi.installTts() first.',
      );
    }

    if (activeSpec is! TtsModelSpec) {
      throw StateError(
        'Active model is not a TtsModelSpec. '
        'Expected TtsModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    // Create SpeechSynthesizer using active spec (paths resolved automatically)
    return await FlutterEdgeAiPlugin.instance.createTtsModel(
      preferredBackend: preferredBackend,
      language: language,
    );
  }

  /// Check if there's an active TTS model
  ///
  /// Returns true if a TTS model has been installed and set as active.
  static bool hasActiveTts() {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    return manager.activeTtsModel is TtsModelSpec;
  }

  /// The active inference model's identity (its [InferenceModelSpec]), or null
  /// if none is set. Cheap synchronous read — does NOT load the engine (use
  /// [getActiveModel] for that). `hasActiveModel() == (activeModelSpec != null)`.
  static InferenceModelSpec? get activeModelSpec {
    final spec = FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel;
    if (spec == null || spec is InferenceModelSpec) {
      return spec as InferenceModelSpec?;
    }
    edgeAiLog(
      'activeModelSpec: active inference slot holds a ${spec.runtimeType}, '
      'not an InferenceModelSpec — returning null (invariant violation).',
    );
    return null;
  }

  /// The active embedding model's identity ([EmbeddingModelSpec]), or null.
  static EmbeddingModelSpec? get activeEmbedderSpec {
    final spec = FlutterEdgeAiPlugin.instance.modelManager.activeEmbeddingModel;
    if (spec == null || spec is EmbeddingModelSpec) {
      return spec as EmbeddingModelSpec?;
    }
    edgeAiLog(
      'activeEmbedderSpec: active embedding slot holds a ${spec.runtimeType}, '
      'not an EmbeddingModelSpec — returning null (invariant violation).',
    );
    return null;
  }

  /// The active STT model's identity ([SttModelSpec]), or null.
  static SttModelSpec? get activeSttSpec {
    final spec = FlutterEdgeAiPlugin.instance.modelManager.activeSttModel;
    if (spec == null || spec is SttModelSpec) {
      return spec as SttModelSpec?;
    }
    edgeAiLog(
      'activeSttSpec: active STT slot holds a ${spec.runtimeType}, '
      'not an SttModelSpec — returning null (invariant violation).',
    );
    return null;
  }

  /// The active TTS model's identity ([TtsModelSpec]), or null.
  static TtsModelSpec? get activeTtsSpec {
    final spec = FlutterEdgeAiPlugin.instance.modelManager.activeTtsModel;
    if (spec == null || spec is TtsModelSpec) {
      return spec as TtsModelSpec?;
    }
    edgeAiLog(
      'activeTtsSpec: active TTS slot holds a ${spec.runtimeType}, '
      'not an TtsModelSpec — returning null (invariant violation).',
    );
    return null;
  }

  /// Absolute on-device read path for an installed model file, keyed by its
  /// [fileName] (the file's basename, e.g. `gemma-4-E2B-it.litertlm`). On web
  /// this resolves to a URL/OPFS handle, not a filesystem path. The path is
  /// computed, not stat-ed — it is returned even if nothing is installed there.
  static Future<String> getModelPath(String fileName) async {
    // A FileSource install references the file in place (not copied) and
    // registers it under its (possibly namespaced) filename -> its original
    // path. Resolve that first so getModelPath returns where the file ACTUALLY
    // is; otherwise fall back to the managed read path (downloaded/asset
    // installs land in the managed dir under their filename). Without this, a
    // namespaced companion (e.g. `<model>__tokenizer.json`) whose FileSource
    // file lives elsewhere would resolve to a non-existent managed path.
    final external = await ServiceRegistry.instance.protectedFilesRegistry
        .getExternalPath(fileName);
    if (external != null) return external;
    return ServiceRegistry.instance.fileSystemService.getReadTargetPath(
      fileName,
    );
  }

  /// Clears the active inference identity (in-memory spec + persisted prefs).
  static Future<void> clearActiveInferenceIdentity() =>
      FlutterEdgeAiPlugin.instance.modelManager.clearActiveInferenceIdentity();

  /// Clears the active embedding identity (in-memory spec + persisted prefs).
  static Future<void> clearActiveEmbeddingIdentity() =>
      FlutterEdgeAiPlugin.instance.modelManager.clearActiveEmbeddingIdentity();

  /// Clears the active STT identity (in-memory spec + persisted prefs).
  static Future<void> clearActiveSttIdentity() =>
      FlutterEdgeAiPlugin.instance.modelManager.clearActiveSttIdentity();

  /// Clears the active TTS identity (in-memory spec + persisted prefs).
  static Future<void> clearActiveTtsIdentity() =>
      FlutterEdgeAiPlugin.instance.modelManager.clearActiveTtsIdentity();

  /// Uninstall a model
  ///
  /// Removes model metadata and files (if not protected).
  ///
  /// Parameters:
  /// - [modelId]: Model filename to uninstall
  static Future<void> uninstallModel(String modelId) async {
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final fileSystem = registry.fileSystemService;

    // Get model info
    final modelInfo = await repository.loadModel(modelId);
    if (modelInfo == null) {
      throw Exception('Model not found: $modelId');
    }

    // Delete files first (if not external/protected) so a file-delete failure
    // leaves the metadata intact and the uninstall retryable — mirrors the
    // safe order used by uninstallEmbedder/Stt/Tts (delete then clear).
    if (modelInfo.source is! FileSource) {
      final targetPath = await fileSystem.getReadTargetPath(modelId);
      await fileSystem.deleteFile(targetPath);
    }

    // Delete metadata last.
    await repository.deleteModel(modelId);
  }

  /// Uninstall the active embedding model — deletes ALL its files (model +
  /// tokenizer) and clears the active-embedder identity. No-op if none active.
  static Future<void> uninstallEmbedder() async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final spec = manager.activeEmbeddingModel;
    if (spec == null) return;
    // The manager deletes every artifact in the spec. Clear only after the
    // whole delete succeeds, so a partial storage failure leaves the identity
    // available for a retry. The facade is the sole owner of this clear: one
    // awaited tombstone, regardless of which platform manager is installed.
    await manager.deleteModel(spec);
    await manager.clearActiveEmbeddingIdentity();
  }

  /// Uninstall the active STT model — deletes all its files and clears the
  /// active-STT identity. No-op if none active.
  static Future<void> uninstallStt() async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final spec = manager.activeSttModel;
    if (spec == null) return;
    await manager.deleteModel(spec);
    await manager.clearActiveSttIdentity();
  }

  /// Uninstall the active TTS model — deletes all its files and clears the
  /// active-TTS identity. No-op if none active.
  static Future<void> uninstallTts() async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final spec = manager.activeTtsModel;
    if (spec == null) return;
    await manager.deleteModel(spec);
    await manager.clearActiveTtsIdentity();
  }

  /// Delete orphaned files and stale metadata left by interrupted installs.
  static Future<void> performCleanup() =>
      FlutterEdgeAiPlugin.instance.modelManager.performCleanup();

  /// Current on-device storage usage across installed models.
  static Future<StorageStats> getStorageInfo() =>
      FlutterEdgeAiPlugin.instance.modelManager.getStorageInfo();

  /// Files on disk that have no matching installed-model metadata.
  static Future<List<OrphanedFileInfo>> getOrphanedFiles() =>
      FlutterEdgeAiPlugin.instance.modelManager.getOrphanedFiles();

  /// Delete orphaned files; returns the number of files removed.
  static Future<int> cleanupStorage() =>
      FlutterEdgeAiPlugin.instance.modelManager.cleanupStorage();

  /// Check if OPFS streaming mode is supported by the current browser
  ///
  /// Returns true on web if OPFS is available, false otherwise.
  /// Always returns false on mobile platforms.
  ///
  /// OPFS (Origin Private File System) is required for streaming mode,
  /// which allows loading large models (>2GB) without hitting ArrayBuffer limits.
  ///
  /// Browser support:
  /// - Chrome 86+ ✅
  /// - Edge 86+ ✅
  /// - Safari 15.2+ ✅
  /// - Firefox: Not yet supported ❌
  ///
  /// Example:
  /// ```dart
  /// if (await FlutterEdgeAi.isStreamingSupported()) {
  ///   await FlutterEdgeAi.initialize(
  ///     webStorageMode: WebStorageMode.streaming,
  ///   );
  /// } else {
  ///   print('OPFS not available, using cacheApi mode');
  ///   await FlutterEdgeAi.initialize(
  ///     webStorageMode: WebStorageMode.cacheApi,
  ///   );
  /// }
  /// ```
  static Future<bool> isStreamingSupported() async {
    // Streaming only supported on web platform
    if (!kIsWeb) {
      return false;
    }

    try {
      final registry = ServiceRegistry.instance;

      // Check if web storage mode is streaming
      if (registry.webStorageMode != WebStorageMode.streaming) {
        return false;
      }

      // Check if OPFS service is available
      final downloadService = registry.downloadService;
      if (downloadService is! WebDownloadService) {
        return false;
      }

      return downloadService.opfsService != null;
    } catch (e) {
      // ServiceRegistry not initialized or error checking
      return false;
    }
  }

  /// Reset ServiceRegistry (primarily for testing).
  static void reset() {
    _resetCoreState();
  }

  /// Resets Flutter Edge AI's core services.
  ///
  /// RAG indexes have an independent lifecycle in `flutter_edge_ai_rag` and
  /// must be disposed by their owner. This method never closes them. Installed
  /// models and loaded runtimes also survive: they live in the platform plugin
  /// instance and persistent model repository, not the DI singleton.
  static Future<void> dispose() async {
    _resetCoreState();
  }

  static void _resetCoreState() {
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
    EmbeddingRegistry.instance.reset();
    EmbeddingTokenizerRegistry.instance.reset();
    SttRegistry.instance.reset();
    TtsRegistry.instance.reset();
    SkillExecutorRegistry.instance.reset();
    HuggingFaceResolverRegistry.instance.reset();
  }
}
