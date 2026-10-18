import 'dart:async';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';
import 'package:flutter_edge_ai/src/domain/no_active_model_error.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../interface.dart';
import '../model_file_manager_interface.dart';
import '../domain/multimodal_order.dart';
import '../domain/platform_types.dart';

import '../model.dart';
import '../domain/model_source.dart';
import '../registry/engine_registry.dart';
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

/// Normalizes a `createTtsModel`/`getActiveTts` `language` argument for the
/// same-model reuse guard's store/compare — defaults `null` to `'english'`
/// (mirrors `LiteRtTtsBackend.createModel`'s `config.language ?? 'english'`)
/// and lowercases so `null`, `'english'`, and `'English'` all compare equal
/// (they build the SAME synthesizer either way — `Qwen3Prompt.build` already
/// lowercases the language it's given). Without this, storing/comparing the
/// raw argument tripped a spurious `StateError` for effectively-identical
/// requests (e.g. `getActiveTts()` then `getActiveTts(language: 'english')`).
/// Duplicated from `flutter_edge_ai_mobile.dart` (same shape, separate shell).
String _normalizeTtsLanguage(String? language) =>
    (language ?? 'english').toLowerCase();

/// Desktop implementation of FlutterEdgeAi plugin
///
/// Uses dart:ffi to communicate directly with LiteRT-LM C API
/// via libLiteRtLm.dylib/so/dll for model inference.
class FlutterEdgeAiDesktop extends FlutterEdgeAiPlugin {
  FlutterEdgeAiDesktop._();

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

  // STT model
  Completer<SpeechRecognizer>? _initSttCompleter;
  SpeechRecognizer? _initializedSttModel;
  String? _lastActiveSttModelName;

  // TTS model
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

  @override
  ModelFileManager get modelManager => _modelManager;

  @override
  InferenceModel? get initializedModel => _modelCache.model;

  @override
  EmbeddingModel? get initializedEmbeddingModel => _embedderCache.model;

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
        build: () async {
          final isBuiltIn = requestedSpec.fileType == ModelFileType.builtIn;

          String modelPath = '';
          if (!isBuiltIn) {
            // Verify model is installed
            final isInstalled = await _modelManager.isModelInstalled(
              activeModel,
            );
            if (!isInstalled) {
              throw Exception('Active model is no longer installed');
            }

            // Get model file path
            final modelFilePaths = await _modelManager.getModelFilePaths(
              activeModel,
            );
            if (modelFilePaths == null || modelFilePaths.isEmpty) {
              throw Exception('Model file paths not found');
            }

            modelPath = modelFilePaths.values.first;
            edgeAiLog('[FlutterEdgeAiDesktop] Using model: $modelPath');
          } else {
            edgeAiLog(
              '[FlutterEdgeAiDesktop] Built-in model ${requestedSpec.name}: '
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
          final spec = requestedSpec;
          final config = runtimeConfigFor(
            requestedParams,
            modelPath: modelPath,
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
          if (activationDataType != null &&
              spec.fileType != ModelFileType.litertlm) {
            edgeAiLog(
              '[FlutterEdgeAi] activationDataType (${activationDataType.name}) is '
              'read only by the .litertlm engine; ${engine.name} ignores it for '
              'ModelFileType.${spec.fileType.name}.',
            );
          }
          return engine.createModel(spec, config);
        },
      );
    });
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
  }) async {
    // Check if active STT model changed
    final currentActiveModel = _modelManager.activeSttModel;
    if (_initSttCompleter != null &&
        _initializedSttModel != null &&
        _lastActiveSttModelName != null) {
      final modelChanged =
          currentActiveModel == null ||
          currentActiveModel.name != _lastActiveSttModelName;
      if (modelChanged) {
        await _initializedSttModel?.close();
        _initSttCompleter = null;
        _initializedSttModel = null;
        _lastActiveSttModelName = null;
      } else {
        // Same model — reuse the singleton, RETARGETED to the requested
        // language. Without this the caller gets back the recognizer built for
        // the FIRST language and transcribes into it with no error; see the
        // matching branch in the mobile shell. The decoder prompt is rebuilt
        // per transcription, so this is a field write, not a reload.
        final cached = await _initSttCompleter!.future;
        cached.language = language;
        return cached;
      }
    }

    // Return existing if initialization in progress — retargeted, for the same
    // reason as the mobile shell: a language requested while the first load is
    // still running would otherwise be dropped silently.
    if (_initSttCompleter case Completer<SpeechRecognizer> completer) {
      final cached = await completer.future;
      cached.language = language;
      return cached;
    }

    final completer = _initSttCompleter = Completer<SpeechRecognizer>();

    try {
      // Resolve model and tokenizer paths from active STT model
      if (modelPath == null || tokenizerPath == null) {
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

        modelPath ??= filePaths[PreferencesKeys.sttModelFile];
        tokenizerPath ??= filePaths[PreferencesKeys.sttTokenizerFile];
      }

      if (modelPath == null) {
        throw StateError('STT model path is required');
      }

      edgeAiLog('[FlutterEdgeAiDesktop] Loading STT model: $modelPath');

      if (tokenizerPath == null) {
        throw StateError('Tokenizer path is required for desktop STT');
      }

      // Dispatches construction through the SttRegistry (probe-chain, mirrors
      // EmbeddingRegistry). The backend reads spec.sttModelType to select its
      // runtime profile, and ONLY config.modelPath/config.tokenizerPath for
      // path resolution.
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
      // modelPath/tokenizerPath are non-null here (resolved in the preamble).
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
      final model = await backend.createModel(specForBackend, sttConfig);

      // Core owns the singleton lifecycle: track it + reset on close. The
      // package-built model fires this via CloseNotifier (addCloseListener).
      _initializedSttModel = model;
      model.addCloseListener(() {
        _initializedSttModel = null;
        _initSttCompleter = null;
        _lastActiveSttModelName = null;
      });

      _lastActiveSttModelName = currentActiveModel?.name;
      completer.complete(model);
      return model;
    } catch (e, st) {
      completer.completeError(e, st);
      _initSttCompleter = null;
      _initializedSttModel = null;
      _lastActiveSttModelName = null;
      // Return the error-completed completer future (not rethrow) so exactly one
      // Future is in flight — a bare rethrow orphans completer.future. See #394.
      return completer.future;
    }
  }

  @override
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    final activeModel = _modelManager.activeTtsModel;
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
        // Active model changed - close old model and create new one.
        // Reset the singleton fields BEFORE awaiting close() so a concurrent
        // createTtsModel() can't pass the guard mid-close and spawn a duplicate
        // worker (which would then be orphaned → native leak). Capture the old
        // model first, then close it after the reset.
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
        return _initTtsCompleter!.future;
      }
    }

    // Return existing if initialization in progress
    if (_initTtsCompleter case Completer<SpeechSynthesizer> completer) {
      return completer.future;
    }

    final completer = _initTtsCompleter = Completer<SpeechSynthesizer>();

    try {
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
      completer.completeError(e, st);
      _initTtsCompleter = null;
      _initializedTtsModel = null;
      _lastActiveTtsSpec = null;
      _lastActiveTtsLanguage = null;
      // Return the completer's future (rather than a bare rethrow) so there
      // is exactly one Future in flight for this call — an unheeded
      // `completer.future` (left behind whenever no concurrent caller
      // grabbed a reference to it first) would otherwise surface as an
      // unhandled async error.
      return completer.future;
    }
  }
}

/// Check if current platform is desktop
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
