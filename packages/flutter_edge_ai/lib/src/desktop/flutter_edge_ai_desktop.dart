import 'dart:async';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';
import 'package:flutter_edge_ai/src/lifecycle/speech_model_cache.dart';
import 'package:flutter_edge_ai/src/domain/no_active_model_error.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart' show internal;
import 'package:path/path.dart' as path;

import '../interface.dart';
import '../model_file_manager_interface.dart';
import '../domain/multimodal_order.dart';
import '../domain/platform_types.dart';

import '../model.dart';
import '../domain/model_source.dart';
import '../registry/engine_registry.dart';
import '../model_management/install_rule.dart' show requireInstalledAsSpecified;
import '../registry/inference_engine_provider.dart';
import '../registry/multi_model_engine.dart';
import '../registry/stt_registry.dart';
import '../registry/stt_backend_provider.dart';
import '../registry/tts_registry.dart';
import '../registry/runtime_config.dart';

// Model spec types come from the dart:io-free specs library; the manager
// implementation comes from the mobile library (desktop reuses it).
import '../model_management/model_specs.dart'
    show InferenceModelSpec, SttModelSpec, SttModelType, TtsModelSpec;
import '../mobile/flutter_edge_ai_mobile.dart' show MobileModelManager;

import '../model_management/constants/preferences_keys.dart';

import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_loader.dart';

/// Desktop implementation of FlutterEdgeAi plugin
///
/// Uses dart:ffi to communicate directly with LiteRT-LM C API
/// via libLiteRtLm.dylib/so/dll for model inference.
class FlutterEdgeAiDesktop extends FlutterEdgeAiPlugin {
  FlutterEdgeAiDesktop._() {
    attachInferenceModelCache(this, _modelCache);
    attachEmbedderCache(this, _embedderCache);
    attachSpeechModelCaches(
      this,
      stt: _sttCache.closeForRemoval,
      tts: _ttsCache.closeForRemoval,
    );
  }

  static FlutterEdgeAiDesktop? _instance;

  /// Get the singleton instance
  static FlutterEdgeAiDesktop get instance =>
      _instance ??= FlutterEdgeAiDesktop._();

  /// Register this implementation as the plugin instance
  ///
  /// This is called automatically by Flutter for dartPluginClass.
  /// No parameters needed for desktop platforms.
  static void registerWith() {
    FlutterEdgeAiPlugin.instance = instance;
    edgeAiLog('[FlutterEdgeAiDesktop] Plugin registered for desktop platform');
  }

  // Reuse MobileModelManager for desktop (same filesystem behavior)
  late final MobileModelManager _modelManager = MobileModelManager();

  /// The cached inference model and the rules for reusing it, shared with the
  /// mobile and web shells.
  final InferenceModelCache _modelCache = InferenceModelCache();

  // Embedding model: one shared cache instead of a completer, a model and a
  // params field kept in lockstep by hand. This shell's hand-rolled version
  // gated its comparison on a field that is only assigned after the build
  // returns, then joined any build in flight without comparing at all.
  final EmbedderCache _embedderCache = EmbedderCache();

  /// The cached recognizer and synthesizer and the rules for reusing them,
  /// shared with the mobile and web shells.
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

  @override
  ModelFileManager get modelManager => _modelManager;

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
    bool supportAudio = false,
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
      // Check active model
      final activeModel = _modelManager.activeInferenceModel;
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
    final isBuiltIn = spec.fileType == ModelFileType.builtIn;

    String modelPath = '';
    if (!isBuiltIn) {
      // Verify model is installed
      final isInstalled = await _modelManager.isModelInstalled(spec);
      if (!isInstalled) {
        throw Exception(
          active
              ? 'Active model is no longer installed'
              : 'Model ${spec.name} is not installed',
        );
      }

      // Get model file path
      final modelFilePaths = await _modelManager.getModelFilePaths(spec);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw Exception('Model file paths not found');
      }

