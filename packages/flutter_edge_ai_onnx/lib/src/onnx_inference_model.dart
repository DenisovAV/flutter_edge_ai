// ORT-GenAI `InferenceModel` — text-only v1 (hardened plan Phase 3, Task 2).
// Shape mirrors `FfiInferenceModel`
// (`flutter_edge_ai_litertlm/lib/src/ffi/ffi_inference_model.dart`)'s
// createSession singleton lane (issue #308 pattern) plus its open-session
// cap (`openEngineSession`, behind core's `openSession`); the base
// `InferenceModel.createChat` and core's `openChat`, which route through
// `createSession`/`openSession`, are inherited unchanged.
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_edge_ai/engine.dart';

import 'ffi/gen_ai_client.dart';
import 'onnx_sampling.dart';
import 'onnx_session.dart';

/// An ORT-GenAI text model: one [GenAiClient] (and its worker isolate), the
/// legacy [createSession] session and any number of [openSession] sessions —
/// each with a generator of its own, turns served one at a time.
///
/// **Cost of an open session.** Every session that has had a turn holds one
/// ORT-GenAI generator whose KV cache is allocated in full at its first turn:
/// `max_length` (the model's [maxTokens]) × the cache size per token
/// (2 × layers × KV heads × head size × dtype size; 0.75 MiB for Phi-3.5-mini
/// int4, which the figures here are for) — 771 MiB at 1024
/// and 3077 MiB at 4096 for Phi-3.5-mini int4 on Linux CPU — resident from
/// then on; closing the session frees it. Windows gives it back to the OS;
/// on Linux the RSS did not fall at 512 to 2048. That is why
/// [maxConcurrentSessions] defaults to 2 on Android and iOS and to unlimited on
/// desktop.
///
/// It closes itself when its worker dies — an uncaught error, or the isolate
/// ended under it: it turns closed, runs [onClose] and fires its close
/// listeners, once, so core drops its cached model, and later calls fail with
/// the reason. [close] afterwards still releases the client and fires nothing
/// again.
class OnnxInferenceModel extends InferenceModel with CloseNotifier {
  OnnxInferenceModel({
    required this.client,
    required this.maxTokens,
    required this.modelType,
    required this.activeBackend,
    this.fileType = ModelFileType.onnx,
    this.configTopK,
    this.maxConcurrentSessions,
    required this.onClose,
  }) {
    // A worker that dies on its own turns this model closed and tells its
    // listeners, so core drops its cached model and the next `getActiveModel`
    // builds a fresh one — instead of handing out this one, whose every call
    // would fail.
    final died = unexpectedExitOf(client);
    if (died != null) unawaited(died.then(_onWorkerDied));
  }

  final GenAiClient client;
  final ModelType modelType;

  /// `search.top_k` from the model's `genai_config.json`, when it sets one.
  final int? configTopK;

  @override
  final ModelFileType fileType;

  @override
  final int maxTokens;

  @override
  final PreferredBackend? activeBackend;

  /// Cap on concurrent [openSession] sessions; null = unlimited. The legacy
  /// [createSession] session does not count.
  final int? maxConcurrentSessions;

  /// Legacy hook fired alongside [CloseNotifier.fireCloseListeners] — the
  /// engine passes a no-op; core registers its singleton-reset via
  /// [addCloseListener] instead (same split as `FfiInferenceModel`).
  final VoidCallback onClose;

  OnnxSession? _session;
  final Set<OnnxSession> _openSessions = {};
  int _nextSessionId = 1;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  /// What every [close] after the first returns: completes, normally, once
  /// the one shared teardown is done — so a second caller waits for it
  /// instead of returning while it is still running.
  Future<void>? _closeFuture;

  /// Whether [onClose] and the close listeners have run; they run once,
  /// whether the model was closed or its worker died.
  bool _closeNotified = false;

  /// Why the worker died, when it did; later calls quote it.
  String? _deathReason;

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get engineSessions => [
    ?_session,
    ..._openSessions,
  ];

  StateError _closedError() {
    final death = _deathReason;
    return StateError(
      death == null
          ? 'Model is closed. Create a new instance to use it again'
          : 'Model is closed because $death. Create a new instance to use it '
                'again',
    );
  }

