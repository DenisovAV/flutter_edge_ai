import 'dart:async';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';

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

/// Normalizes a `createTtsModel`/`getActiveTts` `language` argument for the
/// same-model reuse guard's store/compare — defaults `null` to `'english'`
/// (mirrors `LiteRtTtsBackend.createModel`'s `config.language ?? 'english'`)
/// and lowercases so `null`, `'english'`, and `'English'` all compare equal
/// (they build the SAME synthesizer either way — `Qwen3Prompt.build` already
/// lowercases the language it's given). Without this, storing/comparing the
/// raw argument tripped a spurious `StateError` for effectively-identical
/// requests (e.g. `getActiveTts()` then `getActiveTts(language: 'english')`).
String _normalizeTtsLanguage(String? language) =>
    (language ?? 'english').toLowerCase();

class FlutterEdgeAiMobile extends FlutterEdgeAiPlugin {
  /// The cached inference model and the rules for reusing it, shared with the
  /// desktop and web shells.
  final InferenceModelCache _modelCache = InferenceModelCache();

  /// The cached embedder, the rule for reusing it, and the serialisation that
  /// makes the rule mean anything — shared with the desktop and web shells,
  /// because three hand-rolled copies of it were wrong in three different ways.
  final EmbedderCache _embedderCache = EmbedderCache();

  Completer<SpeechRecognizer>? _initSttCompleter;
  SpeechRecognizer? _initializedSttModel;
  SttModelSpec?
  _lastActiveSttSpec; // Track which spec was used to create _initializedSttModel

