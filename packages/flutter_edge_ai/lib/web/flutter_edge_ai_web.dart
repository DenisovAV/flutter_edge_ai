import 'dart:async';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/stt_registry.dart';
import 'package:flutter_edge_ai/core/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_cache.dart';

class FlutterEdgeAiWeb extends FlutterEdgeAiPlugin {
  FlutterEdgeAiWeb();

  static void registerWith(Registrar registrar) {
    FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
  }

  // WebModelManager singleton
  static WebModelManager? _webManager;

  @override
  ModelFileManager get modelManager {
    // Use WebModelManager
    _webManager ??= WebModelManager();
    return _webManager!;
  }

  @override
  InferenceModel? get initializedModel => _initializedModel;

  @override
  EmbeddingModel? get initializedEmbeddingModel => _embedderCache.model;

  InferenceModel? _initializedModel;
  SpeechRecognizer? _initializedSttModel;

  /// The cached embedder and the rule for reusing it, shared with the mobile
  /// and desktop shells.
  ///
  /// The hand-rolled version it replaces was the STRICTEST of the three — this
  /// shell already compared resolved paths, where mobile and desktop compared a
  /// spec name — but it had no in-flight guard at all, so two concurrent first
  /// callers each built their own model and the loser was left outside core's
  /// bookkeeping, where nothing would ever close it. Its close listener was not
  /// identity-guarded
  /// either. Both are now the cache's problem, once, for all three shells.
  final EmbedderCache _embedderCache = EmbedderCache();

  /// The embedder's params live in [_embedderCache]; STT still keeps its own.
  ({String? modelPath, String? tokenizerPath})? _lastSttPaths;

