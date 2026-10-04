import 'dart:async';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // MethodChannel — used by file_system_manager.dart part
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:background_downloader/background_downloader.dart';

import 'smart_downloader.dart'; // SmartDownloader.downloadGroup — single source of truth for the task group

import '../flutter_edge_ai.dart';
import '../core/di/service_registry.dart';
import '../core/services/model_repository.dart' as repo;
import '../core/model_management/constants/preferences_keys.dart';
import '../core/model_management/active_embedding_identity.dart';
import '../core/model_management/utils/download_temp_reclaim.dart';
import '../core/utils/file_name_utils.dart';
import '../core/registry/engine_registry.dart';
import '../core/registry/embedding_registry.dart';
import '../core/registry/embedding_backend_provider.dart';
import '../core/registry/stt_registry.dart';
import '../core/registry/stt_backend_provider.dart';
import '../core/registry/tts_registry.dart';
import '../core/registry/runtime_config.dart';
import '../core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_cache.dart';
// Re-export the spec value types so existing importers of this library (tests,
// example, and any external code that imported the mobile lib directly) keep
// seeing InferenceModelSpec/EmbeddingModelSpec/etc. — they used to be `part`s
// here, now they live in model_specs.dart. Safe for wasm: this library is only
// on the io graph (web uses the conditional default stub).
export '../core/model_management/model_specs.dart';

