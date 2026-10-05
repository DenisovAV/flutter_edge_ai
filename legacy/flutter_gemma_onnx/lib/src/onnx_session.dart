// ORT-GenAI `InferenceModelSession` — text-only v1 (hardened plan Phase 3,
// Task 2). Shape mirrors `FfiInferenceModelSession`
// (`flutter_gemma_litertlm/lib/src/ffi/ffi_inference_model.dart`) but drives
// [GenAiClient] instead of the LiteRT-LM conversation handle.
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_gemma/core/extensions.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart';

import 'ffi/gen_ai_client.dart';

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
    required this.client,
    required this.modelType,
    required this.fileType,
    this.systemInstruction,
    this.maxOutputTokens,
    required this.onClose,
  });

  final GenAiClient client;
  final ModelType modelType;
  final ModelFileType fileType;
  final String? systemInstruction;
  final int? maxOutputTokens;
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
  Future<String> getResponse() async {
    _assertNotClosed();
    final turn = _drainTurn();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;
    final buffer = StringBuffer();
    var completedNormally = false;
    try {
      await for (final chunk in client.generate(turn)) {
        firstChunkMs ??= genSw.elapsedMilliseconds;
        chunkCount++;
        buffer.write(chunk);
      }
      completedNormally = true;
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
    } finally {
      // A turn that did not complete normally — a mid-stream native error,
      // or the consumer cancelling the subscription (barge-in) — leaves the
      // generator's KV cache holding the same kind of dangling, incomplete
      // assistant turn an explicit stopGeneration() does. Force the next
      // turn to start a fresh generator either way, not only on an explicit
      // stop (see `_forceResetOnNextTurn`'s doc).
      if (!completedNormally) _forceResetOnNextTurn = true;
      _noteGenerationFinished();
    }
    return buffer.toString();
  }

  @override
  Stream<String> getResponseAsync() async* {
    _assertNotClosed();
    final turn = _drainTurn();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;
    var completedNormally = false;
    try {
      await for (final chunk in client.generate(turn)) {
        firstChunkMs ??= genSw.elapsedMilliseconds;
        chunkCount++;
        yield chunk;
      }
      completedNormally = true;
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
    } finally {
      // Same reset-on-abnormal-termination rule as getResponse() above —
      // this also covers the consumer breaking out of `await for`
      // (subscription cancellation), which Dart unwinds through this
      // finally block without completing the try normally.
      if (!completedNormally) _forceResetOnNextTurn = true;
      _noteGenerationFinished();
    }
  }

  void _logGenerationStats(Stopwatch sw, int? firstChunkMs, int chunks) {
    final total = sw.elapsedMilliseconds;
    if (firstChunkMs == null || chunks == 0) {
      gemmaLog(
        '[OnnxSession/perf] generation total: ${total}ms (no chunks emitted)',
      );
      return;
    }
    final decodeMs = total - firstChunkMs;
    gemmaLog(
      '[OnnxSession/perf] generation total: ${total}ms '
      '(prefill ${firstChunkMs}ms + decode ${decodeMs}ms over $chunks chunks)',
    );
  }

  @override
  Future<int> sizeInTokens(String text) => client.countTokens(text);

  @override
  Future<void> stopGeneration() {
    _stoppedThisTurn = true;
    return client.stopGeneration();
  }

  @override
  SessionMetrics getSessionMetrics() {
    final stats = client.lastGenerationStats;
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
    // creating a new one" ordering). The worker itself also forces a stop
    // and drains the active generation before freeing native handles
    // (defense-in-depth, see gen_ai_client.dart's `activeGeneration`), but
    // sending the stop first here keeps this session from sitting on an
    // abandoned decode any longer than necessary.
    await client.stopGeneration();
    await client.resetSession();
    onClose();
  }
}