  @override
  Future<InferenceModel> createModel({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    int maxTokens = 1024,
    PreferredBackend? preferredBackend,
    PreferredBackend? preferredVisionBackend,
    PreferredBackend? preferredAudioBackend,
    List<int>? loraRanks,
    int? maxNumImages,
    bool supportImage = false, // Enabling image support
    bool supportAudio = false, // Enabling audio support (Gemma 3n E4B)
    bool? enableSpeculativeDecoding, // Ignored on web (MediaPipe path).
    ActivationDataType? activationDataType, // Not read by the web engines.
    int? maxConcurrentSessions,
  }) async {
    // TODO: Implement multimodal support for web
    if (supportImage || maxNumImages != null) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: Image support is not yet implemented for web platform',
        );
      }
    }

    // A cached singleton may exist from a prior createModel call. It is always
    // closed and replaced — web does NOT do the params-compare reuse that
    // mobile and desktop do (ActiveModelParams / _lastInferenceParams).
    //
    // Not because core cannot see the params: ActiveModelParams records what
    // the CALLER asked for, so no introspection of the model is needed. The
    // reason is the spec below. Web synthesises it with the constant name
    // 'web-active' because, unlike the other shells, createModel here does not
    // require an active model to be set first. So a reuse check keyed on that
    // spec cannot see the user swapping the active model file underneath it,
    // and would hand back a model built from the previous one — silently, and
    // with the params matching, so nothing would look wrong.
    //
    // Always rebuilding is the safe direction of that trade: it costs a reload
    // that was sometimes unnecessary, rather than answering from the wrong
    // weights. Reuse can be added here once the spec carries the active
    // model's identity.
    if (_initializedModel != null) {
      if (kDebugMode) {
        edgeAiLog(
          '[FlutterEdgeAiWeb] Replacing existing model, closing it first',
        );
      }
      await _initializedModel!.close();
      _initializedModel = null;
    }

    // Engine selection routes through [EngineRegistry] (probe-chain), mirroring
    // the mobile/desktop refactor: .task → MediaPipe, .litertlm → LiteRT-LM.
    // Both web engines now live in their own packages (flutter_edge_ai_mediapipe /
    // flutter_edge_ai_litertlm), supplied via
    // FlutterEdgeAi.initialize(inferenceEngines: ...). Web registers NO default;
    // each engine builds its own WebModelSourceResolver internally. Web has no
    // resolved file path/cache dir (paths are lazy via the resolver), so the
    // RuntimeConfig's modelPath is empty.

    // Web selection has always been by `fileType` alone; build a minimal spec
    // carrying it for the probe (web does not require an active model to be set
    // before createModel, so we don't depend on webManager.activeInferenceModel).
    final spec = InferenceModelSpec(
      name: 'web-active',
      modelSource: AssetSource('models/active.bin'),
      modelType: modelType,
      fileType: fileType,
    );
    final config = RuntimeConfig(
      maxTokens: maxTokens,
      modelPath: '',
      preferredBackend: preferredBackend,
      preferredVisionBackend: preferredVisionBackend,
      preferredAudioBackend: preferredAudioBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
      maxNumImages: maxNumImages,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      activationDataType: activationDataType,
      maxConcurrentSessions: maxConcurrentSessions,
      loraRanks: loraRanks,
    );
    final engine = EngineRegistry.instance.findFor(spec);
    if (engine == null) {
      throw StateError(
        'No inference engine can handle this model (ModelFileType.${spec.fileType.name}). '
        'Add the engine package to pubspec.yaml and pass it in inferenceEngines: '
        'of FlutterEdgeAi.initialize(...). Registered engines: '
        '${EngineRegistry.instance.registered.map((e) => e.name).join(", ")}.',
      );
    }
    if (activationDataType != null) {
      edgeAiLog(
        '[FlutterEdgeAiWeb] activationDataType (${activationDataType.name}) is '
        'not supported on web — no web engine has the setting; ignoring.',
      );
    }
    final model = await engine.createModel(spec, config);

    // Core owns the singleton lifecycle: track it + reset on close. The
    // package-built model fires this via CloseNotifier (addCloseListener).
    _initializedModel = model;
    model.addCloseListener(() {
      _initializedModel = null;
    });
    return model;
  }

  // === EmbeddingModel Methods - Web Implementation ===

  @override
  Future<EmbeddingModel> createEmbeddingModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
  }) {
    // FIRST statement, before every guard. It is idempotent and one-shot, so
    // it needs neither resolved paths nor cache state — and putting it in a
    // branch is what made it unreachable twice: once behind the singleton
    // cache, once behind "only on reuse". The ordinary shape is a single call
    // held for the app's lifetime; if it does not speak here it never speaks.
    noticeWebEmbedderBackendIgnored(preferredBackend);

    // Serialised, so that resolving paths, comparing them and constructing the
    // model are one step — which is what stops two concurrent first callers from
    // each building one, the defect this shell actually had.
    //
    // Note what this does NOT cover on either web arm: the model constructors
    // are trivial and the WASM/WebGPU compile happens lazily on the first
    // `generateEmbedding`, outside this lane. Concurrent first embeddings are
    // deduped by each model's own single in-flight init future — this lane only
    // guarantees one MODEL, not one compile.
    return _embedderCache.serialize(
      () => _reuseOrBuildEmbedder(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: preferredBackend,
      ),
    );
  }

  /// Runs inside [EmbedderCache.serialize], so it may assume nothing else is
  /// touching the cache while it awaits.
  Future<EmbeddingModel> _reuseOrBuildEmbedder({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
  }) async {
    // Modern API: Use active embedding model if paths not provided
    if (modelPath == null || tokenizerPath == null) {
      final manager = modelManager as WebModelManager;
      final activeModel = manager.activeEmbeddingModel;

      // No active embedding model - user must set one first
      if (activeModel == null) {
        throw StateError(
          'No active embedding model set. Use `FlutterEdgeAi.installEmbedder()` or `modelManager.setActiveModel()` to set a model first',
        );
      }

      // Get the actual model file paths through unified system
      final modelFilePaths = await manager.getModelFilePaths(activeModel);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw StateError(
          'Embedding model file paths not found. Use the `modelManager` to load the model first',
        );
      }

      // Extract model and tokenizer paths from spec
      final activeModelPath =
          modelFilePaths[PreferencesKeys.embeddingModelFile];
      final activeTokenizerPath =
          modelFilePaths[PreferencesKeys.embeddingTokenizerFile];

      if (activeModelPath == null || activeTokenizerPath == null) {
        throw StateError(
          'Could not find model or tokenizer path in active embedding model',
        );
      }

      modelPath = activeModelPath;
      tokenizerPath = activeTokenizerPath;

      if (kDebugMode) {
        edgeAiLog(
          'Using active embedding model: $modelPath, tokenizer: $tokenizerPath',
        );
      }
    }

    final requestedParams = ActiveEmbedderParams(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      preferredBackend: preferredBackend,
    );
    final reused = await _embedderCache.reuseOrInvalidate(
      requestedParams,
      // Reusing: on web the runtime picks the accelerator itself — LiteRT.js
      // per compile, onnxruntime-web by trying ['webgpu', 'wasm'] in order —
      // and the notice already fired at the top of this method.
      label: 'web embedder',
    );
    if (reused != null) return reused;

    try {
      // The LiteRT.js embedding runtime lives in flutter_edge_ai_litertlm; core
      // resolves paths (preamble above) + owns the singleton lifecycle, then
      // dispatches construction through the EmbeddingRegistry. The backend reads
      // ONLY config.modelPath/config.tokenizerPath — it ignores the spec for path
      // resolution. Web selects by the sole registered backend (WebGPU LiteRT.js).
      //
      // Inside the try, where every other shell has it. There is no completer to
      // leak here any more, but the shape matters: a throw between claiming a
      // build slot and entering the `try` that releases it is how a single
      // misconfiguration becomes a permanent hang.
      final activeEmb = (modelManager as WebModelManager).activeEmbeddingModel;
      final EmbeddingBackendProvider? backend = activeEmb is EmbeddingModelSpec
          ? EmbeddingRegistry.instance.findFor(activeEmb)
          : (EmbeddingRegistry.instance.registered.isNotEmpty
                ? EmbeddingRegistry.instance.registered.first
                : null);
      if (backend == null) {
        throw StateError(
          'No embedding backend registered. Add flutter_edge_ai_litertlm to '
          'pubspec.yaml and pass LiteRtEmbeddingBackend() in embeddingBackends: '
          'of FlutterEdgeAi.initialize(...). Registered backends: '
          '${EmbeddingRegistry.instance.registered.map((b) => b.name).join(", ")}.',
        );
      }
      // modelPath/tokenizerPath are non-null here (resolved in the preamble or
      // passed by the caller). preferredBackend is ignored on web (LiteRT.js uses
      // WebGPU when available); maxTokens is unused by embeddings.
      final embConfig = RuntimeConfig(
        maxTokens: 0,
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: preferredBackend,
      );
      // The backend's createModel(spec, config) requires a non-null spec but
      // resolves paths exclusively from config; synthesize one from the resolved
      // file paths when there's no active EmbeddingModelSpec.
      final model = await backend.createModel(
        activeEmb is EmbeddingModelSpec
            ? activeEmb
            : EmbeddingModelSpec(
                name: 'web-active-embedding',
                modelSource: ModelSource.file(modelPath),
                tokenizerSource: ModelSource.file(tokenizerPath),
              ),
        embConfig,
      );
      await _embedderCache.adopt(model, requestedParams);
      return model;
    } catch (_) {
      _embedderCache.invalidate();
      rethrow;
    }
  }

  // === SpeechRecognizer Methods - Web Implementation ===

  @override
  Future<SpeechRecognizer> createSttModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    // Modern API: Use active STT model if paths not provided
    if (modelPath == null || tokenizerPath == null) {
      final manager = modelManager as WebModelManager;
      final activeModel = manager.activeSttModel;

      // No active STT model - user must set one first
      if (activeModel == null) {
        throw StateError(
          'No active STT model set. Use `FlutterEdgeAi.installStt()` or `modelManager.setActiveModel()` to set a model first',
        );
      }

      // Get the actual model file paths through unified system
      final modelFilePaths = await manager.getModelFilePaths(activeModel);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw StateError(
          'STT model file paths not found. Use the `modelManager` to load the model first',
        );
      }

      // Extract model and tokenizer paths from spec
      final activeModelPath = modelFilePaths[PreferencesKeys.sttModelFile];
      final activeTokenizerPath =
          modelFilePaths[PreferencesKeys.sttTokenizerFile];

      if (activeModelPath == null || activeTokenizerPath == null) {
        throw StateError(
          'Could not find model or tokenizer path in active STT model',
        );
      }

      modelPath = activeModelPath;
      tokenizerPath = activeTokenizerPath;

      if (kDebugMode) {
        edgeAiLog(
          'Using active STT model: $modelPath, tokenizer: $tokenizerPath',
        );
      }
    }

    // Check if model already exists with different parameters. Core can no
    // longer downcast to the package's concrete STT model type, so it
    // compares against the last resolved paths it cached itself (mirrors
    // the embedder cache).
    if (_initializedSttModel != null) {
      final p = _lastSttPaths;
      final modelChanged =
          p == null ||
          p.modelPath != modelPath ||
          p.tokenizerPath != tokenizerPath;

      if (modelChanged) {
        if (kDebugMode) {
          edgeAiLog(
            '[FlutterEdgeAiWeb] STT model paths changed, closing existing model',
          );
        }
        await _initializedSttModel?.close();
        _initializedSttModel = null;
        _lastSttPaths = null;
      }
    }

    if (_initializedSttModel != null) {
      // Same model — reuse the singleton, RETARGETED to the requested
      // language. Without this the caller gets back the recognizer built for
      // the FIRST language and transcribes into it with no error; see the
      // matching branch in the mobile shell. The decoder prompt is rebuilt
      // per transcription, so this is a field write, not a reload.
      _initializedSttModel!.language = language;
      return _initializedSttModel!;
    }

    // Dispatches construction through the SttRegistry (probe-chain, mirrors
    // EmbeddingRegistry). The backend reads spec.sttModelType to select its
    // runtime profile, and ONLY config.modelPath/config.tokenizerPath for
    // path resolution.
    final activeStt = (modelManager as WebModelManager).activeSttModel;
    final SttBackendProvider? backend = activeStt is SttModelSpec
        ? SttRegistry.instance.findFor(activeStt)
        : (SttRegistry.instance.registered.isNotEmpty
              ? SttRegistry.instance.registered.first
              : null);
    if (backend == null) {
      throw StateError(
        'No STT backend registered. Add flutter_edge_ai_speech to '
        'pubspec.yaml and pass it in sttBackends: of '
        'FlutterEdgeAi.initialize(...). Registered backends: '
        '${SttRegistry.instance.registered.map((b) => b.name).join(", ")}.',
      );
    }
    // modelPath/tokenizerPath are non-null here (resolved in the preamble or
    // passed by the caller). maxTokens is unused by STT.
    final sttConfig = RuntimeConfig(
      maxTokens: 0,
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      preferredBackend: preferredBackend,
      // Whisper's output language. Dropping it here is invisible: the
      // recognizer still works and still returns text, just always in
      // English, because the profile falls back to its `<|en|>` default.
      language: language,
    );
    // The backend's createModel(spec, config) requires a non-null spec but
    // resolves paths exclusively from config; synthesize one from the resolved
    // file paths when there's no active SttModelSpec. sttModelType defaults to
    // moonshine — the only shipped profile — for this legacy-path fallback.
    final model = await backend.createModel(
      activeStt is SttModelSpec
          ? activeStt
          : SttModelSpec(
              name: 'web-active-stt',
              modelSource: ModelSource.file(modelPath),
              tokenizerSource: ModelSource.file(tokenizerPath),
              sttModelType: SttModelType.moonshine,
            ),
      sttConfig,
    );
    _initializedSttModel = model;
    _lastSttPaths = (modelPath: modelPath, tokenizerPath: tokenizerPath);
    model.addCloseListener(() {
      _initializedSttModel = null;
      _lastSttPaths = null;
    });
    return model;
  }

  @override
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    throw UnsupportedError(
      'On-device TTS is not supported on web (flutter_edge_ai_speech TTS is native-only).',
    );
  }

  @override
  Future<void> initializeVectorStore(String databasePath) async {
    await ServiceRegistry.instance.vectorStoreRepository.initialize(
      databasePath,
    );
  }

  @override
  Future<void> flushVectorStore() async {
    await ServiceRegistry.instance.vectorStoreRepository.flush();
  }

  @override
  Future<void> addDocumentWithEmbedding({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    await ServiceRegistry.instance.vectorStoreRepository.addDocument(
      id: id,
      content: content,
      embedding: embedding,
      metadata: metadata,
    );
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    String? metadata,
  }) async {
    final embedder = _embedderCache.model;
    if (embedder == null) {
      throw StateError(
        'No embedding model is active. addDocument(content:) and '
        'searchSimilar(query:) auto-embed text, which requires an embedding '
        'model. Install and activate one with FlutterEdgeAi.installEmbedder(...) '
        '(or modelManager.setActiveModel) before calling these methods — or '
        'pass a precomputed vector to addDocumentWithEmbedding(embedding:).',
      );
    }

    // Generate embedding and add document
    final embedding = await embedder.generateEmbedding(
      content,
      taskType: TaskType.retrievalDocument,
    );
    await ServiceRegistry.instance.vectorStoreRepository.addDocument(
      id: id,
      content: content,
      embedding: embedding,
      metadata: metadata,
    );
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required String query,
    int topK = 5,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    final embedder = _embedderCache.model;
    if (embedder == null) {
      throw StateError(
        'No embedding model is active. addDocument(content:) and '
        'searchSimilar(query:) auto-embed text, which requires an embedding '
        'model. Install and activate one with FlutterEdgeAi.installEmbedder(...) '
        '(or modelManager.setActiveModel) before calling these methods — or '
        'pass a precomputed vector to addDocumentWithEmbedding(embedding:).',
      );
    }

    // Generate query embedding and search
    final queryEmbedding = await embedder.generateEmbedding(query);
    return await ServiceRegistry.instance.vectorStoreRepository.searchSimilar(
      queryEmbedding: queryEmbedding,
      topK: topK,
      threshold: threshold,
      filter: filter,
    );
  }

  @override
  Future<VectorStoreStats> getVectorStoreStats() async {
    return await ServiceRegistry.instance.vectorStoreRepository.getStats();
  }

  @override
  Future<void> clearVectorStore() async {
    await ServiceRegistry.instance.vectorStoreRepository.clear();
  }

  @override
  Future<void> removeDocument({required String id}) async {
    await ServiceRegistry.instance.vectorStoreRepository.removeDocument(id: id);
  }

  @override
  bool get enableHnsw =>
      ServiceRegistry.instance.vectorStoreRepository.enableHnsw;

  @override
  set enableHnsw(bool value) {
    ServiceRegistry.instance.vectorStoreRepository.enableHnsw = value;
  }
}
