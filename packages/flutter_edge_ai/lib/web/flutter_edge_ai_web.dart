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

  /// The pending or completed build of [_initializedModel]. Reused while the
  /// active model and the runtime knobs stay the same; see [createModel].
  Completer<InferenceModel>? _initCompleter;

  /// Which model [_initializedModel] was built for.
  _ModelIdentity? _lastModelIdentity;

  /// The runtime knobs [_initializedModel] was built with.
  ActiveModelParams? _lastInferenceParams;

  /// What the in-flight build is building, while [_initCompleter] is pending.
  /// Kept in lockstep with [_initCompleter], as on mobile and desktop.
  ({_ModelIdentity identity, ActiveModelParams params})? _inFlightRequest;

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
    final active = manager.activeInferenceModel;
    if (active is! InferenceModelSpec) {
      throw StateError(
        'No active inference model set. Use `FlutterEdgeAi.installModel()` first',
      );
    }

    // The whole active spec is the key, not only its name: a re-install from
    // another source under the same file name, or a LoRA added or removed,
    // keeps the name and changes the weights the resolver loads. The engines
    // read only modelType and fileType from the spec they get and resolve the
    // weights themselves, so those two come from the caller, as they always
    // have on web, and are part of the key too.
    final requestedIdentity = (
      active: active,
      modelType: modelType,
      fileType: fileType,
    );
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
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      activationDataType: activationDataType,
      maxConcurrentSessions: maxConcurrentSessions,
      loraRanks: loraRanks,
    );

    // The rest mirrors FlutterEdgeAiMobile.createModel, whose comments say
    // why each step is shaped the way it is.
    if (_initCompleter != null &&
        _initializedModel != null &&
        _lastModelIdentity != null) {
      final modelChange = _modelChange(_lastModelIdentity!, requestedIdentity);
      final baseline = _lastInferenceParams;
      final changedParam = baseline == null
          ? 'unknown — no recorded config for the cached model'
          : baseline.firstDifference(requestedParams);

      if (modelChange != null || changedParam != null) {
        edgeAiLog(
          modelChange != null
              ? '[FlutterEdgeAiWeb] Active model changed ($modelChange)'
              : '[FlutterEdgeAiWeb] Runtime config changed ($changedParam) '
                    'for ${requestedSpec.name} — rebuilding the model',
        );
        // State cleared BEFORE the close is awaited, so no caller observes a
        // half-torn singleton; a throwing close must not keep it registered.
        final closing = _initializedModel;
        _initCompleter = null;
        _inFlightRequest = null;
        _initializedModel = null;
        _lastModelIdentity = null;
        _lastInferenceParams = null;
        try {
          await closing?.close();
        } catch (e) {
          edgeAiLog(
            '[FlutterEdgeAiWeb] Old model close() failed, continuing with '
            'rebuild: $e',
          );
        }
      } else {
        edgeAiLog(
          '[FlutterEdgeAiWeb] Reusing existing model instance for '
          '${requestedSpec.name}',
        );
        return _initCompleter!.future;
      }
    }

    // A build already in flight is shared only with a caller asking for the
    // same model and knobs; anyone else waits for it, then rebuilds.
    if (_initCompleter case Completer<InferenceModel> completer) {
      final pending = _inFlightRequest;
      final modelChange = pending == null
          ? null
          : _modelChange(pending.identity, requestedIdentity);
      final changedParam = pending?.params.firstDifference(requestedParams);
      if (pending != null && modelChange == null && changedParam == null) {
        return completer.future;
      }
      edgeAiLog(
        '[FlutterEdgeAiWeb] A model build is already in flight with a '
        'different request (${modelChange ?? 'config $changedParam'}) — '
        'waiting for it, then rebuilding',
      );
      var inFlightFailed = false;
      try {
        await completer.future;
      } catch (_) {
        inFlightFailed = true;
        edgeAiLog(
          '[FlutterEdgeAiWeb] In-flight build failed; building fresh for this '
          'request',
        );
      }
      if (inFlightFailed && identical(_initCompleter, completer)) {
        _initCompleter = null;
        _inFlightRequest = null;
      }
      return createModel(
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
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        activationDataType: activationDataType,
        maxConcurrentSessions: maxConcurrentSessions,
      );
    }

    final completer = _initCompleter = Completer<InferenceModel>();
    _inFlightRequest = (identity: requestedIdentity, params: requestedParams);

    try {
      // Engine selection routes through [EngineRegistry] (probe-chain), as on
      // mobile and desktop: .task → MediaPipe, .litertlm → LiteRT-LM, from
      // their own packages via FlutterEdgeAi.initialize(inferenceEngines: ...).
      // Web registers no default; each engine builds its own
      // WebModelSourceResolver. Web has no resolved file path, so the
      // RuntimeConfig's modelPath is empty.
      final spec = requestedSpec;
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
      // Identity-guarded: a late close of a superseded model must not clear a
      // newer, live one.
      _initializedModel = model;
      model.addCloseListener(() {
        if (!identical(_initializedModel, model)) return;
        _initializedModel = null;
        _initCompleter = null;
        _inFlightRequest = null;
        _lastModelIdentity = null;
        _lastInferenceParams = null;
      });

      _lastModelIdentity = requestedIdentity;
      _lastInferenceParams = requestedParams;
      _inFlightRequest = null;
      completer.complete(model);
      return model;
    } catch (e, st) {
      _initCompleter = null;
      _inFlightRequest = null;
      _initializedModel = null;
      _lastModelIdentity = null;
      _lastInferenceParams = null;
      completer.completeError(e, st);
      // The completer's future, not a throw: one future in flight, none
      // orphaned (#394).
      return completer.future;
    }
  }

  /// How [to] differs from [from] as a model to build, or null if it does
  /// not: another active model, the same name with other weights (another
  /// source, a LoRA added or removed), or the same model asked for as another
  /// modelType or fileType.
  static String? _modelChange(_ModelIdentity from, _ModelIdentity to) {
    if (from.active.name != to.active.name) {
      return '${from.active.name} → ${to.active.name}';
    }
    if (from.active != to.active) {
      return '${to.active.name} re-installed with another source or LoRA';
    }
    if (from.modelType != to.modelType) {
      return 'modelType ${from.modelType.name} → ${to.modelType.name}';
    }
    if (from.fileType != to.fileType) {
      return 'fileType ${from.fileType.name} → ${to.fileType.name}';
    }
    return null;
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
          'No active embedding model set. Use `FlutterEdgeAi.installEmbedder()` or `modelManager.ensureModelReadyFromSpec()` first',
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

/// The model a web build is for: the active spec, compared by value (source,
/// LoRA and file set included), and the modelType and fileType it was asked
/// for.
typedef _ModelIdentity = ({
  InferenceModelSpec active,
  ModelType modelType,
  ModelFileType fileType,
});
