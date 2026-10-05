import 'dart:async';

import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:flutter_gemma/core/services/vector_store_filter.dart';

import '../flutter_gemma_interface.dart';
import '../model_file_manager_interface.dart';
import '../core/domain/platform_types.dart';

import '../core/model.dart';
import '../core/di/service_registry.dart';
import '../core/domain/model_source.dart';
import '../core/registry/engine_registry.dart';
import '../core/registry/embedding_registry.dart';
import '../core/registry/embedding_backend_provider.dart';
import '../core/registry/stt_registry.dart';
import '../core/registry/stt_backend_provider.dart';
import '../core/registry/tts_registry.dart';
import '../core/registry/runtime_config.dart';

// Model spec types come from the dart:io-free specs library; the manager
// implementation comes from the mobile library (desktop reuses it).
import '../core/model_management/model_specs.dart'
    show
        EmbeddingModelSpec,
        InferenceModelSpec,
        SttModelSpec,
        SttModelType,
        TtsModelSpec;
import '../mobile/flutter_gemma_mobile.dart' show MobileModelManager;

import '../core/model_management/constants/preferences_keys.dart';
import 'package:flutter_gemma/core/embedding/embedder_backend_notice.dart';
import 'package:flutter_gemma/core/embedding/embedder_cache.dart';

/// Normalizes a `createTtsModel`/`getActiveTts` `language` argument for the
/// same-model reuse guard's store/compare — defaults `null` to `'english'`
/// (mirrors `LiteRtTtsBackend.createModel`'s `config.language ?? 'english'`)
/// and lowercases so `null`, `'english'`, and `'English'` all compare equal
/// (they build the SAME synthesizer either way — `Qwen3Prompt.build` already
/// lowercases the language it's given). Without this, storing/comparing the
/// raw argument tripped a spurious `StateError` for effectively-identical
/// requests (e.g. `getActiveTts()` then `getActiveTts(language: 'english')`).
/// Duplicated from `flutter_gemma_mobile.dart` (same shape, separate shell).
String _normalizeTtsLanguage(String? language) =>
    (language ?? 'english').toLowerCase();

/// Desktop implementation of FlutterGemma plugin
///
/// Uses dart:ffi to communicate directly with LiteRT-LM C API
/// via libLiteRtLm.dylib/so/dll for model inference.
class FlutterGemmaDesktop extends FlutterGemmaPlugin {
  FlutterGemmaDesktop._();

  static FlutterGemmaDesktop? _instance;

  /// Get the singleton instance
  static FlutterGemmaDesktop get instance =>
      _instance ??= FlutterGemmaDesktop._();

  /// Register this implementation as the plugin instance
  ///
  /// This is called automatically by Flutter for dartPluginClass.
  /// No parameters needed for desktop platforms.
  static void registerWith() {
    FlutterGemmaPlugin.instance = instance;
    gemmaLog('[FlutterGemmaDesktop] Plugin registered for desktop platform');
  }

  // Reuse MobileModelManager for desktop (same filesystem behavior)
  late final MobileModelManager _modelManager = MobileModelManager();

  // Inference model singleton
  Completer<InferenceModel>? _initCompleter;
  InferenceModel? _initializedModel;
  InferenceModelSpec? _lastActiveInferenceSpec;

  /// Runtime knobs the cached model was built with. This was a three-field
  /// record — supportImage, supportAudio, maxTokens — so the other six
  /// parameters of getActiveModel were silently ignored on reuse. The shared
  /// type compares all nine and names the one that differs.
  ActiveModelParams? _lastInferenceParams;

  /// What the IN-FLIGHT build is building, while [_initCompleter] is pending.
  ///
  /// Deliberately separate from [_lastInferenceParams], which describes the
  /// model that already exists. One field cannot mean both without the two
  /// states becoming indistinguishable — and "cached model" vs "model being
  /// built" is exactly the distinction the race below turns on.
  ///
  /// Kept in lockstep with [_initCompleter]: set where that is created,
  /// cleared everywhere it is cleared.
  ({String specName, ActiveModelParams params})? _inFlightRequest;

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
  InferenceModel? get initializedModel => _initializedModel;

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
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    // Check active model
    final activeModel = _modelManager.activeInferenceModel;
    if (activeModel == null) {
      throw StateError(
        'No active inference model set. Use `FlutterGemma.installModel()` or `modelManager.setActiveModel()` first',
      );
    }

