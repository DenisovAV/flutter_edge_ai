// A scripted fake ORT-GenAI worker — a REAL isolate, REAL ports, ZERO FFI.
// Speaks the exact `gen_ai_protocol.dart` message shapes the production
// `_defaultWorkerEntry` (`lib/src/ffi/gen_ai_client.dart`) does, so
// `test/gen_ai_client_lifecycle_test.dart` can inject it via
// `GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry)` and exercise the REAL
// client's dispatch/mutex/`_closed`-recheck machinery end-to-end (hardened
// plan Task 2b/2c) — something a `FakeGenAiClient`-based session test cannot
// reach, since that fake skips `GenAiFfiClient` entirely. This fake has NO
// FFI and no native pointers: it mirrors the real worker's
// stop-then-await-activeGeneration ORDERING for realistic client-side
// timing, but it cannot prove that ordering is what makes the real worker's
// native handle teardown use-after-free-safe — see
// `onnx_generation_host_smoke_test.dart`'s real-worker regression test for
// that.
//
// Script format: [GenAiTurn.userContent] is JSON (falls back to a single
// verbatim echo chunk if it doesn't parse):
//   {"chunks": ["a", "b"], "delayMs": 10, "echoIsFirstTurn": true}
// - `chunks`: pieces emitted in order, one per (simulated) decode step.
// - `delayMs`: real-clock delay before each chunk (0 = yield-only, still
//   enough for a queued StopSignal to land between chunks — mirrors the
//   real worker's per-token yield).
// - `echoIsFirstTurn`: when true, a marker chunk `[isFirstTurn=<bool>]` is
//   sent FIRST, echoing what the worker received on [GenAiTurn.isFirstTurn]
//   — lets a test assert the client-observable effect of `resetSession()`
//   without reaching into worker-private state.
// - `kill`: when true, the isolate kills ITSELF (`Isolate.current.kill`)
//   instead of ever replying — simulates an unexpected native crash
//   mid-generation, same shape as `embedding_worker_test.dart`'s
//   `killMidRequest` fake mode. Never sends a Chunk/GenerateDone.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_gemma_onnx/src/ffi/gen_ai_client.dart' show GenAiTurn;
import 'package:flutter_gemma_onnx/src/ffi/gen_ai_protocol.dart';

Future<void> fakeGenAiWorkerEntry(WorkerInit init) async {
  final commandPort = ReceivePort();
  init.replyTo.send(Ready(commandPort.sendPort));

  var stopRequested = false;

  // Mirrors the real worker's `activeGeneration` — teardown branches await
  // this before acking, so a suspended generate() always finishes (and
  // sends its GenerateDone/Error) before Close/ResetSessionRequest replies.
  Future<void>? activeGeneration;

  Future<void> runGenerate(int id, GenAiTurn turn) async {
    stopRequested = false;
    List<String> chunks;
    int delayMs;
    var echoIsFirstTurn = false;
    try {
      final decoded = jsonDecode(turn.userContent) as Map<String, dynamic>;
      if (decoded['kill'] == true) {
        // Simulate an unexpected native crash: the isolate dies while a
        // request is in flight, never sending a reply — the real worker's
        // `onExit` port is what `GenAiFfiClient._dispatch`'s `msg == null`
        // branch is built to catch.
        Isolate.current.kill(priority: Isolate.immediate);
        // Unreachable in practice — kill() terminates before this returns —
        // but the function must still return on every path.
        return;
      }
      chunks = (decoded['chunks'] as List).cast<String>();
      delayMs = (decoded['delayMs'] as num?)?.toInt() ?? 0;
      echoIsFirstTurn = decoded['echoIsFirstTurn'] == true;
    } catch (_) {
      chunks = [turn.userContent];
      delayMs = 0;
    }

    var generated = 0;
    if (echoIsFirstTurn) {
      init.replyTo.send(Chunk(id, '[isFirstTurn=${turn.isFirstTurn}]'));
      generated++;
    }

    for (final chunk in chunks) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      } else {
        // Yield-only pacing still gives a queued StopSignal a chance to
        // interleave, same shape as the real worker's `await Future(() {})`.
        await Future<void>(() {});
      }
      if (stopRequested) break;
      init.replyTo.send(Chunk(id, chunk));
      generated++;
    }

    init.replyTo.send(
      GenerateDone(id, stopRequested, chunks.length, generated, generated),
    );
    stopRequested = false;
  }

  try {
    await for (final msg in commandPort) {
      if (msg is GenerateRequest) {
        final future = runGenerate(msg.id, msg.turn);
        activeGeneration = future;
        unawaited(
          future.whenComplete(() {
            if (identical(activeGeneration, future)) activeGeneration = null;
          }),
        );
      } else if (msg is CountTokensRequest) {
        // Deterministic zero-native token count — good enough for lifecycle
        // assertions, which only care about the reply round-tripping.
        init.replyTo.send(
          CountTokensReply(msg.id, (msg.text.length / 4).ceil(), null),
        );
      } else if (msg is StopSignal) {
        stopRequested = true;
      } else if (msg is ResetSessionRequest) {
        stopRequested = true;
        if (activeGeneration case final active?) await active;
        init.replyTo.send(const ResetSessionAck());
      } else if (msg is Close) {
        stopRequested = true;
        if (activeGeneration case final active?) await active;
        commandPort.close();
        break;
      }
    }
  } finally {
    init.replyTo.send(const CloseAck());
  }
}
