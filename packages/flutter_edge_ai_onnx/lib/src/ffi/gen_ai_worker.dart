// Worker side of the ORT-GenAI isolate (`gen_ai_client.dart` is the main
// side, `gen_ai_protocol.dart` the messages between them). [serveGenAiWorker]
// is the loop; [GenAiWorkerEngine] is what it drives — the `dart:ffi` engine
// in production, a scripted fake in tests, so the tests exercise this loop
// itself. src-only, not barrel-exported.
//
// Close never kills the worker. The client used to wait five seconds for an
// ack and then `Isolate.kill` — but a prompt's prefill is one synchronous FFI
// call that can run longer than that on a CPU, and a kill that lands when it
// returns stops the isolate before it frees anything: the model, tokenizer
// and generator stayed resident for the life of the process. Now the worker
// queues requests itself and serves one at a time; a close fails what has not
// started, lets the call in flight finish (a generation stops at its next
// token), frees every handle and leaves through `Isolate.exit` on its own.
import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'gen_ai_client.dart' show GenAiGenerationStats, GenAiTurn;
import 'gen_ai_protocol.dart';

/// What [serveGenAiWorker] drives. Every native handle lives inside it, on the
/// worker isolate. Construction must not allocate anything native — that is
/// [load]'s job, so a failure there can be cleaned up.
abstract interface class GenAiWorkerEngine {
  /// Opens the libraries and loads model + tokenizer. When it throws, the
  /// worker calls [close] before it reports the error, so whatever it
  /// allocated is freed.
  Future<void> load();

  /// Runs one turn, passing each decoded piece to [emit]. Between tokens it
  /// must yield with a zero-duration timer (`await Future<void>(() {})`) and
  /// return as soon as [stopRequested] reports true: that yield is how a
  /// `StopSignal`, `ResetSessionRequest` or `Close` sent mid-turn reaches the
  /// worker.
  Future<GenAiGenerationStats> generate(
    GenAiTurn turn, {
    required void Function(String piece) emit,
    required bool Function() stopRequested,
  });

  /// Token count for [text] via the tokenizer's own encoder (no template).
  int countTokens(String text);

  /// Destroys the live generator, so the next turn starts a fresh one.
  void resetGenerator();

  /// Frees every native handle. Called exactly once, also after a failed
  /// [load], so it must cope with a partial one.
  void close();
}

/// The error a queued request gets when a [Close] arrived before it started.
/// Says "shut down", like every other request the client refuses once
/// `shutdown()` has begun.
const closedBeforeRunMessage =
    'GenAiFfiClient shut down before this request ran';