      modelPath = modelFilePaths.values.first;
      edgeAiLog('[FlutterEdgeAiDesktop] Using model: $modelPath');
    } else {
      edgeAiLog(
        '[FlutterEdgeAiDesktop] Built-in model ${spec.name}: '
        'skipping file/installed checks (no on-disk file)',
      );
    }

    // Core resolves the model path + owns the singleton lifecycle, then
    // dispatches construction polymorphically through the EngineRegistry.
    // Desktop registers NO default engine — the LiteRtLmEngine is supplied
    // via FlutterEdgeAi.initialize(inferenceEngines:). If the registry is
    // empty (or no engine canHandle the spec), the findFor==null StateError
    // below fires. Desktop is litertlm-only; a `.task` request would simply
    // find no matching engine.
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
    // Serialised, because this shell resolves paths from preferences before it
    // can compare them — an await between "decide" and "record" that two
    // callers can both slip through. Moving that resolution earlier once
    // widened exactly that window; the lane makes the ordering not matter.
    return _embedderCache.serialize(
      () => loadActiveEmbedder(
        manager: _modelManager,
        cache: _embedderCache,
        preferredBackend: preferredBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        entryPoint: createEmbeddingModel,
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
      var files = const <String>{};
      String? label;
      // Locals, not the parameters: this runs again after every wait, and
      // must resolve the active model again each time.
      var resolvedModelPath = modelPath;
      var resolvedTokenizerPath = tokenizerPath;
      // Resolve model and tokenizer paths from active STT model
      if (resolvedModelPath == null || resolvedTokenizerPath == null) {
        final activeModel = _modelManager.activeSttModel;
        if (activeModel == null) {
          throw StateError(
            'No active STT model set. '
            'Use `FlutterEdgeAi.installStt()` first.',
          );
        }

        final filePaths = await _modelManager.getModelFilePaths(activeModel);
        if (filePaths == null || filePaths.isEmpty) {
          throw StateError('STT model file paths not found');
        }

        resolvedModelPath ??= filePaths[PreferencesKeys.sttModelFile];
        resolvedTokenizerPath ??= filePaths[PreferencesKeys.sttTokenizerFile];
        files = {for (final file in activeModel.files) file.filename};
        label = activeModel.name;
      }

      if (resolvedModelPath == null) {
        throw StateError('STT model path is required');
      }
      if (resolvedTokenizerPath == null) {
        throw StateError('Tokenizer path is required for desktop STT');
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
    // Same model — reuse the singleton, RETARGETED to the requested language.
    // Without this the caller gets back the recognizer built for the FIRST
    // language and transcribes into it with no error; see the mobile shell.
    // The decoder prompt is rebuilt per transcription, so this is a field
    // write, not a reload. A caller joining a build in flight is retargeted
    // too.
    onReuse: (recognizer) => recognizer.language = language,
  );

  Future<SpeechRecognizer> _buildStt({
    required String modelPath,
    required String tokenizerPath,
    required PreferredBackend? preferredBackend,
    required String? language,
  }) async {
    edgeAiLog('[FlutterEdgeAiDesktop] Loading STT model: $modelPath');

    // Dispatches construction through the SttRegistry (probe-chain, mirrors
    // EmbeddingRegistry). The backend reads spec.sttModelType to select its
    // runtime profile, and ONLY config.modelPath/config.tokenizerPath for
    // path resolution.
    final currentActiveModel = _modelManager.activeSttModel;
    final activeSpec = currentActiveModel is SttModelSpec
        ? currentActiveModel
        : null;
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
    // resolved file paths (FileSource) purely to satisfy the signature.
    // sttModelType defaults to moonshine — the only shipped profile — for
    // this legacy-path fallback.
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
    final activeModel = _modelManager.activeTtsModel;
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
    final filePaths = await _modelManager.getModelFilePaths(activeModel);
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

/// Check if current platform is desktop
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