    // Hoisted out of the reuse check below: the in-flight race also
    // needs it, and that runs when the reuse check does not.
    final requestedSpec = activeModel as InferenceModelSpec;

    // Captured once: compared against the cached model below, and recorded as
    // the new baseline after a successful build.
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

    // Check if singleton exists and matches active model + runtime params
    if (_initCompleter != null &&
        _initializedModel != null &&
        _lastActiveInferenceSpec != null) {
      final currentSpec = _lastActiveInferenceSpec!;

      final modelChanged = currentSpec.name != requestedSpec.name;
      // A MISSING baseline must mean rebuild, not reuse. `?.` here returned
      // null when _lastInferenceParams was unset, and null is this function's
      // word for "nothing changed" — so "we have no record of what this model
      // was built with" and "it was built with exactly this" took the same
      // branch. That is the same collapse this whole block exists to fix, one
      // level up. The costs are not symmetric: guessing "rebuild" reloads
      // weights that were already right, guessing "reuse" hands back a model
      // configured for something else and says nothing.
      final baseline = _lastInferenceParams;
      final changedParam = baseline == null
          ? 'unknown — no recorded config for the cached model'
          : baseline.firstDifference(requestedParams);

      if (modelChanged || changedParam != null) {
        // Name the knob. "paramsChanged=true" told nobody what to change.
        gemmaLog(
          modelChanged
              ? 'Model recreation: active model changed '
                    '(${currentSpec.name} -> ${requestedSpec.name})'
              : 'Model recreation: $changedParam changed for '
                    '${requestedSpec.name}',
        );
        // Clear the state BEFORE awaiting the close, not after. Everything
        // between these two statements runs without an await, so no other
        // caller can observe a half-torn singleton — which the old order
        // allowed, in two ways:
        //
        //   * a caller arriving during the close passed the reuse check (every
        //     field was still populated) and was handed the model that was
        //     already closing; its next createSession threw "Model is closed".
        //   * two callers with different params both entered this branch, both
        //     awaited a close the second found already done, then raced to
        //     install their own build. The surviving _initCompleter and
        //     _lastInferenceParams could come from different callers, so the
        //     reuse check would hand back a model built for someone else's
        //     request — the exact failure this change exists to remove. The
        //     other interleaving simply leaked a model nothing closed.
        //
        // Clearing first also removes the reason the old code trusted the
        // close listener for two of the five fields: nothing here depends on
        // that listener running, or running in time, or running at all.
        //
        // The close is wrapped because a throwing teardown must not leave the
        // singleton registered; the fields are already clear, so the next call
        // builds fresh instead of inheriting a dead model.
        final closing = _initializedModel;
        _initCompleter = null;
        _inFlightRequest = null;
        _initializedModel = null;
        _lastActiveInferenceSpec = null;
        _lastInferenceParams = null;
        try {
          await closing?.close();
        } catch (e) {
          gemmaLog('Old model close() failed, continuing with rebuild: $e');
        }
      } else {
        gemmaLog('Reusing existing model instance for ${requestedSpec.name}');
        return _initCompleter!.future;
      }
    }

