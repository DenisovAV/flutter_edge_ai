import 'package:flutter/foundation.dart'
    show
        kIsWeb,
        defaultTargetPlatform,
        listEquals,
        TargetPlatform,
        visibleForTesting;
import 'package:flutter_edge_ai/src/api/inference_installation_builder.dart';
import 'package:flutter_edge_ai/src/api/embedding_installation_builder.dart';
import 'package:flutter_edge_ai/src/model_management/active_embedding_identity.dart'
    show noActiveEmbedderError;
import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart'
    show embedderCacheOf;
import 'package:flutter_edge_ai/src/lifecycle/speech_model_cache.dart'
    show sttRemovalOf, ttsRemovalOf;
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart'
    show inferenceModelCacheOf;
import 'package:flutter_edge_ai/src/model_management/install_rule.dart'
    show coreCopyLocation, recordedFileLocation;
import 'package:flutter_edge_ai/src/api/stt_installation_builder.dart';
import 'package:flutter_edge_ai/src/api/tts_installation_builder.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/domain/web_storage_mode.dart';
import 'package:flutter_edge_ai/src/infrastructure/web_download_service_stub.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/infrastructure/web_download_service.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/multi_model_engine.dart'
    show MultiModelEngine;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart'
    show ActiveModelParams;
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/stt_registry.dart';
import 'package:flutter_edge_ai/src/registry/tts_registry.dart';
import 'package:flutter_edge_ai/src/registry/skill_executor_registry.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_source.dart';
import 'package:flutter_edge_ai/src/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_tokenizer_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_tokenizer_registry.dart';
import 'package:flutter_edge_ai/src/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/skill_executor_provider.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/domain/multimodal_order.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/domain/no_active_model_error.dart';
import 'package:flutter_edge_ai/src/catalog/model_catalog.dart';
import 'package:flutter_edge_ai/src/catalog/registered_catalog.dart';

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
  /// Release builds print only the start-up notices about active models that
  /// could not be restored (no model output or prompts reach logcat/syslog);
  /// debug builds print according to this value. Default
  /// [EdgeAiLogLevel.info]. Use [EdgeAiLogLevel.verbose] to see model output
  /// and prompts while debugging. [EdgeAiLogLevel.none] silences everything
  /// this level controls, those notices included. Not under it: a few
  /// warnings about failures an app would not otherwise see (a model that
  /// fails to close, for example) are printed in every build.
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
    await ServiceRegistry.initialize(
      huggingFaceToken: huggingFaceToken,
      maxDownloadRetries: maxDownloadRetries,
      webStorageMode: webStorageMode,
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

  /// The models the packages passed to [initialize] offer, as one catalog.
  ///
  /// Each engine or backend that implements [ModelCatalogSource] adds its
  /// catalog, so only models a registered package can run are listed. A model
  /// two packages offer is one model; the variants of the package registered
  /// first come first. Choose a variant with [CatalogModel.variantFor] and
  /// install it with [installModelFromCatalog] (an LLM) or `fromCatalog` on
  /// [installEmbedder], [installStt] or [installTts].
  ///
  /// Throws [StateError] before [initialize] and after [dispose], when two
  /// packages offer the same variant id, and when a registered catalog breaks
  /// the id rules (a variant id that is not `<model id>/<slug>`, a model id
  /// with a `/`, a variant listed twice): one faulty catalog makes the whole
  /// getter throw, rather than leave a variant no id finds.
  static ModelCatalog get catalog {
    // Throws the not-initialized StateError.
    final registry = ServiceRegistry.instance;
    final providers = [
      ...EngineRegistry.instance.registered,
      ...EmbeddingRegistry.instance.registered,
      ...SttRegistry.instance.registered,
      ...TtsRegistry.instance.registered,
    ];
    // Built once for the registered providers (in their order): a getter an
    // app reads from build() does not merge the catalogs again.
    if (_catalog case (
      final r,
      final p,
      final c,
    ) when identical(r, registry) && listEquals(p, providers)) {
      return c;
    }
    final built = RegisteredCatalog(providers);
    _catalog = (registry, providers, built);
    return built;
  }

  static (ServiceRegistry, List<Object>, ModelCatalog)? _catalog;

  /// An installation builder for the LLM [variant]: its model type and file
  /// type, its pinned URL, the name the file is installed under and its
  /// size, which is checked before the model becomes active (not on the web,
  /// where the browser keeps the file). On the web a file over 2 GiB is
  /// refused before it downloads in every storage mode but
  /// `WebStorageMode.streaming`, the one that holds it.
  ///
  /// [token] is used for the download; without it, the token passed to
  /// [initialize] is used for huggingface.co. [foreground] is
  /// `InferenceInstallationBuilder.fromNetwork(foreground:)`.
  ///
  /// `install()` throws [UnsupportedError], before anything downloads, for a
  /// variant whose [CatalogVariant.backendsHere] is empty (its package does
  /// not run it in this runtime). That is a check of the runtime and its
  /// processor architecture only: whether this device has the NPU a build
  /// was compiled for, and whether the app bundled that vendor's stack, is
  /// known at load.
  ///
  /// The catalog pins each file to a revision: a model installed earlier
  /// from a `/resolve/main/` URL (or an older pin) is another source under
  /// the same name, and its first install from the catalog downloads the
  /// file again. When an active model of any kind reads a file of that name,
  /// `install()` throws [StateError] before the download instead of writing
  /// over it (not on the web), naming that model and the call that
  /// uninstalls it: uninstall it first, then install.
  ///
  /// ```dart
  /// final variant = FlutterEdgeAi.catalog
  ///     .byId('gemma-4-e2b-it')!
  ///     .variantFor(backend: PreferredBackend.gpu)! as InferenceVariant;
  /// await FlutterEdgeAi.installModelFromCatalog(variant)
  ///     .withProgress((p) => print('$p%'))
  ///     .install();
  /// final model = await FlutterEdgeAi.getActiveModel(
  ///   defaults: variant.runtimeDefaults,
  /// );
  /// ```
  static InferenceInstallationBuilder installModelFromCatalog(
    InferenceVariant variant, {
    String? token,
    bool? foreground,
  }) => inferenceBuilderFromCatalog(
    variant,
    token: token,
    foreground: foreground,
  );

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
  /// - [preferredVisionBackend]: vision-encoder backend override; null lets
  /// the engine choose (the native `.litertlm` engine reads the model file:
  /// the encoder's declared `backend_constraint`, the NPU when the encoder is
  /// compiled for one, else CPU; `InferenceModel.activeVisionBackend` says
  /// what it chose) (optional)
  /// - [preferredAudioBackend]: audio-encoder backend override; null as for
  /// [preferredVisionBackend] (optional)
  /// - [supportImage]: Enable multimodal image support (default: false)
  /// - [supportAudio]: Enable audio input, for a model with an audio encoder,
  ///   e.g. Gemma 4 or Gemma 3n `.litertlm` (E2B, E4B); native only (default: false)
  /// - [maxNumImages]: Maximum number of images if supportImage is true
  /// - [multimodalOrder]: the order in which a user message's images, audio
  ///   and text reach the model. Null picks the order of the active model's
  ///   type ([MultimodalOrder.forModelType]): images, text, audio for
  ///   [ModelType.gemma4], images, audio, text for every other type. Set it
  ///   for a model whose template expects another order. Changing it rebuilds
  ///   the model, as every argument here does. Read by the native LiteRT-LM
  ///   engine only (optional)
  /// - [activationDataType]: activation type for the text decoder of native
  ///   `.litertlm` models (Android, iOS, desktop); null honors the model file
  ///   (except a `ModelType.functionGemma` bundle that declares no
  ///   `prefer_activation_type`, which gets float32 on its GPU attempt),
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
  /// - `TimeoutException` if the previous model is still closing after 60 s;
  ///   its close keeps running, and a later call succeeds once it ends. A
  ///   model closing when this is called (`isClosed` is true) is waited for,
  ///   never returned.
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
  /// // Create with audio support (e.g. Gemma 4 or Gemma 3n .litertlm, native)
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
    MultimodalOrder? multimodalOrder,
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeInferenceModel;

    if (activeSpec == null) {
      throw NoActiveModelError(
        'No active inference model set. Use FlutterEdgeAi.installModel() first.',
      );
    }

    if (activeSpec is! InferenceModelSpec) {
      throw StateError(
        'Active model is not an InferenceModelSpec. '
        'Expected InferenceModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    final merged = _mergeModelDefaults(
      'getActiveModel',
      defaults: defaults,
      maxTokens: maxTokens,
      preferredBackend: preferredBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
    );

    // Create InferenceModel using identity from spec + runtime params
    return await FlutterEdgeAiPlugin.instance.obtainActiveModel(
      modelType: activeSpec.modelType,
      fileType: activeSpec.fileType,
      maxTokens: merged.maxTokens,
      preferredBackend: merged.preferredBackend,
      preferredVisionBackend: preferredVisionBackend,
      preferredAudioBackend: preferredAudioBackend,
      supportImage: merged.supportImage,
      supportAudio: merged.supportAudio,
      maxNumImages: maxNumImages,
      multimodalOrder: multimodalOrder,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      activationDataType: activationDataType,
      maxConcurrentSessions: maxConcurrentSessions,
    );
  }

  /// Opens a new model for [spec] that the caller owns, next to the active
  /// model and to other opened ones. Mobile and desktop only.
  ///
  /// [getActiveModel] gives the one active model: cached, and rebuilt when a
  /// parameter changes. [openModel] builds a new model on every call. It is
  /// never cached, a [getActiveModel] rebuild never touches it, and closing it
  /// leaves every other model open. Close it with [InferenceModel.close] when
  /// done: the plugin has no memory policy, and each open model holds its own
  /// weights and context window. On iOS a process past its memory limit is
  /// killed, with no exception to catch.
  ///
  /// [spec] must be the installed model, as `install()` returned it. Register
  /// a file without making it the active model with
  /// `installModel(…).fromFile(path).install(activate: false)`. Uninstalling
  /// a model does not close the models opened on it.
  ///
  /// The engine that runs [spec] must implement [MultiModelEngine]
  /// (`LiteRtLmEngine` does); otherwise this throws [UnsupportedError] before
  /// anything is loaded. Open models share the engine cache directory
  /// [getActiveModel] uses, the native libraries the process loaded and the
  /// engine's process-wide settings (LiteRT-LM's log level). A model's sampler
  /// is fixed by its first generation (LiteRT-LM#2080), so sessions sharing
  /// one model should use the same sampling.
  ///
  /// The parameters mean what they mean on [getActiveModel], with the same
  /// precedence over [defaults].
  ///
  /// Throws [UnsupportedError] on web and for an engine without
  /// [MultiModelEngine], [StateError] when no registered engine can run
  /// [spec], and an `Exception` when [spec] is not the installed model.
  static Future<InferenceModel> openModel(
    InferenceModelSpec spec, {
    ModelRuntimeDefaults? defaults,
    int? maxTokens,
    PreferredBackend? preferredBackend,
    PreferredBackend? preferredVisionBackend,
    PreferredBackend? preferredAudioBackend,
    bool? supportImage,
    bool? supportAudio,
    int? maxNumImages,
    MultimodalOrder? multimodalOrder,
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    final merged = _mergeModelDefaults(
      'openModel',
      defaults: defaults,
      maxTokens: maxTokens,
      preferredBackend: preferredBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
    );
    return FlutterEdgeAiPlugin.instance.openModel(
      spec,
      ActiveModelParams(
        maxTokens: merged.maxTokens,
        preferredBackend: merged.preferredBackend,
        preferredVisionBackend: preferredVisionBackend,
        preferredAudioBackend: preferredAudioBackend,
        supportImage: merged.supportImage,
        supportAudio: merged.supportAudio,
        maxNumImages: maxNumImages,
        multimodalOrder:
            multimodalOrder ?? MultimodalOrder.forModelType(spec.modelType),
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        activationDataType: activationDataType,
        maxConcurrentSessions: maxConcurrentSessions,
      ),
    );
  }

  /// The model-level values [getActiveModel] and [openModel] build with.
  static ({
    int maxTokens,
    PreferredBackend? preferredBackend,
    bool supportImage,
    bool supportAudio,
  })
  _mergeModelDefaults(
    String caller, {
    required ModelRuntimeDefaults? defaults,
    required int? maxTokens,
    required PreferredBackend? preferredBackend,
    required bool? supportImage,
    required bool? supportAudio,
  }) {
    // Merge precedence: explicit argument > manifest [defaults] > SDK default.
    // maxTokens keeps its historical 1024 fallback, so an omitted arg with no
    // defaults behaves exactly as before. The .litertlm engine still clamps
    // this value downstream (clampLitertlmContextTokens) — a manifest cannot
    // set a context window the engine rejects (guards #318).
    final merged = (
      maxTokens: mergeRuntimeDefault(maxTokens, defaults?.maxTokens, 1024),
      preferredBackend: preferredBackend ?? defaults?.preferredBackend,
      supportImage: mergeRuntimeDefault(
        supportImage,
        defaults?.supportImage,
        false,
      ),
      supportAudio: mergeRuntimeDefault(
        supportAudio,
        defaults?.supportAudio,
        false,
      ),
    );

    // [defaults] also carries two SESSION-level fields (thinkingDeclared,
    // minOutputTokens) that this model-level call cannot apply. Warn (debug
    // builds) so a caller who passes `defaults:` here and forgets to forward
    // them to createSession finds out, instead of a reasoning model silently
    // truncating mid-<think>.
    if (defaults != null &&
        (defaults.thinkingDeclared != null ||
            defaults.minOutputTokens != null)) {
      edgeAiLog(
        '[flutter_edge_ai] $caller: manifest defaults carry session-level '
        'fields (thinkingDeclared/minOutputTokens) that $caller does not apply '
        '— forward them to createSession(enableThinking:, maxOutputTokens:).',
      );
    }
    return merged;
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

  /// Three-tier runtime-default merge used by [getActiveModel] and [openModel]: an explicit
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
  /// The model (and, unless it is a self-contained `.litertlm` bundle, its
  /// tokenizer) comes from the active EmbeddingModelSpec. Every engine loads
  /// eagerly, so [EmbeddingModel.dimension], [EmbeddingModel.modalities] and
  /// [EmbeddingModel.maxInputTokens] are known when this returns.
  ///
  /// Runtime parameters:
  /// - [supportImage] / [supportAudio]: declare the media you will embed.
  ///   Text is implied whenever the model has a text tower. Media sent to a
  ///   model that did not declare them fail with
  ///   `EmbeddingModalityNotLoadedException`. The embedder already loaded is
  ///   reused when it covers the request; otherwise it is rebuilt with the
  ///   UNION of what it had and what is asked, so declarations only widen.
  /// - [preferredBackend]: explicit accelerator preference. Providers declare
  ///   what they honour for the installed spec. Automatic (null) reuses a
  ///   current non-NPU embedder for that model and media. A repeated explicit
  ///   CPU/GPU request reuses the model it loaded, including a fallback; it
  ///   does not retry the accelerator until a rebuild is needed or the model
  ///   is closed. An explicit switch otherwise replaces it. NPU requests keep
  ///   a separate cache identity and automatic requests never borrow an NPU
  ///   entry, since NPU vectors need not match CPU/GPU vectors. Existing
  ///   CPU-only providers ignore GPU with a once-only diagnostic; legacy web
  ///   runtimes choose their own placement. GPU-capable providers report the
  ///   loaded backend and print one release-visible warning when a new
  ///   explicit load falls back, including an NPU request; reuse is quiet.
  ///   Read [EmbeddingModel.activeBackend] for the actual placement; null is
  ///   unknown, not CPU. Provider constructors own any strict fallback policy.
  ///
  /// Fails (as a failed future) with:
  /// - [StateError] if no active embedding model is set
  /// - `EmbeddingLoadException` if the model fails to load, or the engine
  ///   cannot serve a declared medium
  /// - `EmbedderCloseTimeoutException` if the previous embedder is still
  ///   closing after 60 s; its close keeps running, and a later call succeeds
  ///   once it ends.
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
  /// final vector = await embedder.embed(
  ///   EmbeddingInput.text('How do I reset the device?'),
  ///   taskType: TaskType.retrievalQuery,
  /// );
  ///
  /// // Where the backend matters, ask — do not assume the argument took.
  /// // Native answers PreferredBackend.cpu (npu for an NPU bundle; gpu for
  /// // EmbeddingGemma 2 asked for with gpu on Linux x64 — Linux x64 only;
  /// // Windows x64 is refused on native-v0.18.0-h (LiteRT-LM accelerator
  /// // crash), tracked in #744); on web EmbeddingGemma 2 answers gpu and
  /// // other embedders null.
  /// debugPrint('embedding on ${embedder.activeBackend}');
  /// ```
  static Future<EmbeddingModel> getActiveEmbedder({
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
  }) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final activeSpec = manager.activeEmbeddingModel;

    if (activeSpec == null) throw noActiveEmbedderError();

    if (activeSpec is! EmbeddingModelSpec) {
      throw StateError(
        'Active model is not an EmbeddingModelSpec. '
        'Expected EmbeddingModelSpec, got ${activeSpec.runtimeType}',
      );
    }

    // Create EmbeddingModel using active spec (paths resolved automatically)
    return await FlutterEdgeAiPlugin.instance.createEmbeddingModel(
      preferredBackend: preferredBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
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

  /// Absolute on-device path an installed model file is read from, keyed by
  /// the [fileName] it is installed under (e.g. `gemma-4-E2B-it.litertlm`),
  /// as the file's install record says — where the engines open it:
  ///
  /// - installed with `fromFile`: the app's own file, where it is now (on iOS
  ///   in the app's current container, which an update or a restore from a
  ///   backup can move);
  /// - installed with `fromBundled`: in the app bundle on iOS, core's copy of
  ///   it on Android;
  /// - any other source: core's copy, in core's model directory.
  ///
  /// A name with no install record gives what an older release registered
  /// for it, else its place in core's model directory. The path is computed,
  /// not stat-ed — it is returned even if nothing is there — except that a
  /// bundled resource the iOS app bundle does not hold throws, as loading it
  /// does.
  ///
  /// On web this returns [fileName] itself, not a path or a URL: a model there
  /// lives in the browser's storage, and the engines look it up by that name.
  static Future<String> getModelPath(String fileName) async {
    final registry = ServiceRegistry.instance;
    if (!kIsWeb) {
      // The file's own record, not the registry of the app's files: that one
      // keeps the path an install was given, so on iOS it can name a
      // container that has since moved, and older releases left names in it
      // that a download has taken over since.
      final record = await registry.modelRepository.loadModel(fileName);
      if (record != null) return recordedFileLocation(record);
    }
    // No record — an install from before every file had one, or none.
    final external = await registry.protectedFilesRegistry.getExternalPath(
      fileName,
    );
    if (external != null) return external;
    return registry.fileSystemService.getReadTargetPath(fileName);
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
  /// Removes the model's metadata and core's copy of its file. A file the app
  /// installed with `fromFile` is the app's own and stays where it is.
  ///
  /// When the file is one of the active inference model's (the model or its
  /// LoRA), the active inference identity is cleared too, in memory and
  /// persisted, as [clearActiveInferenceIdentity] does: [getActiveModel] then
  /// throws [NoActiveModelError] instead of loading a file that is gone.
  ///
  /// The model [getActiveModel] built from the file is closed first, with its
  /// sessions and chats: a generation running on it stops early, with or
  /// without an error depending on the engine, and a later call on it throws.
  /// A [getActiveModel] call whose build of that model is still running gets
  /// it, closed right after; one made once the uninstall has started closing
  /// waits for the uninstall to end. A model built from other files stays
  /// open, and so do the models [openModel] opened: they are the caller's to
  /// close. When that close is still running after 60 seconds, the uninstall
  /// throws `TimeoutException` before anything is deleted, and can be retried.
  ///
  /// A directory model (ORT-GenAI, installed with `fromHuggingFace`) is
  /// uninstalled by its name, the `spec.name` its install returned: every
  /// file of it and its directory go.
  ///
  /// Parameters:
  /// - [modelId]: Model filename to uninstall, or a directory model's name
  static Future<void> uninstallModel(String modelId) async {
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final fileSystem = registry.fileSystemService;
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    // The active model is restored at start; it is known once that is done.
    await manager.ensureInitialized();

    // Get model info
    final modelInfo = await repository.loadModel(modelId);
    if (modelInfo == null) {
      // A directory (ORT-GenAI) model has no record of its own: each of its
      // files is recorded as `<modelId>/<file>`.
      final directory = await _installedDirectoryModel(modelId);
      if (directory == null) throw Exception('Model not found: $modelId');
      return _uninstallDirectoryModel(directory);
    }

    Future<void> remove() async {
      // Delete files first (if not external/protected) so a file-delete
      // failure leaves the metadata intact and the uninstall retryable —
      // mirrors the safe order used by uninstallEmbedder/Stt/Tts (delete then
      // clear).
      final copy = switch (modelInfo.source) {
        FileSource() => null,
        // Core's copy, not a file named after the record: the iOS bundle's
        // resource is read in place, and Android copies one under its
        // resource name, which a namespaced LoRA or tokenizer record id is
        // not.
        BundledSource() => await coreCopyLocation(modelInfo),
        _ => await fileSystem.getReadTargetPath(modelId),
      };
      if (copy != null) await fileSystem.deleteFile(copy);

      // Forget what a fromFile install registered — or what an older release
      // left registered after an uninstall — while the record still exists,
      // so a failure here leaves the uninstall retryable.
      await registry.protectedFilesRegistry.unprotect(modelId);
      await registry.protectedFilesRegistry.unregisterExternalPath(modelId);

      // The active model cannot load without this file. Cleared once the
      // file is gone, and while the record still exists: a failure up to
      // here leaves both the identity and a retryable uninstall.
      final active = manager.activeInferenceModel;
      if (active != null && active.files.any((f) => f.filename == modelId)) {
        await manager.clearActiveInferenceIdentity();
      }

      // Delete metadata last.
      await repository.deleteModel(modelId);
    }

    // Closed before the file goes: left open, the model keeps answering from
    // a file that is gone (measured on macOS and Windows).
    final cache = inferenceModelCacheOf(FlutterEdgeAiPlugin.instance);
    if (cache == null) return remove();
    return cache.closeForRemoval(modelId, remove);
  }

  /// The directory model [modelId] as its install records describe it, or
  /// null when no file is recorded under `<modelId>/`.
  static Future<InferenceModelSpec?> _installedDirectoryModel(
    String modelId,
  ) async {
    final members = [
      for (final record
          in await ServiceRegistry.instance.modelRepository.listInstalled())
        if (record.id.startsWith('$modelId/')) record,
    ];
    if (members.isEmpty) return null;
    // Only the file names matter for the removal; which member is the
    // primary does not.
    final primary = members.first.id.substring(modelId.length + 1);
    final files = [
      for (final m in members)
        DirectoryBundleFile.member(
          modelId: modelId,
          bareName: m.id.substring(modelId.length + 1),
          primaryName: primary,
          source: m.source,
        ),
    ];
    // The records keep no model type, and nothing loads this spec.
    return InferenceModelSpec(
      name: modelId,
      modelSource: files.first.source,
      modelType: ModelType.general,
      fileType: ModelFileType.onnx,
      directoryFiles: files,
    );
  }

  /// Uninstalls every file of the directory model [spec], as [uninstallModel]
  /// does one file: the model built from it is closed first, the active
  /// identity is cleared when it is this model, and the manager deletes each
  /// file before its record, then the emptied directory.
  static Future<void> _uninstallDirectoryModel(InferenceModelSpec spec) async {
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final names = {for (final f in spec.files) f.filename};

    Future<void> remove() async {
      // Cleared before the records go: a delete that fails part-way leaves
      // the remaining members recorded, so the uninstall can be retried by
      // the same name, while a model with some of its files gone is no
      // longer the active one.
      final active = manager.activeInferenceModel;
      if (active != null &&
          active.files.any((f) => names.contains(f.filename))) {
        await manager.clearActiveInferenceIdentity();
      }
      await manager.deleteModel(spec);
    }

    final cache = inferenceModelCacheOf(FlutterEdgeAiPlugin.instance);
    if (cache == null) return remove();
    // Any member names the model built from the directory.
    return cache.closeForRemoval(spec.files.first.filename, remove);
  }

  /// Uninstall the active embedding model — uninstalls ALL its files (model +
  /// tokenizer) and clears the active-embedder identity. No-op if none active.
  /// Core's copies are deleted; a file installed with `fromFile` is the app's
  /// own and stays where it is.
  ///
  /// The embedder [getActiveEmbedder] built from those files is closed
  /// first, including the handle the app holds: a later call on it throws
  /// [EmbedderClosedException], and the next [getActiveEmbedder] throws
  /// [NoActiveModelError] until an embedder is installed again, which then
  /// gets a new embedder. A request already running finishes; the queued
  /// ones fail with [EmbedderClosedException]. A [getActiveEmbedder] call
  /// made meanwhile waits for the uninstall to end. When that close is still
  /// running after 60 seconds, the uninstall throws
  /// [EmbedderCloseTimeoutException] before anything is deleted, and can be
  /// retried.
  static Future<void> uninstallEmbedder() async {
    final plugin = FlutterEdgeAiPlugin.instance;
    final manager = plugin.modelManager;
    final spec = manager.activeEmbeddingModel;
    if (spec == null) return;
    Future<void> remove() async {
      // The manager deletes every artifact in the spec. Clear only after the
      // whole delete succeeds, so a partial storage failure leaves the
      // identity available for a retry. The facade is the sole owner of this
      // clear: one awaited tombstone, regardless of which platform manager is
      // installed.
      await manager.deleteModel(spec);
      await manager.clearActiveEmbeddingIdentity();
    }

    // Closed before the files go: left open, the embedder keeps answering
    // from files that are gone and stays resident (measured on macOS).
    final cache = embedderCacheOf(plugin);
    if (cache == null) return remove();
    final paths = {...?(await manager.getModelFilePaths(spec))?.values};
    return cache.closeForRemoval(
      (params) =>
          paths.contains(params.modelPath) ||
          paths.contains(params.tokenizerPath),
      remove,
      label: spec.name,
    );
  }

  /// Uninstall the active STT model — uninstalls ALL its files and clears
  /// the active-STT identity. No-op if none active. Core's copies are
  /// deleted; a file installed with `fromFile` is the app's own and stays
  /// where it is.
  ///
  /// The recognizer [getActiveStt] built from those files is closed first,
  /// including the handle the app holds: a later call on it throws, and the
  /// next [getActiveStt] throws until a model is installed again, which then
  /// gets a new recognizer. A transcription already running finishes first.
  /// A [getActiveStt] call made meanwhile waits for the uninstall to end.
  /// When that close is still running after 60 seconds, the uninstall throws
  /// `TimeoutException` before anything is deleted, and can be retried.
  static Future<void> uninstallStt() async {
    final plugin = FlutterEdgeAiPlugin.instance;
    final manager = plugin.modelManager;
    final spec = manager.activeSttModel;
    if (spec == null) return;
    Future<void> remove() async {
      await manager.deleteModel(spec);
      await manager.clearActiveSttIdentity();
    }

    final removal = sttRemovalOf(plugin);
    if (removal == null) return remove();
    return removal({for (final file in spec.files) file.filename}, remove);
  }

  /// Uninstall the active TTS model — uninstalls ALL its files and clears
  /// the active-TTS identity. No-op if none active. Core's copies are
  /// deleted; a file installed with `fromFile` is the app's own and stays
  /// where it is.
  ///
  /// The synthesizer [getActiveTts] built from those files is closed first,
  /// including the handle the app holds: a later call on it throws, and the
  /// next [getActiveTts] throws until a model is installed again, which then
  /// gets a new synthesizer. A synthesis already running finishes first. A
  /// [getActiveTts] call made meanwhile waits for the uninstall to end. When
  /// that close is still running after 60 seconds, the uninstall throws
  /// `TimeoutException` before anything is deleted, and can be retried.
  static Future<void> uninstallTts() async {
    final plugin = FlutterEdgeAiPlugin.instance;
    final manager = plugin.modelManager;
    final spec = manager.activeTtsModel;
    if (spec == null) return;
    Future<void> remove() async {
      await manager.deleteModel(spec);
      await manager.clearActiveTtsIdentity();
    }

    final removal = ttsRemovalOf(plugin);
    if (removal == null) return remove();
    return removal({for (final file in spec.files) file.filename}, remove);
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
    _catalog = null;
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
