import 'dart:async';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';
import 'package:flutter_edge_ai/src/lifecycle/speech_model_cache.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // MethodChannel — used by file_system_manager.dart part
import 'package:meta/meta.dart' show internal;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:background_downloader/background_downloader.dart';

import 'smart_downloader.dart'; // SmartDownloader.downloadGroup — single source of truth for the task group

import '../../flutter_edge_ai.dart';
import '../di/service_registry.dart';
import '../services/model_repository.dart' as repo;
import '../model_management/constants/preferences_keys.dart';
import '../model_management/active_embedding_identity.dart';
import '../model_management/active_identity_store.dart';
import '../model_management/model_activation.dart';
import '../model_management/install_rule.dart';
import '../model_management/restored_filename.dart';
import '../model_management/utils/local_file.dart';
import '../model_management/utils/download_temp_reclaim.dart';
import '../utils/file_name_utils.dart';
import '../registry/engine_registry.dart';
import '../registry/inference_engine_provider.dart';
import '../registry/multi_model_engine.dart';
import '../registry/stt_registry.dart';
import '../registry/tts_registry.dart';
import '../registry/runtime_config.dart';
import '../model_management/model_specs.dart';

import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_loader.dart';

// Re-export the spec value types so existing importers of this library (tests,
// example, and any external code that imported the mobile lib directly) keep
// seeing InferenceModelSpec/EmbeddingModelSpec/etc. — they used to be `part`s
// here, now they live in model_specs.dart. Safe for wasm: this library is only
// on the io graph (web uses the conditional default stub).
export '../model_management/model_specs.dart';

// New unified model management system. The spec/exception value types live in
// the dart:io-free `model_specs.dart` library (extracted for dart2wasm/web
// compat); the implementation parts below stay here (they use dart:io).
part '../model_management/utils/file_system_manager.dart';
part '../model_management/utils/resume_checker.dart';
part '../model_management/managers/mobile_model_manager.dart';

class FlutterEdgeAiMobile extends FlutterEdgeAiPlugin {
  FlutterEdgeAiMobile() {
    attachInferenceModelCache(this, _modelCache);
    attachEmbedderCache(this, _embedderCache);
    attachSpeechModelCaches(
      this,
      stt: _sttCache.closeForRemoval,
      tts: _ttsCache.closeForRemoval,
    );
  }

  /// The cached inference model and the rules for reusing it, shared with the
  /// desktop and web shells.
  final InferenceModelCache _modelCache = InferenceModelCache();

  /// The cached embedder, the rule for reusing it, and the serialisation that
  /// makes the rule mean anything — shared with the desktop and web shells,
  /// because three hand-rolled copies of it were wrong in three different ways.
  final EmbedderCache _embedderCache = EmbedderCache();

  /// The cached recognizer and synthesizer and the rules for reusing them,
  /// shared with the desktop and web shells.
  final SpeechModelCache<SpeechRecognizer, SttCacheKey> _sttCache =
      SpeechModelCache(
        close: (recognizer) => recognizer.close(),
        addCloseListener: (recognizer, listener) =>
            recognizer.addCloseListener(listener),
      );
  final SpeechModelCache<SpeechSynthesizer, TtsCacheKey> _ttsCache =
      SpeechModelCache(
        close: (synthesizer) => synthesizer.close(),
        addCloseListener: (synthesizer, listener) =>
            synthesizer.addCloseListener(listener),
        decide: decideTtsReuse,
      );

  // Made public for example app integration
  late final MobileModelManager _unifiedManager = MobileModelManager();

  @override
  MobileModelManager get modelManager => _unifiedManager;

  @override
  InferenceModel? get initializedModel => _modelCache.model;

  @override
  EmbeddingModel? get initializedEmbeddingModel => _embedderCache.model;

