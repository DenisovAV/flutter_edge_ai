import 'dart:async';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/stt_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'package:flutter_edge_ai/src/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_loader.dart';

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
  InferenceModel? get initializedModel => _modelCache.model;

  @override
  EmbeddingModel? get initializedEmbeddingModel => _embedderCache.model;

  SpeechRecognizer? _initializedSttModel;

  /// The cached inference model and the rules for reusing it, shared with the
  /// mobile and desktop shells.
  final InferenceModelCache _modelCache = InferenceModelCache();

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
    bool supportImage = false, // Enabling image support
    bool supportAudio = false, // Enabling audio support (Gemma 3n E4B)
    MultimodalOrder? multimodalOrder, // Compared, but no web engine reads it.
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

    // Keyed on the ACTIVE model, as on mobile and desktop. Web used to build
    // from a synthetic spec named 'web-active', and since a reuse check keyed
    // on that could not see the active model change, every call closed the
    // cached model and loaded the weights again, even with nothing changed.
    // The manager holds the real identity; the engines' source resolver loads
    // the weights of that same active model, so it is what the cache must
    // follow. ensureInitialized first: after a page reload the identity is
    // restored asynchronously.
    final manager = modelManager as WebModelManager;
    await manager.ensureInitialized();
    // Resolved inside the cache, not before it: when the cache waits for a
    // build in flight and starts over, a model installed meanwhile is the one
    // built.
    return _modelCache.obtain(() {
      final active = manager.activeInferenceModel;
      if (active is! InferenceModelSpec) {
        throw NoActiveModelError(
          'No active inference model set. Use `FlutterEdgeAi.installModel()` first',
        );
      }

      // The whole active spec is the key, not only its name: a re-install from
      // another source under the same file name, or a LoRA added or removed,
      // keeps the name and changes the weights the resolver loads. The engines
      // read only modelType and fileType from the spec they get and resolve the
      // weights themselves, so those two come from the caller, as they always
      // have on web, and are part of the key too.
      final requestedSpec = InferenceModelSpec(
        name: active.name,
        modelSource: active.modelSource,
        modelType: modelType,
        fileType: fileType,
      );
      final requestedParams = ActiveModelParams(
        maxTokens: maxTokens,
        preferredBackend: preferredBackend,
        preferredVisionBackend: preferredVisionBackend,
        preferredAudioBackend: preferredAudioBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        maxNumImages: maxNumImages,
        multimodalOrder:
            multimodalOrder ?? MultimodalOrder.forModelType(modelType),
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        activationDataType: activationDataType,
        maxConcurrentSessions: maxConcurrentSessions,
        loraRanks: loraRanks,
      );

      return (
        identity: (spec: active, modelType: modelType, fileType: fileType),
        params: requestedParams,
        build: () async {
          // Engine selection routes through [EngineRegistry] (probe-chain), as on
          // mobile and desktop: .task → MediaPipe, .litertlm → LiteRT-LM, from
          // their own packages via FlutterEdgeAi.initialize(inferenceEngines: ...).
          // Web registers no default; each engine builds its own
          // WebModelSourceResolver. Web has no resolved file path, so the
          // RuntimeConfig's modelPath is empty.
          final spec = requestedSpec;
          final config = runtimeConfigFor(requestedParams, modelPath: '');
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
          return engine.createModel(spec, config);
        },
      );
    });
  }

  // === EmbeddingModel Methods - Web Implementation ===

  @override
  Future<EmbeddingModel> createEmbeddingModel({
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
  }) {
    // FIRST statement, before every guard. It is idempotent and one-shot, so
    // it needs neither resolved paths nor cache state — and putting it in a
    // branch is what made it unreachable twice: once behind the singleton
    // cache, once behind "only on reuse". The ordinary shape is a single call
    // held for the app's lifetime; if it does not speak here it never speaks.
    noticeWebEmbedderBackendIgnored(preferredBackend);

    // Serialised, so that resolving paths, comparing them and constructing the
    // model are one step — which is what stops two concurrent first callers from
    // each building one, the defect this shell actually had. On web the pass
    // runs inline and loads eagerly inside this lane, so concurrent first
    // embeddings no longer race a lazy compile either.
    return _embedderCache.serialize(
      () => loadActiveEmbedder(
        manager: modelManager,
        cache: _embedderCache,
        preferredBackend: preferredBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        entryPoint: createEmbeddingModel,
      ),
    );
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
}
