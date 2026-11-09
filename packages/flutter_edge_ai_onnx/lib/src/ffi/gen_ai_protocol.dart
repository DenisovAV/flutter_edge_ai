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

import 'package:flutter_edge_ai/engine.dart' show EdgeAiLogLevel, TurnEnd;

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
  GenerateRequest(this.id, this.turn, {this.guidance, this.seedHistory});
  final int id;
  final GenAiTurn turn;

  /// The JSON schema every reply of the turn's session must match, set on
  /// the generator's params when its generator is created
  /// (`OgaGeneratorParamsSetGuidance`, `json_schema`). Null = unguided. A
  /// session sends the same value on every turn, so a generator it creates
  /// again is guided again.
  final String? guidance;

  /// On a first turn, the conversation (`role`/`content` messages after the
  /// system message) the new generator starts from, as text — what a session
  /// rebuilt from its history would hold. Null = none.
  final List<Map<String, String>>? seedHistory;
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
    this.end,
    this.promptTokens,
    this.generatedTokens,
    this.decodeMs,
  );
  final int id;

  /// How the turn ended: [TurnEnd.endOfSequence], [TurnEnd.outputLimit] or
  /// [TurnEnd.contextLimit] from the engine, [TurnEnd.stopped] after a
  /// [StopSignal] or a [ResetSessionRequest], [TurnEnd.closed] after a
  /// [Close].
  final TurnEnd end;
  final int promptTokens;
  final int generatedTokens;
  final int decodeMs;
}

/// Worker → main: [id]'s generation failed.
class GenerateError {
  GenerateError(this.id, this.error, {this.end});
  final int id;
  final String error;

  /// [TurnEnd.contextLimit] when the prompt did not fit the context window;
  /// null for any other failure.
  final TurnEnd? end;
}

/// Main → worker: stop [sessionId]'s generation, if it is the one in flight
/// (or queued) — or, from [StopSignal.request], only the turn [requestId]. A
/// stop for one session never cuts off another's turn. NOT gated by the
/// client's `_mutex` — it must be able to interrupt a call holding it. A null
/// [sessionId] is the legacy session.
class StopSignal {
  const StopSignal([this.sessionId]) : requestId = null;

  /// Stops the turn [requestId] and nothing else: what a cancelled
  /// subscription sends. A consumer that paused its stream and cancels it
  /// after the turn ended — and the session's next turn started — must not
  /// stop that next turn, which a stop naming the session would.
  const StopSignal.request(int this.requestId) : sessionId = null;

  final int? sessionId;
  final int? requestId;
}

/// Main → worker: destroy [sessionId]'s live generator so its next turn starts
/// fresh (and, for an opened session, so its KV cache is released). A null
/// [sessionId] is the legacy session.
class ResetSessionRequest extends QueuedRequest {
  const ResetSessionRequest([this.sessionId]);
  final int? sessionId;
}

/// Worker → main: [ResetSessionRequest] handled. [error] is set, with its
/// stack, when destroying the generator threw: the next turn may then
/// continue the old conversation, and the client says so.
class ResetSessionAck {
  const ResetSessionAck([this.error]);
  final String? error;
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
/// [error] is set, with its stack, when freeing them threw: the native model
/// may then still be resident, and the main isolate says so.
class CloseAck {
  const CloseAck([this.error]);
  final String? error;
}

/// Worker → main: the last message of a worker whose load failed. The load
/// error itself went first, as a plain `String`, so the caller never waits
/// for this; it follows once the worker has freed what the load allocated.
/// [error] is set, with its stack, when that close threw.
class LoadCleanup {
  const LoadCleanup([this.error]);
  final String? error;
}

/// Worker → main: the serving loop itself threw — a bug, since serving a
/// request never throws — and the worker closed the engine anyway before the
/// error ends it. [error] is set, with its stack, when that close threw too.
class LoopFailed {
  const LoopFailed([this.error]);
  final String? error;
}

/// Signature every worker entry point (real or a test fake) must match —
/// the injection seam `GenAiFfiClient({workerEntry})` spawns. Both the real
/// entry and the test fake hand their engine to `serveGenAiWorker`
/// (`gen_ai_worker.dart`), so a fake exercises the real worker loop.
typedef GenAiWorkerEntry = Future<void> Function(WorkerInit init);