  Completer<SpeechSynthesizer>? _initTtsCompleter;
  SpeechSynthesizer? _initializedTtsModel;
  TtsModelSpec?
  _lastActiveTtsSpec; // Track which spec was used to create _initializedTtsModel
  // The `language` the active singleton was built with, NORMALIZED
  // ([_normalizeTtsLanguage] — defaulted + lowercased) so a same-effective-
  // language request compared raw-to-raw (e.g. null vs. 'english', or
  // 'English' vs. 'english') doesn't spuriously trip the guard below.
  // Reusing the singleton for a genuinely DIFFERENT language would silently
  // emit wrong-language audio with no error — see the same-model branch in
  // createTtsModel below.
  String? _lastActiveTtsLanguage;

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
  }) async {
    // Modern API: Use active STT model if paths not provided
    if (modelPath == null || tokenizerPath == null) {
      final manager = _unifiedManager;
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

      // Check if singleton exists and matches the active model
      if (_initSttCompleter != null &&
          _initializedSttModel != null &&
          _lastActiveSttSpec != null) {
        final currentSpec = _lastActiveSttSpec!;
        final requestedSpec = activeModel as SttModelSpec;

        if (currentSpec.name != requestedSpec.name) {
          // Active model changed - close old model and create new one
          edgeAiLog(
            '⚠️  Active STT model changed: ${currentSpec.name} → ${requestedSpec.name}',
          );
          edgeAiLog('🔄 Closing old STT model and creating new one...');
          await _initializedSttModel?.close();
          // Reset explicitly (mirror the desktop shell) instead of relying on
          // the async close-listener, so the in-progress guard below cannot
          // return the completer that is being torn down.
          _initSttCompleter = null;
          _initializedSttModel = null;
          _lastActiveSttSpec = null;
        } else {
          // Same model - return existing singleton, RETARGETED to the requested
          // language.
          //
          // Load-bearing, and the reason `SpeechRecognizer.language` is
          // settable: this branch is the common case (a recognizer built at
          // startup, a language picked later), and without the assignment the
          // caller gets back the recognizer built for the FIRST language and
          // transcribes into it with no error — a documented parameter that
          // works exactly once per process. Whisper's decoder prompt is rebuilt
          // per transcription, so this is a field write, not a reload.
          edgeAiLog(
            'ℹ️  Reusing existing STT model instance for ${requestedSpec.name}',
          );
          final cached = await _initSttCompleter!.future;
          cached.language = language;
          return cached;
        }
      }

      modelPath = activeModelPath;
      tokenizerPath = activeTokenizerPath;

      edgeAiLog(
        'Using active STT model: $modelPath, tokenizer: $tokenizerPath',
      );
    } else {
      // Legacy API with explicit paths - check if singleton exists
      if (_initSttCompleter case Completer<SpeechRecognizer> completer) {
        edgeAiLog('ℹ️  Reusing existing STT model instance (Legacy API)');
        // `createSttModel`'s dartdoc promises it retargets an existing
        // recognizer. On this arm it did not, so a second explicit-paths call
        // with a new language returned the first one's, silently.
        final cached = await completer.future;
        cached.language = language;
        return cached;
      }
    }

    // In-progress guard (Modern-API path): a concurrent createSttModel() during
    // the initial load — completer set but the model not yet published to
    // _initializedSttModel — must return the existing completer, not fall
    // through and spawn a SECOND SttWorker/native model. Mirrors the desktop
    // shell (which the Modern-API branch above otherwise lacked).
    if (_initSttCompleter case Completer<SpeechRecognizer> completer) {
      // A caller arriving DURING the first load gets that load's recognizer —
      // so it must still be retargeted, or a language picked while the model is
      // still loading is dropped with no error. The window is wide: an isolate
      // spawn plus a ~51k-entry tokenizer parse plus a model compile.
      final cached = await completer.future;
      cached.language = language;
      return cached;
    }

    final completer = _initSttCompleter = Completer<SpeechRecognizer>();

    // Verify the active model is still installed (for Modern API path)
    final manager = _unifiedManager;
    final activeModel = manager.activeSttModel;

    if (activeModel != null) {
      final isModelInstalled = await manager.isModelInstalled(activeModel);
      if (!isModelInstalled) {
        completer.completeError(
          Exception(
            'Active STT model is no longer installed. Use the `modelManager` to load the model first',
          ),
        );
        return completer.future;
      }
    }

    try {
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
      // modelPath/tokenizerPath are non-null here (resolved in the preamble or
      // passed by the legacy API). maxTokens is unused by STT.
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
      final model = await backend.createModel(specForBackend, sttConfig);

      // Core owns the singleton lifecycle: track it + reset on close. The
      // package-built model fires this via CloseNotifier (addCloseListener).
      _initializedSttModel = model;
      model.addCloseListener(() {
        _initializedSttModel = null;
        _initSttCompleter = null;
        _lastActiveSttSpec = null;
      });

      // Save the spec that was used to create this model (Modern API path only)
      if (activeSpec != null) {
        _lastActiveSttSpec = activeSpec;
      }

      completer.complete(model);
      return model;
    } catch (e, st) {
      // FIX #170: Reset state to allow retry with different model
      _initSttCompleter = null;
      _initializedSttModel = null;
      _lastActiveSttSpec = null;
      completer.completeError(e, st);
      // Return the error-completed completer future (not a separate throw) so
      // exactly one Future is in flight — a bare throw would orphan
      // completer.future (no listener in the single-caller path) → spurious
      // unhandled-async. Mirrors createTtsModel. See #394.
      return completer.future;
    }
  }

  @override
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    final manager = _unifiedManager;
    final activeModel = manager.activeTtsModel;
    if (activeModel is! TtsModelSpec) {
      throw StateError(
        'No active TTS model set. Use FlutterEdgeAi.installTts() first.',
      );
    }

    // Check if singleton exists and matches the active model
    if (_initTtsCompleter != null &&
        _initializedTtsModel != null &&
        _lastActiveTtsSpec != null) {
      if (_lastActiveTtsSpec!.name != activeModel.name) {
        // Active model changed - close old model and create new one
        edgeAiLog(
          '⚠️  Active TTS model changed: ${_lastActiveTtsSpec!.name} → ${activeModel.name}',
        );
        edgeAiLog('🔄 Closing old TTS model and creating new one...');
        // Reset the singleton fields BEFORE awaiting close() so a concurrent
        // createTtsModel() that interleaves during the await cannot pass the
        // "all three non-null" guard and spawn a duplicate worker (which would
        // then be orphaned → native leak). Capture the old model first, then
        // close it after the reset.
        final old = _initializedTtsModel;
        _initTtsCompleter = null;
        _initializedTtsModel = null;
        _lastActiveTtsSpec = null;
        _lastActiveTtsLanguage = null;
        await old?.close();
      } else if (_normalizeTtsLanguage(language) != _lastActiveTtsLanguage) {
        // Same model, but a DIFFERENT language was requested — reusing the
        // singleton here would silently emit WRONG-LANGUAGE audio with no
        // error. Fail loud instead of reusing: the caller must close() the
        // existing synthesizer first (tts_screen.dart already does this on
        // every model/language switch — see LiteRtSpeechSynthesizer/
        // getActiveTts's docs). Both
        // sides are normalized ([_normalizeTtsLanguage]) so this only fires
        // for a GENUINELY different language, not e.g. null vs. 'english'
        // or 'English' vs. 'english'.
        throw StateError(
          'Active TTS synthesizer was created for language '
          "'$_lastActiveTtsLanguage'; call close() before requesting "
          "'${_normalizeTtsLanguage(language)}'.",
        );
      } else {
        // Same model, same language - return existing singleton
        edgeAiLog(
          'ℹ️  Reusing existing TTS model instance for ${activeModel.name}',
        );
        return _initTtsCompleter!.future;
      }
    }

    // In-progress guard: a concurrent createTtsModel() during the initial
    // load — completer set but the model not yet published to
    // _initializedTtsModel — must return the existing completer, not fall
    // through and spawn a SECOND TtsWorker/native model.
    if (_initTtsCompleter case Completer<SpeechSynthesizer> completer) {
      return completer.future;
    }

    final completer = _initTtsCompleter = Completer<SpeechSynthesizer>();

    try {
      final filePaths = await manager.getModelFilePaths(activeModel);
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
      final synth = await backend.createModel(activeModel, config);

      // Core owns the singleton lifecycle: track it + reset on close. The
      // package-built model fires this via CloseNotifier (addCloseListener).
      _initializedTtsModel = synth;
      _lastActiveTtsSpec = activeModel;
      _lastActiveTtsLanguage = _normalizeTtsLanguage(language);
      synth.addCloseListener(() {
        // Only reset if this close-listener still belongs to the current
        // singleton — a newer model may already have replaced it (the
        // model-changed branch above resets the fields synchronously).
        if (identical(_initializedTtsModel, synth)) {
          _initializedTtsModel = null;
          _initTtsCompleter = null;
          _lastActiveTtsSpec = null;
          _lastActiveTtsLanguage = null;
        }
      });

      completer.complete(synth);
      return synth;
    } catch (e, st) {
      _initTtsCompleter = null;
      _initializedTtsModel = null;
      _lastActiveTtsSpec = null;
      _lastActiveTtsLanguage = null;
      // Complete the completer and return its future (rather than
      // rethrowing separately) so there is exactly one Future in flight for
      // this call — a second, unheeded `completer.future` (as a bare
      // rethrow would leave behind whenever no concurrent caller grabbed a
      // reference to it first) would otherwise surface as an unhandled
      // async error.
      completer.completeError(e, st);
      return completer.future;
    }
  }
}