// New unified model management system. The spec/exception value types live in
// the dart:io-free `model_specs.dart` library (extracted for dart2wasm/web
// compat); the implementation parts below stay here (they use dart:io).
part '../core/model_management/utils/file_system_manager.dart';
part '../core/model_management/utils/resume_checker.dart';
part '../core/model_management/managers/mobile_model_manager.dart';

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
  Completer<InferenceModel>? _initCompleter;
  InferenceModel? _initializedModel;

  InferenceModelSpec?
  _lastActiveInferenceSpec; // Track which spec was used to create _initializedModel

  /// Runtime knobs the cached model was built with. Compared on every
  /// getActiveModel so a request that differs rebuilds instead of silently
  /// handing back a model configured for something else.
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
    bool supportAudio = false, // Enabling audio support (Gemma 3n E4B)
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  }) async {
    // Check if model is ready through unified system
    final manager = _unifiedManager;
    final activeModel = manager.activeInferenceModel;

    // No active inference model - user must set one first
    if (activeModel == null) {
      throw StateError(
        'No active inference model set. Use `FlutterEdgeAi.installModel()` or `modelManager.setActiveModel()` to set a model first',
      );
    }

    // Hoisted out of the reuse check below: the in-flight race also
    // needs it, and that runs when the reuse check does not.
    final requestedSpec = activeModel as InferenceModelSpec;

    // Captured once: compared against the cached model below, and recorded
    // as the new baseline after a successful build.
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

    // Check if singleton exists and matches the active model
    if (_initCompleter != null &&
        _initializedModel != null &&
        _lastActiveInferenceSpec != null) {
      final currentSpec = _lastActiveInferenceSpec!;

      // The name alone used to decide this, so every runtime knob was
      // ignored: getActiveModel(preferredBackend: cpu) after a GPU creation
      // returned the GPU model without a word. Compare the knobs too, and name
      // the one that forced the rebuild.
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

      if (currentSpec.name != requestedSpec.name || changedParam != null) {
        edgeAiLog(
          currentSpec.name != requestedSpec.name
              ? '⚠️  Active model changed: ${currentSpec.name} → ${requestedSpec.name}'
              : '⚠️  Runtime config changed ($changedParam) for '
                    '${requestedSpec.name} — rebuilding the model',
        );
        edgeAiLog('🔄 Closing old model and creating new one...');
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
          edgeAiLog('Old model close() failed, continuing with rebuild: $e');
        }
      } else {
        // Same model - return existing singleton
        edgeAiLog(
          'ℹ️  Reusing existing model instance for ${requestedSpec.name}',
        );
        return _initCompleter!.future;
      }
    }

    // If singleton doesn't exist or was just closed, create new one
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
      edgeAiLog(
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
        edgeAiLog('In-flight build failed; building fresh for this request');
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

    final isBuiltIn = requestedSpec.fileType == ModelFileType.builtIn;
    String modelPath = '';

    try {
      // The pre-build checks live INSIDE this try, and they THROW rather than
      // completing the completer themselves. Desktop was always shaped this
      // way; mobile had them outside, with a closure that duplicated the catch
      // below, and that split cost two defects:
      //
      //   * the checks used to complete the error and return while leaving
      //     `_initCompleter` installed — the defect FIX #170 removed from the
      //     catch, in the paths it did not cover — so every later caller was
      //     handed a dead completer, and a DIFFERENT request awaited it,
      //     caught it, re-entered, and looped without end;
      //   * a THROW from isModelInstalled / getModelFilePaths / exists()
      //     escaped createModel entirely, leaving a completer that could never
      //     settle.
      //
      // One try and one catch cannot drift apart the way two did. Throwing also
      // keeps the stack trace, which the closure discarded.
      if (!isBuiltIn) {
        final isModelInstalled = await manager.isModelInstalled(activeModel);
        if (!isModelInstalled) {
          throw Exception(
            'Active model is no longer installed. Use the `modelManager` to load the model first',
          );
        }

        final modelFilePaths = await manager.getModelFilePaths(activeModel);
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
          'Built-in model ${requestedSpec.name}: skipping file/installed checks (no on-disk file)',
        );
      }

      // Engine selection routes ENTIRELY through [EngineRegistry] (probe-chain).
      // Core registers NO default engine: both MediaPipe (.task/.bin, from
      // flutter_edge_ai_mediapipe) and LiteRT-LM (.litertlm, from
      // flutter_edge_ai_litertlm) are fully opt-in via
      // FlutterEdgeAi.initialize(inferenceEngines: [...]). Core only resolves the
      // model path (preamble above) + owns the singleton lifecycle centrally
      // (track + reset on close); the selected engine builds the model.

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
      if (activationDataType != null &&
          spec.fileType != ModelFileType.litertlm) {
        edgeAiLog(
          '[FlutterEdgeAi] activationDataType (${activationDataType.name}) is '
          'read only by the .litertlm engine; ${engine.name} ignores it for '
          'ModelFileType.${spec.fileType.name}.',
        );
      }
      final model = await engine.createModel(spec, config);

      // Core owns the singleton lifecycle: track it + reset on close. The
      // package-built model fires this via CloseNotifier (addCloseListener).
      _initializedModel = model;
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
        // Cleared with the rest, not left behind: these four describe ONE
        // cached model, and a subset that survives it is a baseline for a
        // model that no longer exists.
        _lastInferenceParams = null;
      });

      _lastActiveInferenceSpec = spec;
      _lastInferenceParams = requestedParams;
      // Nothing is in flight any more. Leaving this set would be a field
      // outliving its meaning — the reuse check above happens to shadow it
      // today, which is not a reason to keep a stale one around.
      _inFlightRequest = null;
      completer.complete(model);
      return model;
    } catch (e, st) {
      // FIX #170: Reset state to allow retry with different model
      _initCompleter = null;
      _inFlightRequest = null;
      _initializedModel = null;
      _lastActiveInferenceSpec = null;
      _lastInferenceParams = null;
      completer.completeError(e, st);
      // Return the error-completed completer future (not a separate throw) so
      // exactly one Future is in flight — a bare throw would orphan
      // completer.future (no listener in the single-caller path) → spurious
      // unhandled-async. Mirrors createTtsModel. See #394.
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

    // Serialised, because resolving paths, comparing them against the cached
    // embedder and building are three steps with awaits between them: run
    // interleaved, two callers both finish deciding before either records a
    // model, and one of the two builds is orphaned with nobody to close it.
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
    String label = 'explicit paths';

    // Modern API: Use active embedding model if paths not provided
    if (modelPath == null || tokenizerPath == null) {
      final manager = _unifiedManager;
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
      label = (activeModel as EmbeddingModelSpec).name;

      edgeAiLog(
        'Using active embedding model: $modelPath, tokenizer: $tokenizerPath',
      );
    }

    // Both entry shapes get the SAME comparison, on the RESOLVED PATHS rather
    // than a spec name: reinstalling a same-named embedder to a new path used
    // to be invisible, and returning the cached singleton unconditionally on
    // the explicit-paths side handed a caller who asked for a different model
    // file the previous model's vectors, silently.
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

    // Verify the active model is still installed (for Modern API path)
    final manager = _unifiedManager;
    final activeModel = manager.activeEmbeddingModel;

    if (activeModel != null) {
      final isModelInstalled = await manager.isModelInstalled(activeModel);
      if (!isModelInstalled) {
        throw Exception(
          'Active embedding model is no longer installed. Use the `modelManager` to load the model first',
        );
      }
    }

    try {
      // The LiteRT embedding runtime lives in flutter_edge_ai_litertlm; core
      // resolves paths (preamble above) + owns the singleton lifecycle, then
      // dispatches construction through the EmbeddingRegistry. The backend
      // reads ONLY config.modelPath/config.tokenizerPath — it ignores the spec
      // arg for path resolution (see LiteRtEmbeddingBackend.createModel).
      final activeSpec =
          activeModel as EmbeddingModelSpec?; // null on legacy explicit-paths
      final EmbeddingBackendProvider? backend = activeSpec != null
          ? EmbeddingRegistry.instance.findFor(activeSpec)
          : (EmbeddingRegistry.instance.registered.isNotEmpty
                ? EmbeddingRegistry.instance.registered.first
                : null);
      if (backend == null) {
        throw StateError(
          'No embedding backend registered. Add flutter_edge_ai_litertlm to '
          'pubspec.yaml and pass LiteRtEmbeddingBackend() in '
          'embeddingBackends: of FlutterEdgeAi.initialize(...). Registered '
          'backends: '
          '${EmbeddingRegistry.instance.registered.map((b) => b.name).join(", ")}.',
        );
      }
      // modelPath/tokenizerPath are non-null here (resolved in the preamble or
      // passed by the legacy API). maxTokens is unused by embeddings.
      final embConfig = RuntimeConfig(
        maxTokens: 0,
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: preferredBackend,
      );
      // The backend's createModel(spec, config) signature requires a non-null
      // spec, but it resolves paths exclusively from config. On the legacy
      // explicit-paths path there is no active spec, so synthesize one from the
      // resolved file paths (FileSource, mobile/desktop only — web swaps in its
      // own plugin) purely to satisfy the signature.
      final specForBackend =
          activeSpec ??
          EmbeddingModelSpec(
            name: 'legacy:${path.basename(modelPath)}',
            modelSource: ModelSource.file(modelPath),
            tokenizerSource: ModelSource.file(tokenizerPath),
          );
      final model = await backend.createModel(specForBackend, embConfig);

      // Core owns the singleton lifecycle: the cache tracks the model, resets
      // on close (identity-guarded) and records what it was built from, so the
      // next caller has something to compare against.
      await _embedderCache.adopt(model, requestedParams);
      return model;
    } catch (_) {
      // FIX #170: leave no bookkeeping behind, so a retry with a different
      // model is a fresh decision rather than a replay of this failure.
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
    // Modern API: Use active STT model if paths not provided
    if (modelPath == null || tokenizerPath == null) {
      final manager = _unifiedManager;
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