    // Return existing completer if initialization in progress
    // A build may already be in flight — an earlier caller is inside
    // engine.createModel. Returning that future unconditionally, which is what
    // this did, hands THIS caller a model built to somebody else's request:
    // two getActiveModel calls that race, one asking for GPU and one for CPU,
    // both get whichever started first and the loser is never told. It is the
    // same defect as the name-only reuse check above, just in the window where
    // the cached model does not exist yet — so the check above cannot see it.
    if (_initCompleter case Completer<InferenceModel> completer) {
      final pending = _inFlightRequest;
      final changedParam = pending?.params.firstDifference(requestedParams);
      final sameModel = pending?.specName == requestedSpec.name;
      if (pending != null && sameModel && changedParam == null) {
        // Genuinely the same request — sharing the in-flight build is the
        // point of the completer.
        return completer.future;
      }
      gemmaLog(
        '⏳ A model build is already in flight with a different request '
        '(${sameModel ? 'config $changedParam' : 'model ${pending?.specName} → ${requestedSpec.name}'})'
        ' — waiting for it, then rebuilding',
      );
      var inFlightFailed = false;
      try {
        await completer.future;
      } catch (_) {
        // That build failed. Its own catch resets the state and its caller
        // receives the error, so nothing is being swallowed here — fall
        // through and build fresh for THIS caller.
        inFlightFailed = true;
        // Logged, not silent: the "waiting for it" line above fires BEFORE
        // the await, so a build that failed and was recovered from left no
        // trace at all. The error itself still reaches the caller that
        // started that build.
        gemmaLog('In-flight build failed; building fresh for this request');
      }
      if (inFlightFailed && identical(_initCompleter, completer)) {
        // A failed build left its own completer installed. Recursing now would
        // find that same dead completer, await it, catch the same error, and
        // repeat without end — the recursion below must not depend on every
        // error path having remembered to reset. (On the SUCCESS path the
        // completer stays installed on purpose: it IS the cache. Hence the
        // failure condition rather than a bare identity check.)
        _initCompleter = null;
        _inFlightRequest = null;
      }
      // Re-enter rather than tear down mid-build: the first caller's future
      // stays valid and gets the model it asked for, and only then is it
      // replaced. On re-entry the reuse check above sees a built model whose
      // params differ and does the ordinary close-and-rebuild, so this
      // terminates — the rebuild records these params as the new baseline.
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
    _inFlightRequest = (specName: requestedSpec.name, params: requestedParams);

    try {
      final isBuiltIn = requestedSpec.fileType == ModelFileType.builtIn;

      String modelPath = '';
      if (!isBuiltIn) {
        // Verify model is installed
        final isInstalled = await _modelManager.isModelInstalled(activeModel);
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
        gemmaLog('[FlutterGemmaDesktop] Using model: $modelPath');
      } else {
        gemmaLog(
          '[FlutterGemmaDesktop] Built-in model ${requestedSpec.name}: '
          'skipping file/installed checks (no on-disk file)',
        );
      }

      // Core resolves the model path + owns the singleton lifecycle, then
      // dispatches construction polymorphically through the EngineRegistry.
      // Desktop registers NO default engine — the LiteRtLmEngine is supplied
      // via FlutterGemma.initialize(inferenceEngines:). If the registry is
      // empty (or no engine canHandle the spec), the findFor==null StateError
      // below fires. Desktop is litertlm-only; a `.task` request would simply
      // find no matching engine.
      final spec = requestedSpec;
      final config = RuntimeConfig(
        maxTokens: maxTokens,
        modelPath: modelPath,
        preferredBackend: preferredBackend,
        preferredVisionBackend: preferredVisionBackend,
        preferredAudioBackend: preferredAudioBackend,
        supportImage: supportImage,
        supportAudio: supportAudio,
        maxNumImages: maxNumImages,
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        activationDataType: activationDataType,
        maxConcurrentSessions: maxConcurrentSessions,
        // Forwarded, not merely compared. ActiveModelParams treats loraRanks as
        // a rebuild trigger and its dartdoc says the engine receives it — but
        // desktop compared it and then dropped it here, so a changed rank tore
        // down multi-gigabyte weights and handed the engine a byte-identical
        // config. Comparing a value the engine never sees is its own kind of
        // lie. Mobile and web already forwarded it.
        loraRanks: loraRanks,
      );
      final engine = EngineRegistry.instance.findFor(spec);
      if (engine == null) {
        throw StateError(
          'No inference engine can handle this model (ModelFileType.${spec.fileType.name}). '
          'Add the engine package to pubspec.yaml and pass it in inferenceEngines: '
          'of FlutterGemma.initialize(...). Registered engines: '
          '${EngineRegistry.instance.registered.map((e) => e.name).join(", ")}.',
        );
      }
      if (activationDataType != null &&
          spec.fileType != ModelFileType.litertlm) {
        gemmaLog(
          '[FlutterGemma] activationDataType (${activationDataType.name}) is '
          'read only by the .litertlm engine; ${engine.name} ignores it for '
          'ModelFileType.${spec.fileType.name}.',
        );
      }
      final model = await engine.createModel(spec, config);

      // Core owns the singleton lifecycle: track it + reset on close. The
      // package-built model fires this via CloseNotifier (addCloseListener).
      _initializedModel = model;
      _lastInferenceParams = requestedParams;
      model.addCloseListener(() {
        // Identity-guarded, as the session layer already does
        // (mobile_inference_model.dart: `if (identical(_session, session))`).
        // Without it a late close of a SUPERSEDED model nulls whatever is
        // registered now — including a newer, live model, whose next caller
        // then reloads weights that were already in memory.
        if (!identical(_initializedModel, model)) return;
        _initializedModel = null;
        _initCompleter = null;
        _inFlightRequest = null;
        _lastActiveInferenceSpec = null;
        _lastInferenceParams = null;
      });

      _lastActiveInferenceSpec = spec;
      // Nothing is in flight any more. Leaving this set would be a field
      // outliving its meaning — the reuse check above happens to shadow it
      // today, which is not a reason to keep a stale one around.
      _inFlightRequest = null;
      completer.complete(model);
      return model;
    } catch (e, st) {
      completer.completeError(e, st);
      _initCompleter = null;
      _inFlightRequest = null;
      _initializedModel = null;
      _lastActiveInferenceSpec = null;
      _lastInferenceParams = null;
      // Return the error-completed completer future (not rethrow) so exactly one
      // Future is in flight — a bare rethrow orphans completer.future. See #394.
      return completer.future;
    }
  }

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
    noticeEmbedderBackendIgnored(preferredBackend);

