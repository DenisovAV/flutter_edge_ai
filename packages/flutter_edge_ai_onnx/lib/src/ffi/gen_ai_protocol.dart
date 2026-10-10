// Isolate message protocol for the ORT-GenAI worker (`gen_ai_client.dart`).
// Every class here must be plain-data (no closures, no FFI pointers) to
// survive `SendPort.send`.
//
// Deliberately its own file, src-only (NOT barrel-exported from
// `flutter_edge_ai_onnx.dart`) — hardened plan Task 2a. Pulling the protocol
// out from under `gen_ai_client.dart`'s leading underscores lets
// `test/gen_ai_client_lifecycle_test.dart` spawn a FAKE worker (a real
// isolate, real ports, zero FFI/dlopen) that runs the real worker loop
// (`serveGenAiWorker`, `gen_ai_worker.dart`) over a scripted engine —
// exercising the REAL `GenAiFfiClient` dispatch/mutex/`_closed`-recheck
// machinery and the real queue/close rules, which a `FakeGenAiClient`-based
// session test cannot reach. It still cannot prove the FFI engine's native
// handle teardown is use-after-free-safe (see
// `onnx_generation_host_smoke_test.dart` for that).
import 'dart:isolate';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart'
    show EdgeAiLogLevel;

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
  final EdgeAiLogLevel logLevel;
}

/// Worker → main: load succeeded, here is the command port.
class Ready {
  Ready(this.commandPort);
  final SendPort commandPort;
}

/// A main → worker request the worker queues and serves one at a time, in
/// arrival order (`gen_ai_worker.dart`). Sealed so serving it, and failing it
/// when a [Close] arrives before it started, are exhaustive switches.
sealed class QueuedRequest {
  const QueuedRequest();
}

/// Main → worker: start streaming a turn.
class GenerateRequest extends QueuedRequest {
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
class ResetSessionRequest extends QueuedRequest {
  const ResetSessionRequest();
}

/// Worker → main: [ResetSessionRequest] handled.
class ResetSessionAck {
  const ResetSessionAck();
}

/// Main → worker: tokenize [text] (no chat template) and report its length.
class CountTokensRequest extends QueuedRequest {
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

/// Main → worker: fail every queued request that has not started, let the
/// one in flight finish (a generation stops at its next token), free every
/// native handle, then leave with [CloseAck].
class Close {
  const Close();
}

/// Worker → main: the last message, sent through `Isolate.exit` once every
/// native handle has been freed — nothing of the worker runs after it.
/// [error] is set when freeing them threw: the native model may then still be
/// resident, and the main isolate says so.
class CloseAck {
  const CloseAck([this.error]);
  final String? error;
}

/// Signature every worker entry point (real or a test fake) must match —
/// the injection seam `GenAiFfiClient({workerEntry})` spawns. Both the real
/// entry and the test fake hand their engine to `serveGenAiWorker`
/// (`gen_ai_worker.dart`), so a fake exercises the real worker loop.
typedef GenAiWorkerEntry = Future<void> Function(WorkerInit init);