  /// Opens a session with a generator of its own, independent of [session]
  /// and of every other open session: its history is not replayed, and
  /// closing it gives back its KV cache. Turns of different sessions are
  /// served one at a time.
  ///
  /// Throws [StateError] when [maxConcurrentSessions] sessions are already
  /// open. See the class doc for what an open session costs.
  @override
  Future<InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    final SessionRequest(
      :temperature,
      :randomSeed,
      :topK,
      :topP,
      :loraPath,
      :enableVisionModality,
      :enableAudioModality,
      :systemInstruction,
      :maxOutputTokens,
    ) = request;
    if (_isClosed) throw _closedError();
    _rejectUnsupported(loraPath, enableVisionModality, enableAudioModality);
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one. Each open session holds a KV cache that is '
        'allocated at its first turn: per token 2 x layers x KV heads x head '
        'size x dtype size (0.75 MiB for Phi-3.5-mini int4), times '
        'max_length ($maxTokens). The createSession session is not counted '
        'and holds a generator too.',
      );
    }
    final sampling = withSamplingTopK(
      SamplingParams(
        temperature: temperature,
        topK: topK,
        topP: topP,
        randomSeed: randomSeed,
      )..validate(),
      modelType: modelType,
      configTopK: configTopK,
    );
    late final OnnxSession opened;
    opened = OnnxSession(
      client: client,
      modelType: modelType,
      fileType: fileType,
      systemInstruction: systemInstruction,
      maxOutputTokens: maxOutputTokens,
      sampling: sampling,
      sessionId: _nextSessionId++,
      onClose: () => _openSessions.remove(opened),
    );
    _openSessions.add(opened);
    return opened;
  }

  /// [openChat]'s unset model type is this model's own (D8); the rest are
  /// core's defaults: ONNX GenAI sessions are text-only.
  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) =>
      ResolvedChatRequest(
        modelType: request.modelType ?? modelType,
        supportImage: request.supportImage ?? false,
        supportAudio: request.supportAudio ?? false,
        supportsFunctionCalls: request.supportsFunctionCalls ?? false,
        tools: request.tools,
        maxFunctionBufferLength:
            request.maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
        temperature: request.temperature,
        randomSeed: request.randomSeed,
        topK: request.topK,
        topP: request.topP,
        tokenBuffer: request.tokenBuffer,
        loraPath: request.loraPath,
        enableThinking: request.enableThinking,
        toolChoice: request.toolChoice,
        systemInstruction: request.systemInstruction,
        maxOutputTokens: request.maxOutputTokens,
      );

  void _rejectUnsupported(
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
  ) {
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the ONNX GenAI path '
        '(loraPath=$loraPath). Use a MediaPipe .task model instead.',
      );
    }
    if (enableVisionModality == true || enableAudioModality == true) {
      throw UnsupportedError(
        'Vision/audio modalities are not supported on the ONNX GenAI '
        'session (v1, text-only). Use a MediaPipe .task or .litertlm model.',
      );
    }
  }

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    if (_isClosed) throw _closedError();
    _rejectUnsupported(loraPath, enableVisionModality, enableAudioModality);

    // Single-flight guard for concurrent callers; sequential calls fall
    // through and close the previous session before opening a fresh one —
    // same rationale as `FfiInferenceModel.createSession` (issue #308).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();

    try {
      // Checked first: values it rejects must not cost the live session.
      final sampling = withSamplingTopK(
        SamplingParams(
          temperature: temperature,
          topK: topK,
          topP: topP,
          randomSeed: randomSeed,
        )..validate(),
        modelType: modelType,
        configTopK: configTopK,
      );

      // Legacy singleton lane: close the previous session (and, via its
      // close(), reset the client's live generator) BEFORE opening a fresh
      // one, so a new session never inherits stale KV-cache history.
      await _session?.close();

      if (_isClosed) {
        final death = _deathReason;
        throw StateError(
          death == null
              ? 'Model was closed while creating a session'
              : 'Model was closed while creating a session, because $death',
        );
      }

      late final OnnxSession newSession;
      newSession = OnnxSession(
        client: client,
        modelType: modelType,
        fileType: fileType,
        systemInstruction: systemInstruction,
        maxOutputTokens: maxOutputTokens,
        sampling: sampling,
        // Identity-guarded so a late close of a superseded session can't
        // null a newer `_session` (mirrors `FfiInferenceModel`).
        onClose: () {
          if (identical(_session, newSession)) _session = null;
        },
      );
      _session = newSession;
      completer.complete(newSession);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _createCompleter = null;
    }
    return completer.future;
  }

  /// Closes the session, then shuts the client down. Also after the worker
  /// died: the client's ports still need closing, and the close listeners —
  /// which the death already fired — do not fire again. Concurrent callers
  /// share one teardown.
  @override
  Future<void> close() {
    final teardownDone = _closeFuture;
    if (teardownDone != null) return teardownDone;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // `whenComplete` hands the first caller the teardown's own outcome — a
    // throwing `onClose` or listener included — while every later caller
    // gets `settled`, which only ever completes normally once it is done.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    // Every step runs even when an earlier one threw: a throwing shutdown — a
    // custom GenAiClient's — must still reach the listeners core evicts on.
    // The first failure goes to the caller; a later one is printed, because
    // a `finally` that throws would replace the first and lose it.
    Object? firstError;
    StackTrace? firstStack;
    void fail(String step, Object error, StackTrace stack) {
      if (firstError == null) {
        firstError = error;
        firstStack = stack;
        return;
      }
      // `print`, not edgeAiLog, which is silent in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: $step also failed while the ONNX '
        'model was closing: $error\n$stack',
      );
    }

    try {
      // Stops the legacy (`createSession`) session's turn; opened sessions
      // stop their own in OnnxSession.close(), below. Idempotent/cheap on the
      // client and worker either way.
      await client.stopGeneration();
      await _session?.close();
      // Together, and copied because close() removes a session from the set:
      // each close waits for its reset while the worker may be busy, and one
      // after the other that would add up.
      await Future.wait([for (final s in _openSessions.toList()) s.close()]);
    } catch (e, st) {
      fail('closing the session', e, st);
    }
    try {
      await client.shutdown();
    } catch (e, st) {
      fail('shutting the client down', e, st);
    }
    try {
      _notifyClosed();
    } catch (e, st) {
      fail('a close listener', e, st);
    }
    final error = firstError;
    if (error != null) Error.throwWithStackTrace(error, firstStack!);
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    try {
      onClose();
    } finally {
      // Even when `onClose` throws: core drops its cached instance on a close
      // listener, and one it never hears about is handed to every later
      // caller.
      fireCloseListeners();
    }
  }

  void _onWorkerDied(String reason) {
    _deathReason = reason;
    _isClosed = true;
    // The sessions are unusable now; closing them takes them out of
    // `sessions` and runs their own cleanup (the dead client ignores it).
    for (final s in _openSessions.toList()) {
      // A close that fails on a dead worker has nobody to tell.
      unawaited(s.close().then<void>((_) {}, onError: (Object _) {}));
    }
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context; `print`, because edgeAiLog is silent
      // in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: a close listener threw while an ONNX '
        'model whose worker had died was being closed: $e\n$st',
      );
    }
  }
}
