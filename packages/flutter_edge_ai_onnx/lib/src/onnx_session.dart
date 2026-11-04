// ORT-GenAI `InferenceModelSession` — text-only v1 (hardened plan Phase 3,
// Task 2). Shape mirrors `FfiInferenceModelSession`
// (`flutter_edge_ai_litertlm/lib/src/ffi/ffi_inference_model.dart`) but drives
// [GenAiClient] instead of the LiteRT-LM conversation handle.
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_edge_ai/engine.dart';

import 'ffi/gen_ai_client.dart';
import 'onnx_sampling.dart';

/// `InferenceModelSession` over ORT-GenAI. Buffers query chunks (raw text —
/// Task 3 routes onnx through the SDK-owns-templates path, so no manual turn
/// markers land in the buffer) until [getResponse]/[getResponseAsync] drains
/// them into one [GenAiTurn].
///
/// Text-only v1: [addQueryChunk] rejects image/audio input loudly rather
/// than silently dropping it — multimodal ORT-GenAI models are a later
/// slice (device-gated, see the hardened plan's D2 tail).
class OnnxSession extends InferenceModelSession {
  OnnxSession({
    required GenAiClient client,
    required ModelType modelType,
    required ModelFileType fileType,
    String? systemInstruction,
    int? maxOutputTokens,
    SamplingParams sampling = const SamplingParams(),
    int? sessionId,
    required VoidCallback onClose,
  }) : this._(
         null,
         client: client,
         modelType: modelType,
         fileType: fileType,
         systemInstruction: systemInstruction,
         maxOutputTokens: maxOutputTokens,
         sampling: sampling,
         sessionId: sessionId,
         onClose: onClose,
       );

  OnnxSession._(
    this._guidance, {
    required this.client,
    required this.modelType,
    required this.fileType,
    this.systemInstruction,
    this.maxOutputTokens,
    this.sampling = const SamplingParams(),
    this.sessionId,
    required this.onClose,
  });

  /// The JSON schema ORT-GenAI's guidance enforces on every reply of this
  /// session, set on its generator; null = unguided. Only
  /// [openGuidedOnnxSession] sets it.
  final String? _guidance;

  /// Which generator this session drives: null is the legacy singleton
  /// session (`createSession`), any other value an `openSession` session with
  /// a generator — and KV cache — of its own.
  final int? sessionId;

  final GenAiClient client;
  final ModelType modelType;
  final ModelFileType fileType;
  final String? systemInstruction;
  final int? maxOutputTokens;

  /// What the caller set; unset fields keep the model's `genai_config.json`.
  final SamplingParams sampling;
  final VoidCallback onClose;

  final StringBuffer _queryBuffer = StringBuffer();
  bool _isClosed = false;

  /// True until the first [getResponse]/[getResponseAsync] call completes —
  /// tells the worker to (re)create the generator and, if set, send
  /// [systemInstruction] as the `system` role. Later turns rely on the
  /// persistent generator's KV cache, same posture as every other
  /// raw-mode (SDK-owns-history) engine.
  bool _isFirstTurn = true;

  /// True while a turn currently streaming has had [stopGeneration] called
  /// on it.
  bool _stoppedThisTurn = false;