/// Loads [engine], then serves the client's requests until [Close].
///
/// - The port listener only files messages; it never starts work. A
///   [StopSignal] only raises the stop flag the running generation polls.
/// - Requests run one at a time, in arrival order, each after a zero-duration
///   timer: a call may block this isolate in synchronous FFI, so a [Close]
///   sent meanwhile is still in the message queue when it returns, and the
///   timer — posted behind it — lets the listener file the close before
///   anything else starts.
/// - [Close] fails every queued request that has not started, stops the
///   generation in flight at its next token, frees the engine (a failure is
///   reported in the ack, not thrown) and leaves with [CloseAck] through
///   `Isolate.exit`, so the client never has to kill the isolate.
/// - A failed [GenAiWorkerEngine.load] closes the engine and leaves through
///   `Isolate.exit` carrying the error.
/// - Serving a request never throws; a failure is the request's reply.
Future<void> serveGenAiWorker(WorkerInit init, GenAiWorkerEngine engine) async {
  edgeAiLogLevel = init.logLevel;

  try {
    await engine.load();
  } catch (e, st) {
    edgeAiLog('[GenAiFfiClient/worker] load failed: $e\n$st');
    // Closed BEFORE the error is sent — the client gives up on this worker
    // the moment the error arrives.
    final closeError = _closeEngine(engine);
    Isolate.exit(
      init.replyTo,
      closeError == null
          ? 'ONNX GenAI worker failed to load: $e'
          : 'ONNX GenAI worker failed to load: $e (freeing what it had loaded '
                'also failed, so native memory may still be held: '
                '$closeError)',
    );
  }

  final commandPort = ReceivePort();
  final queued = Queue<QueuedRequest>();
  var closeRequested = false;
  var stopRequested = false;
  Completer<void>? wake;

  commandPort.listen((msg) {
    switch (msg) {
      case GenerateRequest():
        // A turn starts un-stopped, and any StopSignal filed from here on —
        // even before the turn has started — stops it. A stop names no turn,
        // so the worker cannot tell a late stop for the previous turn from
        // one meant for this one: one filed before this request is dropped,
        // one filed after it applies — as when a turn started the moment its
        // request was processed. The client sends a turn only after the
        // previous one finished, so this never un-stops a running generation.
        stopRequested = false;
        queued.add(msg);
      case CountTokensRequest():
        queued.add(msg);
      case ResetSessionRequest():
        // Unwind the generation in flight, if any — bounded to one more
        // token — so the reset runs right after it, not after a full decode.
        stopRequested = true;
        queued.add(msg);
      case StopSignal():
        stopRequested = true;
      case Close():
        closeRequested = true;
        stopRequested = true;
        commandPort.close();
        // Only what has not started. The request in flight, if any, was taken
        // off the queue when it started, and it finishes on its own terms.
        while (queued.isNotEmpty) {
          _failUnstarted(queued.removeFirst(), init.replyTo);
        }
    }
    final waiting = wake;
    wake = null;
    waiting?.complete();
  });

  init.replyTo.send(Ready(commandPort.sendPort));

  final String? closeError;
  try {
    while (!closeRequested) {
      if (queued.isEmpty) {
        final idle = wake = Completer<void>();
        await idle.future;
        continue;
      }
      // Yield to the event loop before every request — see this function's
      // doc. Awaiting an already-completed future would drain only
      // microtasks, never the message queue a Close waits in.
      await Future<void>.delayed(Duration.zero);
      if (closeRequested || queued.isEmpty) continue;
      await _serve(
        queued.removeFirst(),
        engine,
        init.replyTo,
        () => stopRequested,
      );
    }
  } finally {
    // Also on an unexpected throw out of the loop: the native handles are
    // freed either way, and the throw then takes the isolate down, which the
    // client's onError/onExit handling reports.
    closeError = _closeEngine(engine);
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the client never has to kill it.
  Isolate.exit(init.replyTo, CloseAck(closeError));
}

/// Runs one request and replies. Never throws, so one failure cannot stop the
/// loop that serves the rest.
Future<void> _serve(
  QueuedRequest request,
  GenAiWorkerEngine engine,
  SendPort replyTo,
  bool Function() stopRequested,
) async {
  switch (request) {
    case GenerateRequest(:final id, :final turn):
      try {
        final stats = await engine.generate(
          turn,
          emit: (piece) => replyTo.send(Chunk(id, piece)),
          stopRequested: stopRequested,
        );
        replyTo.send(
          GenerateDone(
            id,
            stopRequested(),
            stats.promptTokens,
            stats.generatedTokens,
            stats.decodeMs,
          ),
        );
      } catch (e, st) {
        edgeAiLog('[GenAiFfiClient/worker] generate failed: $e\n$st');
        replyTo.send(GenerateError(id, '$e'));
      }
    case CountTokensRequest(:final id, :final text):
      try {
        replyTo.send(CountTokensReply(id, engine.countTokens(text), null));
      } catch (e) {
        replyTo.send(CountTokensReply(id, null, '$e'));
      }
    case ResetSessionRequest():
      try {
        engine.resetGenerator();
      } catch (e, st) {
        edgeAiLog(
          '[GenAiFfiClient/worker] resetting the generator failed: '
          '$e\n$st',
        );
      }
      replyTo.send(const ResetSessionAck());
  }
}

/// Answers a request a [Close] overtook. A reset needs no work: the close
/// destroys the generator anyway.
void _failUnstarted(QueuedRequest request, SendPort replyTo) {
  switch (request) {
    case GenerateRequest(:final id):
      replyTo.send(GenerateError(id, closedBeforeRunMessage));
    case CountTokensRequest(:final id):
      replyTo.send(CountTokensReply(id, null, closedBeforeRunMessage));
    case ResetSessionRequest():
      replyTo.send(const ResetSessionAck());
  }
}

/// Closes [engine], reporting a failure as text instead of throwing, so the
/// caller still sends its last message. Null means it closed cleanly.
String? _closeEngine(GenAiWorkerEngine engine) {
  try {
    engine.close();
    return null;
  } catch (e, st) {
    edgeAiLog('[GenAiFfiClient/worker] close failed: $e\n$st');
    return '$e';
  }
}