  @Deprecated('Use FlutterEdgeAi.getActiveModel(). Removed in 2.6.0.')
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
    bool supportImage = false,
    bool supportAudio = false, // e.g. Gemma 4 / Gemma 3n .litertlm
    MultimodalOrder? multimodalOrder,
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) => obtainActiveModel(
    modelType: modelType,
    fileType: fileType,
    maxTokens: maxTokens,
    preferredBackend: preferredBackend,
    preferredVisionBackend: preferredVisionBackend,
    preferredAudioBackend: preferredAudioBackend,
    loraRanks: loraRanks,
    maxNumImages: maxNumImages,
    supportImage: supportImage,
    supportAudio: supportAudio,
    multimodalOrder: multimodalOrder,
    enableSpeculativeDecoding: enableSpeculativeDecoding,
    activationDataType: activationDataType,
    maxConcurrentSessions: maxConcurrentSessions,
  );

  @internal
  @override
  Future<InferenceModel> obtainActiveModel({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    int maxTokens = 1024,
    PreferredBackend? preferredBackend,
    PreferredBackend? preferredVisionBackend,
    PreferredBackend? preferredAudioBackend,
    List<int>? loraRanks,
    int? maxNumImages,
    bool supportImage = false,
    bool supportAudio = false,
    MultimodalOrder? multimodalOrder,
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    // Resolved inside the cache, not before it: when the cache waits for a
    // build in flight and starts over, a model installed meanwhile is the one
    // built.
    return _modelCache.obtain(() {
      // Check if model is ready through unified system
      final manager = _unifiedManager;
      final activeModel = manager.activeInferenceModel;

      // No active inference model - user must set one first
      if (activeModel == null) {
        throw NoActiveModelError(
          'No active inference model set. Use `FlutterEdgeAi.installModel()` or `modelManager.ensureModelReadyFromSpec()` first',
        );
      }

      final requestedSpec = activeModel as InferenceModelSpec;

      // What the cache compares, and what the engine gets: the config is
      // built from this object (`runtimeConfigFor`), so the two cannot drift.
      final requestedParams = ActiveModelParams(
        maxTokens: maxTokens,
        preferredBackend: preferredBackend,
        preferredVisionBackend: preferredVisionBackend,
        preferredAudioBackend: preferredAudioBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        maxNumImages: maxNumImages,
        multimodalOrder:
            multimodalOrder ??
            MultimodalOrder.forModelType(requestedSpec.modelType),
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        activationDataType: activationDataType,
        maxConcurrentSessions: maxConcurrentSessions,
        loraRanks: loraRanks,
      );

      return (
        identity: (
          spec: requestedSpec,
          modelType: requestedSpec.modelType,
          fileType: requestedSpec.fileType,
        ),
        params: requestedParams,
        build: () => _buildModel(requestedSpec, requestedParams, active: true),
      );
    });
  }

  @internal
  @override
  Future<InferenceModel> openModel(
    InferenceModelSpec spec,
    ActiveModelParams params,
  ) async {
    // The engine checked is the engine that builds: the registry is asked
    // once, before the awaits of the install checks.
    final engine = requireMultiModelEngine(spec);
    if (spec.fileType != ModelFileType.builtIn) {
      await requireInstalledAsSpecified(spec);
    }
    return _buildModel(spec, params, active: false, engine: engine);
  }

  /// Builds a model for [spec]: the cached active model ([active]) or one the
  /// caller owns (`FlutterEdgeAi.openModel`), with [engine] when the caller
  /// already chose it, else the registry's.
  Future<InferenceModel> _buildModel(
    InferenceModelSpec spec,
    ActiveModelParams params, {
    required bool active,
    InferenceEngineProvider? engine,
  }) async {
    // The pre-build checks THROW rather than settle anything themselves:
    // the cache's one catch resets its state for every failure (#170),
    // and a throw keeps the stack trace.
    final manager = _unifiedManager;
    final isBuiltIn = spec.fileType == ModelFileType.builtIn;
    String modelPath = '';
    if (!isBuiltIn) {
      final isModelInstalled = await manager.isModelInstalled(spec);
      if (!isModelInstalled) {
        throw Exception(
          active
              ? 'Active model is no longer installed. Use the `modelManager` to load the model first'
              : 'Model ${spec.name} is not installed. Install it with '
                    '`FlutterEdgeAi.installModel()` first',
        );
      }

      final modelFilePaths = await manager.getModelFilePaths(spec);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw Exception(
          'Model file paths not found. Use the `modelManager` to load the model first',
        );
      }

      modelPath = modelFilePaths.values.first;
      final modelFile = File(modelPath);

      if (!await modelFile.exists()) {
        throw Exception('Model file not found at path: ${modelFile.path}');
      }

      edgeAiLog('Using unified model file: $modelPath');
    } else {
      edgeAiLog(
        'Built-in model ${spec.name}: skipping file/installed checks (no on-disk file)',
      );
    }

    // Engine selection routes ENTIRELY through [EngineRegistry] (probe-chain).
    // Core registers NO default engine: both MediaPipe (.task/.bin, from
    // flutter_edge_ai_mediapipe) and LiteRT-LM (.litertlm, from
    // flutter_edge_ai_litertlm) are fully opt-in via
    // FlutterEdgeAi.initialize(inferenceEngines: [...]). Core only resolves the
    // model path (preamble above) + owns the singleton lifecycle centrally
    // (track + reset on close); the selected engine builds the model.
    final config = runtimeConfigFor(params, modelPath: modelPath);
    engine ??= EngineRegistry.instance.findFor(spec);
    if (engine == null) throw noInferenceEngineError(spec);
    final activationDataType = params.activationDataType;
    if (activationDataType != null && spec.fileType != ModelFileType.litertlm) {
      edgeAiLog(
        '[FlutterEdgeAi] activationDataType (${activationDataType.name}) is '
        'read only by the .litertlm engine; ${engine.name} ignores it for '
        'ModelFileType.${spec.fileType.name}.',
      );
    }
    return engine.createModel(spec, config);
  }

  @override
  Future<EmbeddingModel> createEmbeddingModel({
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
  }) {
    // Serialised, because resolving paths, comparing them against the cached
    // embedder and building are three steps with awaits between them: run
    // interleaved, two callers both finish deciding before either records a
    // model, and one of the two builds is orphaned with nobody to close it.
    return _embedderCache.serialize(
      () => loadActiveEmbedder(
        manager: _unifiedManager,
        cache: _embedderCache,
        preferredBackend: preferredBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        entryPoint: createEmbeddingModel,
        verifyInstalled: true,
      ),
    );
  }

  @override
  Future<SpeechRecognizer> createSttModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
    String? language,
  }) => _sttCache.obtain(
    () async {
      final manager = _unifiedManager;
      var files = const <String>{};
      String? label;
      // Locals, not the parameters: this runs again after every wait, and
      // must resolve the active model again each time.
      var resolvedModelPath = modelPath;
      var resolvedTokenizerPath = tokenizerPath;
      // Modern API: Use active STT model if paths not provided
      if (resolvedModelPath == null || resolvedTokenizerPath == null) {
        final activeModel = manager.activeSttModel;

        // No active STT model - user must set one first
        if (activeModel == null) {
          throw StateError(
            'No active STT model set. Use `FlutterEdgeAi.installStt()` or `modelManager.ensureModelReadyFromSpec()` first',
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

        resolvedModelPath = activeModelPath;
        resolvedTokenizerPath = activeTokenizerPath;
        files = {for (final file in activeModel.files) file.filename};
        label = activeModel.name;
      }
      final sttModelPath = resolvedModelPath;
      final sttTokenizerPath = resolvedTokenizerPath;
      return (
        key: (modelPath: sttModelPath, tokenizerPath: sttTokenizerPath),
        files: files,
        label: label ?? 'STT ${path.basename(sttModelPath)}',
        build: () => _buildStt(
          modelPath: sttModelPath,
          tokenizerPath: sttTokenizerPath,
          preferredBackend: preferredBackend,
          language: language,
        ),
      );
    },
    // Load-bearing, and the reason `SpeechRecognizer.language` is settable:
    // reuse is the common case (a recognizer built at startup, a language
    // picked later), and without the assignment the caller gets back the
    // recognizer built for the FIRST language and transcribes into it with no
    // error. Whisper's decoder prompt is rebuilt per transcription, so this
    // is a field write, not a reload. A caller joining a build in flight is
    // retargeted too.
    onReuse: (recognizer) => recognizer.language = language,
  );

  Future<SpeechRecognizer> _buildStt({
    required String modelPath,
    required String tokenizerPath,
    required PreferredBackend? preferredBackend,
    required String? language,
  }) async {
    // Verify the active model is still installed (for Modern API path)
    final manager = _unifiedManager;
    final activeModel = manager.activeSttModel;

    if (activeModel != null) {
      final isModelInstalled = await manager.isModelInstalled(activeModel);
      if (!isModelInstalled) {
        throw Exception(
          'Active STT model is no longer installed. Use the `modelManager` to load the model first',
        );
      }
    }

    edgeAiLog('Using active STT model: $modelPath, tokenizer: $tokenizerPath');

    // Dispatches construction through the SttRegistry (probe-chain, mirrors
    // EmbeddingRegistry). The backend reads spec.sttModelType to select its
    // runtime profile, and ONLY config.modelPath/config.tokenizerPath for
    // path resolution — it ignores the spec arg for path resolution (see
    // LiteRtSttBackend.createModel).
    final activeSpec =
        activeModel as SttModelSpec?; // null on legacy explicit-paths
    final SttBackendProvider? backend = activeSpec != null
        ? SttRegistry.instance.findFor(activeSpec)
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
    // maxTokens is unused by STT.
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
    // The backend's createModel(spec, config) signature requires a non-null
    // spec, but it resolves paths exclusively from config. On the legacy
    // explicit-paths path there is no active spec, so synthesize one from the
    // resolved file paths (FileSource, mobile/desktop only — web swaps in its
    // own plugin) purely to satisfy the signature. sttModelType defaults to
    // moonshine — the only shipped profile — for this legacy-path fallback.
    final specForBackend =
        activeSpec ??
        SttModelSpec(
          name: 'legacy:${path.basename(modelPath)}',
          modelSource: ModelSource.file(modelPath),
          tokenizerSource: ModelSource.file(tokenizerPath),
          sttModelType: SttModelType.moonshine,
        );
    return backend.createModel(specForBackend, sttConfig);
  }

  @override
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  }) => _ttsCache.obtain(() async {
    final manager = _unifiedManager;
    final activeModel = manager.activeTtsModel;
    if (activeModel is! TtsModelSpec) {
      throw StateError(
        'No active TTS model set. Use FlutterEdgeAi.installTts() first.',
      );
    }
    return (
      key: (name: activeModel.name, language: normalizeTtsLanguage(language)),
      files: {for (final file in activeModel.files) file.filename},
      label: activeModel.name,
      build: () => _buildTts(activeModel, preferredBackend, language),
    );
  });

  Future<SpeechSynthesizer> _buildTts(
    TtsModelSpec activeModel,
    PreferredBackend? preferredBackend,
    String? language,
  ) async {
    final filePaths = await _unifiedManager.getModelFilePaths(activeModel);
    if (filePaths == null || filePaths.isEmpty) {
      throw StateError(
        'Active TTS model files not found on disk. Reinstall via installTts().',
      );
    }
    final config = RuntimeConfig(
      maxTokens: 0,
      modelPath: filePaths
          .values
          .first, // representative; TTS backend uses artifactPaths
      artifactPaths: filePaths,
      preferredBackend: preferredBackend,
      language: language,
    );
    final backend = TtsRegistry.instance.findFor(activeModel);
    if (backend == null) {
      throw StateError(
        TtsRegistry.instance.hasAny
            ? 'No registered TTS backend can handle this model '
                  '(${activeModel.ttsModelType}). Registered: '
                  '${TtsRegistry.instance.registered.map((b) => b.name).join(", ")}.'
            : 'No TTS backend registered. Pass ttsBackends: to FlutterEdgeAi.initialize().',
      );
    }
    edgeAiLog(
      'Using active TTS model: ${activeModel.name} (${filePaths.length} files)',
    );
    return backend.createModel(activeModel, config);
  }
}
