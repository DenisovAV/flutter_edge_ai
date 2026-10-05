// Isolate message protocol for the ORT-GenAI worker (`gen_ai_client.dart`).
// Every class here must be plain-data (no closures, no FFI pointers) to
// survive `SendPort.send`.
//
// Deliberately its own file, src-only (NOT barrel-exported from
// `flutter_gemma_onnx.dart`) — hardened plan Task 2a. Pulling the protocol
// out from under `gen_ai_client.dart`'s leading underscores lets
// `test/gen_ai_client_lifecycle_test.dart` spawn a scripted FAKE worker (a
// real isolate, real ports, zero FFI/dlopen) that speaks the exact same
// message shapes the real `_workerEntry` does — exercising the REAL
// `GenAiFfiClient` dispatch/mutex/`_closed`-recheck machinery, which a
// `FakeGenAiClient`-based session test cannot reach. That fake-worker
// coverage is client-side only: it cannot prove the real worker's native
// handle teardown is use-after-free-safe (see
// `onnx_generation_host_smoke_test.dart` for that).
import 'dart:isolate';

import 'package:flutter_gemma/core/utils/gemma_log.dart' show GemmaLogLevel;

import 'gen_ai_client.dart' show GenAiTurn;

/// Initial message sent to the worker isolate at spawn time.
class WorkerInit {
  WorkerInit({
    required this.replyTo,
    required this.modelDir,
    required this.contextWindow,
    required this.libsDir,
    required this.logLevel,
  });

  final SendPort replyTo;
  final String modelDir;
  final int contextWindow;
  final String? libsDir;
  final GemmaLogLevel logLevel;
}

/// Worker → main: load succeeded, here is the command port.
class Ready {
  Ready(this.commandPort);
  final SendPort commandPort;
}

/// Main → worker: start streaming a turn.
class GenerateRequest {
  GenerateRequest(this.id, this.turn);
  final int id;
  final GenAiTurn turn;
}

/// Worker → main: one decoded text piece for [id].
class Chunk {
  Chunk(this.id, this.text);
  final int id;
  final String text;
}

/// Worker → main: [id]'s stream finished (normally or via [StopSignal]).
class GenerateDone {
  GenerateDone(
    this.id,
    this.stopped,
    this.promptTokens,
    this.generatedTokens,
    this.decodeMs,
  );
  final int id;
  final bool stopped;
  final int promptTokens;
  final int generatedTokens;
  final int decodeMs;
}

/// Worker → main: [id]'s generation failed.
class GenerateError {
  GenerateError(this.id, this.error);
  final int id;
  final String error;
}

/// Main → worker: stop the in-flight generation, if any. NOT gated by the
/// client's `_mutex` — it must be able to interrupt a call holding it.
class StopSignal {
  const StopSignal();
}

/// Main → worker: destroy the live generator so the next turn starts fresh.
class ResetSessionRequest {
  const ResetSessionRequest();
}

/// Worker → main: [ResetSessionRequest] handled.
class ResetSessionAck {
  const ResetSessionAck();
}

/// Main → worker: tokenize [text] (no chat template) and report its length.
class CountTokensRequest {
  CountTokensRequest(this.id, this.text);
  final int id;
  final String text;
}

/// Worker → main: reply to a [CountTokensRequest].
class CountTokensReply {
  CountTokensReply(this.id, this.count, this.error);
  final int id;
  final int? count;
  final String? error;
}

/// Main → worker: tear everything down and exit the command loop.
class Close {
  const Close();
}

/// Worker → main: final message before the isolate exits — every native
/// handle has been freed.
class CloseAck {
  const CloseAck();
}

/// Signature every worker entry point (real or a test fake) must match —
/// the injection seam `GenAiFfiClient({workerEntry})` spawns.
typedef GenAiWorkerEntry = Future<void> Function(WorkerInit init);