  /// Set after a turn that was cut short by [stopGeneration] — forces the
  /// NEXT turn to start a fresh generator (fresh KV cache) instead of
  /// continuing the live one.
  ///
  /// A stopped generation leaves the generator's KV cache holding a
  /// DANGLING, incomplete assistant turn — no closing template tag, no
  /// natural stop token. Continuing generation on top of it (as a normal
  /// next turn would) lets the model resume finishing that abandoned
  /// sentence instead of answering the new prompt (verified on the macOS
  /// host smoke: turn 3 bled turn 2's cut-off "rock cycle" answer after a
  /// mid-stream stop). Forcing a reset trades away KV-cache reuse across
  /// that one boundary for correctness — the ORT-GenAI analogue of core's
  /// F2 dangling-tool-call fix (`generateChatResponseWithTools` balancing a
  /// mid-stream error on a reused chat).
  bool _forceResetOnNextTurn = false;

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError('Session is closed');
    }
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    if (message.hasImage || message.hasAudio) {
      throw UnsupportedError(
        'Image/audio input is not supported on the ONNX GenAI session (v1, '
        'text-only). Use a MediaPipe .task or .litertlm model for '
        'multimodal input.',
      );
    }
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    _queryBuffer.write(prompt);
  }

  GenAiTurn _drainTurn() {
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final startFresh = _isFirstTurn || _forceResetOnNextTurn;
    final turn = GenAiTurn(
      userContent: text,
      // Send the system instruction whenever a FRESH generator is created —
      // not only on the very first turn. `startFresh` also covers the
      // post-stop/post-cancel/post-error reset turn: that turn rebuilds the
      // generator with an empty KV cache, so a `_isFirstTurn`-only gate
      // silently drops the system prompt for the rest of the conversation
      // the first time the turn is interrupted (see `_forceResetOnNextTurn`).
      systemInstruction: startFresh ? systemInstruction : null,
      isFirstTurn: startFresh,
      maxOutputTokens: maxOutputTokens,
      searchOptions: onnxSearchOptions(sampling),
      sessionId: sessionId,
    );
    _isFirstTurn = false;
    _forceResetOnNextTurn = false;
    _stoppedThisTurn = false;
    return turn;
  }

  /// Records whether [stopGeneration] was called during the turn that just
  /// finished streaming — see [_forceResetOnNextTurn]'s doc.
  void _noteGenerationFinished() {
    if (_stoppedThisTurn) _forceResetOnNextTurn = true;
  }

  @override
  Future<String> getResponse() async => getResponseAsync().join();

  // Lazy, as before: the query is drained, and a closed session fails, when
  // the stream is listened to.
  @override
  Stream<String> getResponseAsync() async* {
    yield* startTurn().text;
  }

  /// One turn, with how it ended when the client can say (a
  /// [GenAiFfiClient]; any other client gives `end: null`). A turn of a
  /// session closed while it ran ends [TurnEnd.closed]; one that
  /// [stopGeneration] or a cancelled subscription stopped,
  /// [TurnEnd.stopped]; otherwise the worker's end-of-sequence, output or
  /// context limit. A failed turn's error is on the text, and its end is
  /// [TurnEnd.closed], as core's own structured session reports a turn that
  /// failed to start (never read after an error).
  ///
  /// What a turn leaves behind is settled by the worker of a
  /// [GenAiFfiClient] before it serves anything else (`afterTurn`): an end
  /// of sequence is kept, and so is an unguided turn at `maxOutputTokens`;
  /// a stopped turn keeps its exchange — the prompt and the reply as far as
  /// the user saw it, closed with the model's end-of-turn token, as core's
  /// chat keeps the partial reply in its history; any other end — a full
  /// context window, a prompt that did not fit, a failure, a guided turn at
  /// its cap — is rewound, so the session keeps its earlier turns without
  /// this one. A guided session's grammar starts again either way. With any
  /// other client the session itself starts the next turn fresh after a stop
  /// or a failure.
  ///
  /// A prompt that does not fit is refused: the text ends with a
  /// [StateError] and the turn ends [TurnEnd.contextLimit], on a plain and a
  /// guided session alike, and nothing of the turn is kept — the prompt never
  /// reaches the generator (design 2.6.0 §3: an error with `contextLimit` is
  /// a refused input, whose messages core's chat takes back).
  ///
  /// The turn is sent when this is called, as core's chat and structured
  /// session expect; listen to [EngineTurn.text] right away. A text never
  /// listened to cannot stop the turn, which then decodes to its end.
  @override
  EngineTurn startTurn() {
    _assertNotClosed();
    final turn = _drainTurn();
    final started = startGenAiTurn(client, turn, guidance: _guidance);
    final workerEnd = started.end;
    return EngineTurn(
      text: _streamTurn(started.text, workerEnd),
      end: workerEnd?.then((end) => _isClosed ? TurnEnd.closed : end),
    );
  }

  Stream<String> _streamTurn(Stream<String> text, Future<TurnEnd>? end) async* {
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;
    var completedNormally = false;
    try {
      await for (final chunk in text) {
        firstChunkMs ??= genSw.elapsedMilliseconds;
        chunkCount++;
        yield chunk;
      }
      completedNormally = true;
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
    } finally {
      // Only for a client whose worker does not settle its turns (end ==
      // null): a turn that did not complete normally — a mid-stream native
      // error, or the consumer cancelling the subscription (barge-in,
      // breaking out of `await for`, which Dart unwinds through this
      // finally block) — leaves the generator's KV cache holding the same
      // kind of dangling, incomplete assistant turn an explicit
      // stopGeneration() does. Force the next turn to start a fresh
      // generator either way (see `_forceResetOnNextTurn`'s doc).
      if (end == null) {
        if (!completedNormally) _forceResetOnNextTurn = true;
        _noteGenerationFinished();
      }
    }
  }

  void _logGenerationStats(Stopwatch sw, int? firstChunkMs, int chunks) {
    final total = sw.elapsedMilliseconds;
    if (firstChunkMs == null || chunks == 0) {
      edgeAiLog(
        '[OnnxSession/perf] generation total: ${total}ms (no chunks emitted)',
      );
      return;
    }
    final decodeMs = total - firstChunkMs;
    edgeAiLog(
      '[OnnxSession/perf] generation total: ${total}ms '
      '(prefill ${firstChunkMs}ms + decode ${decodeMs}ms over $chunks chunks)',
    );
  }

  // `async` so a client whose countTokens throws synchronously still fails
  // through the returned Future, as GenAiFfiClient.countTokens does.
  @override
  Future<int> sizeInTokens(String text) async => client.countTokens(text);

  @override
  Future<void> stopGeneration() {
    _stoppedThisTurn = true;
    return client.stopGeneration(sessionId: sessionId);
  }

  @override
  SessionMetrics getSessionMetrics() {
    final stats = client.generationStatsOf(sessionId);
    if (stats == null) return SessionMetrics();
    return SessionMetrics(
      inputTokens: stats.promptTokens,
      outputTokens: stats.generatedTokens,
      totalTokens: stats.promptTokens + stats.generatedTokens,
      tokensPerSecond: stats.tokensPerSecond,
    );
  }

  @override
  Future<void> close() async {
    // Idempotent — createSession() closes the previous singleton session
    // before creating a new one, and a caller may also close it directly.
    if (_isClosed) return;
    _isClosed = true;
    _queryBuffer.clear();
    // Stop any turn still streaming BEFORE asking the worker to tear down
    // the generator — resetSession()/close() on the client race an
    // in-flight generate() on the worker side (the ORT-GenAI analogue of
    // the litertlm FFI engine's "close previous conversation before
    // creating a new one" ordering). The worker itself also stops the turn
    // in flight when a reset or close arrives, and serves one request at a
    // time, so it never frees a handle a suspended generation still holds
    // (defense-in-depth, see `serveGenAiWorker` in gen_ai_worker.dart), but
    // sending the stop first here keeps this session from sitting on an
    // abandoned decode any longer than necessary.
    try {
      await client.stopGeneration(sessionId: sessionId);
      await client.resetSession(sessionId: sessionId);
    } finally {
      // Even when a custom client throws: the model must not keep a cap slot
      // for a session that is closed.
      onClose();
    }
  }
}

/// An [OnnxSession] whose every reply ORT-GenAI's guidance holds to
/// [jsonSchema]: set on the session's own generator, each time one is created.
/// Only for a [GenAiFfiClient] whose host has guidance (`guidanceRefusalOf`);
/// `OnnxInferenceModel.openEngineSession` checks that first. Not exported.
OnnxSession openGuidedOnnxSession({
  required GenAiClient client,
  required ModelType modelType,
  required ModelFileType fileType,
  String? systemInstruction,
  int? maxOutputTokens,
  SamplingParams sampling = const SamplingParams(),
  required int sessionId,
  required VoidCallback onClose,
  required String jsonSchema,
}) => OnnxSession._(
  jsonSchema,
  client: client,
  modelType: modelType,
  fileType: fileType,
  systemInstruction: systemInstruction,
  maxOutputTokens: maxOutputTokens,
  sampling: sampling,
  sessionId: sessionId,
  onClose: onClose,
);