    // Serialised, because this shell resolves paths from preferences before it
    // can compare them — an await between "decide" and "record" that two
    // callers can both slip through. Moving that resolution earlier once
    // widened exactly that window; the lane makes the ordering not matter.
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
    final currentActiveModel = _modelManager.activeEmbeddingModel;
    // Named from how this call was MADE, not from whatever happens to be
    // active: a caller passing explicit paths while an unrelated embedder is
    // installed would otherwise see that other model's name in the log.
    String label = 'explicit paths';

    // Paths are resolved BEFORE the reuse check, and the explicit-paths caller
    // goes through the same comparison as everyone else. Both were bugs: this
    // shell compared the spec NAME, so a same-named embedder reinstalled to a
    // new file was served stale — and a caller passing explicit paths got
    // whatever singleton existed, with no comparison at all. Resolving first
    // costs one preferences read on a reuse and removes both.
    if (modelPath == null || tokenizerPath == null) {
      if (currentActiveModel == null) {
        throw StateError(
          'No active embedding model set. '
          'Use `FlutterGemma.installEmbedder()` first.',
        );
      }
      final filePaths = await _modelManager.getModelFilePaths(
        currentActiveModel,
      );
      if (filePaths == null || filePaths.isEmpty) {
        throw StateError('Embedding model file paths not found');
      }
      modelPath ??= filePaths[PreferencesKeys.embeddingModelFile];
      tokenizerPath ??= filePaths[PreferencesKeys.embeddingTokenizerFile];
      if (currentActiveModel is EmbeddingModelSpec) {
        label = currentActiveModel.name;
      }
    }
    if (modelPath == null) {
      throw StateError('Embedding model path is required');
    }
    if (tokenizerPath == null) {
      throw StateError('Tokenizer path is required for desktop embeddings');
    }

    final requestedParams = ActiveEmbedderParams(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      preferredBackend: preferredBackend,
    );
    final reused = await _embedderCache.reuseOrInvalidate(
      requestedParams,
      label: label,
    );
    if (reused != null) return reused;

    try {
      gemmaLog('[FlutterGemmaDesktop] Loading embedding model: $modelPath');
      // No throw for PreferredBackend.npu here any more. It was the only
      // `getActive*` path where a PREFERENCE was a hard error, and it
      // contradicted three things at once: `gpu` passed silently to the
      // identical CPU build, desktop INFERENCE falls npu -> gpu -> cpu rather
      // than throwing, and PreferredBackend's own contract promises a
      // fallback. Its message was also wrong about Windows NPU. Callers now
      // get a CPU embedder and can read `activeBackend` to see it.

      // The LiteRT embedding runtime lives in flutter_gemma_litertlm; core
      // resolves paths (preamble above) + owns the singleton lifecycle, then
      // dispatches construction through the EmbeddingRegistry. The backend
      // reads ONLY config.modelPath/config.tokenizerPath — it ignores the spec
      // arg for path resolution.
      final activeSpec = currentActiveModel is EmbeddingModelSpec
          ? currentActiveModel
          : null;
      final EmbeddingBackendProvider? backend = activeSpec != null
          ? EmbeddingRegistry.instance.findFor(activeSpec)
          : (EmbeddingRegistry.instance.registered.isNotEmpty
                ? EmbeddingRegistry.instance.registered.first
                : null);
      if (backend == null) {
        throw StateError(
          'No embedding backend registered. Add flutter_gemma_litertlm to '
          'pubspec.yaml and pass LiteRtEmbeddingBackend() in '
          'embeddingBackends: of FlutterGemma.initialize(...). Registered '
          'backends: '
          '${EmbeddingRegistry.instance.registered.map((b) => b.name).join(", ")}.',
        );
      }
      // modelPath/tokenizerPath are non-null here (resolved in the preamble).
      // maxTokens is unused by embeddings.
      final embConfig = RuntimeConfig(
        maxTokens: 0,
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: preferredBackend,
      );
      // The backend's createModel(spec, config) signature requires a non-null
      // spec, but it resolves paths exclusively from config. On the legacy
      // explicit-paths path there is no active spec, so synthesize one from the
      // resolved file paths (FileSource) purely to satisfy the signature.
      final specForBackend =
          activeSpec ??
          EmbeddingModelSpec(
            name: 'legacy:${path.basename(modelPath)}',
            modelSource: ModelSource.file(modelPath),
            tokenizerSource: ModelSource.file(tokenizerPath),
          );
      final model = await backend.createModel(specForBackend, embConfig);

      // Core owns the singleton lifecycle: the cache tracks the model, resets
      // on close (identity-guarded) and records what it was built from.
      await _embedderCache.adopt(model, requestedParams);
      return model;
    } catch (_) {
      _embedderCache.invalidate();
      rethrow;
    }
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
            'Use `FlutterGemma.installStt()` first.',
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

      gemmaLog('[FlutterGemmaDesktop] Loading STT model: $modelPath');

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
          'No STT backend registered. Add flutter_gemma_speech to '
          'pubspec.yaml and pass it in sttBackends: of '
          'FlutterGemma.initialize(...). Registered backends: '
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
        'No active TTS model set. Use FlutterGemma.installTts() first.',
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
              : 'No TTS backend registered. Pass ttsBackends: to FlutterGemma.initialize().',
        );
      }
      gemmaLog(
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

  // === RAG Methods ===

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
    if (initializedEmbeddingModel == null) {
      throw StateError(
        'No embedding model is active. addDocument(content:) and '
        'searchSimilar(query:) auto-embed text, which requires an embedding '
        'model. Install and activate one with FlutterGemma.installEmbedder(...) '
        '(or modelManager.setActiveModel) before calling these methods — or '
        'pass a precomputed vector to addDocumentWithEmbedding(embedding:).',
      );
    }
    final embedding = await initializedEmbeddingModel!.generateEmbedding(
      content,
      taskType: TaskType.retrievalDocument,
    );
    await addDocumentWithEmbedding(
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
    if (initializedEmbeddingModel == null) {
      throw StateError(
        'No embedding model is active. addDocument(content:) and '
        'searchSimilar(query:) auto-embed text, which requires an embedding '
        'model. Install and activate one with FlutterGemma.installEmbedder(...) '
        '(or modelManager.setActiveModel) before calling these methods — or '
        'pass a precomputed vector to addDocumentWithEmbedding(embedding:).',
      );
    }
    final queryEmbedding = await initializedEmbeddingModel!.generateEmbedding(
      query,
    );
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

/// Check if current platform is desktop
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
