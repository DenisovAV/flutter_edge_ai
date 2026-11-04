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

import 'package:flutter_edge_ai/engine.dart';

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
  ///
  /// [guidance] is the session's JSON schema, set on a generator the turn
  /// creates; null = unguided. [seedHistory], on a first turn, is the
  /// conversation the new generator starts from, as text (after the system
  /// message). A prompt that does not fit the context window throws
  /// [GenAiContextFullException].
  Future<GenAiTurnResult> generate(
    GenAiTurn turn, {
    String? guidance,
    List<Map<String, String>>? seedHistory,
    required void Function(String piece) emit,
    required bool Function() stopRequested,
  });

  /// Settles [sessionId]'s last turn before anything else is served: keeps
  /// it in the generator and the session's history ([AfterTurn.keep]), or
  /// restores the generator to its length before the turn
  /// ([AfterTurn.rewind]; where a rewind fails, the generator is dropped and
  /// the session's next turn rebuilds it from the session's history text,
  /// said once). Called after every turn, including one that threw; a turn
  /// that never reached its prefill has nothing to undo. Returns false when
  /// a rewind fell back to the rebuild.
  bool endTurn({int? sessionId, required AfterTurn how});

  /// Token count for [text] via the tokenizer's own encoder (no template).
  int countTokens(String text);

  /// Destroys [sessionId]'s live generator (null = the legacy session), so its
  /// next turn starts a fresh one. A session with no generator is a no-op.
  void resetGenerator({int? sessionId});

  /// Frees every native handle. Called exactly once, also after a failed
  /// [load], so it must cope with a partial one.
  void close();
}

/// What happens to a session's generator after a turn ([afterTurn]).
enum AfterTurn {
  /// The turn stays in the generator and the history.
  keep,

  /// The generator goes back to its length before the turn, so the session
  /// keeps its history without the turn.
  rewind,

  /// A stopped turn: its exchange — the prompt and the reply as far as it
  /// got, the tokens the user saw — stays in the generator, closed with the
  /// model's end-of-turn token, as if the reply had ended there. Core's chat
  /// keeps the partial reply in its history, so the model's context must
  /// hold it too (LiteRT-LM keeps a stopped exchange the same way, §16). The
  /// grammar of a guided session is reset, so the next turn is guided from
  /// its start.
  keepStopped,
}

/// The rule for what a turn that ended [end] (null: it failed) leaves
/// behind, so the session stays usable with its history — design 2.6.0 §3,
/// "the engine restores the context to before this turn":
/// - an end of sequence is kept;
/// - a stop keeps its exchange, closed as a finished turn
///   ([AfterTurn.keepStopped]), guided or not;
/// - a full context window, a prompt that did not fit and a failure are
///   rewound: the session keeps its earlier turns, without this one;
/// - a turn at `maxOutputTokens` is rewound when guided — ORT-GenAI resets
///   the grammar only when the generator is done or rewound, and the next
///   prompt would otherwise be committed into the half-parsed value — and
///   kept when not (the session continues it, as before).
AfterTurn afterTurn(TurnEnd? end, {required bool guided}) => switch (end) {
  TurnEnd.endOfSequence => AfterTurn.keep,
  TurnEnd.outputLimit => guided ? AfterTurn.rewind : AfterTurn.keep,
  TurnEnd.stopped => AfterTurn.keepStopped,
  TurnEnd.contextLimit || TurnEnd.closed || null => AfterTurn.rewind,
};

/// What [GenAiWorkerEngine.generate] returns: the turn's counters and how it
/// ended — [TurnEnd.endOfSequence], [TurnEnd.outputLimit],
/// [TurnEnd.contextLimit], or [TurnEnd.stopped] when it returned because
/// `stopRequested` reported true. The loop turns a stop that a close caused
/// into [TurnEnd.closed].
final class GenAiTurnResult {
  const GenAiTurnResult(this.stats, this.end);
  final GenAiGenerationStats stats;
  final TurnEnd end;
}

/// Thrown by [GenAiWorkerEngine.generate] when the prompt does not fit what is
/// left of the context window; the turn's error then reports
/// [TurnEnd.contextLimit].
final class GenAiContextFullException implements Exception {
  const GenAiContextFullException(this.message);
  final String message;

  @override
  String toString() => message;
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
/// - A failed [GenAiWorkerEngine.load] sends its error first, so the caller
///   fails at once, then closes the engine and leaves through `Isolate.exit`
///   with [LoadCleanup].
/// - Serving a request never throws; a failure is the request's reply. Should
///   the loop itself throw, the engine is closed anyway, [LoopFailed] says
///   so, and the error ends the isolate.
Future<void> serveGenAiWorker(WorkerInit init, GenAiWorkerEngine engine) async {
  edgeAiLogLevel = init.logLevel;

  try {
    await engine.load();
  } catch (e, st) {
    edgeAiLog('[GenAiFfiClient/worker] load failed: $e\n$st');
    // The error goes FIRST, so a native close that never returns cannot hold
    // the caller too.
    init.replyTo.send('ONNX GenAI worker failed to load: $e');
    // Then what the load allocated is freed, in this same isolate — never by
    // killing it, which would skip the close. The client is still listening
    // and reports a close that fails.
    Isolate.exit(init.replyTo, LoadCleanup(_closeEngine(engine)));
  }

  final commandPort = ReceivePort();
  final queued = Queue<QueuedRequest>();
  var closeRequested = false;
  // Sessions (null = the legacy one) whose running or queued turn has had a
  // stop filed. A stop names its session, so one session's stop never cuts
  // off the turn of another.
  final stopped = <int?>{};
  // Turns stopped by request id: a cancelled subscription names its own turn,
  // so a stop that arrives after that turn ended stops nothing.
  final stoppedRequests = <int>{};
  var hasRunning = false;
  int? runningSession;
  int? runningRequest;
  Completer<void>? wake;

  bool isLive(int? sessionId) =>
      (hasRunning && runningSession == sessionId) ||
      queued.any((r) => r is GenerateRequest && r.turn.sessionId == sessionId);

  bool isLiveRequest(int requestId) =>
      runningRequest == requestId ||
      queued.any((r) => r is GenerateRequest && r.id == requestId);

  commandPort.listen((msg) {
    switch (msg) {
      case GenerateRequest():
        // A turn starts un-stopped, and any StopSignal for its session filed
        // from here on — even before the turn has started — stops it. A
        // session stop (`stopGeneration`) names a session, not a turn, so the
        // worker cannot tell a late one for the session's previous turn from
        // one meant for this one: one filed before this request is dropped,
        // one filed after it applies. A cancelled subscription's stop names
        // its request instead (StopSignal.request), so it never reaches a
        // later turn. The client sends a turn only after the previous one
        // finished, so this never un-stops a running generation.
        stopped.remove(msg.turn.sessionId);
        queued.add(msg);
      case CountTokensRequest():
        queued.add(msg);
      case ResetSessionRequest():
        // Unwind the session's generation in flight, if any — bounded to one
        // more token — so the reset runs right after it, not after a full
        // decode. Another session's turn is left alone.
        if (isLive(msg.sessionId)) stopped.add(msg.sessionId);
        queued.add(msg);
      case StopSignal(:final requestId?):
        if (isLiveRequest(requestId)) stoppedRequests.add(requestId);
      case StopSignal(:final sessionId):
        if (isLive(sessionId)) stopped.add(sessionId);
      case Close():
        closeRequested = true;
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
      final request = queued.removeFirst();
      final sessionId = request is GenerateRequest
          ? request.turn.sessionId
          : null;
      final requestId = request is GenerateRequest ? request.id : null;
      if (request is GenerateRequest) {
        hasRunning = true;
        runningSession = sessionId;
        runningRequest = requestId;
      }
      try {
        await _serve(
          request,
          engine,
          init.replyTo,
          () =>
              closeRequested ||
              stopped.contains(sessionId) ||
              stoppedRequests.contains(requestId),
          () => closeRequested,
        );
      } finally {
        if (request is GenerateRequest) {
          hasRunning = false;
          runningRequest = null;
          stopped.remove(sessionId);
          stoppedRequests.remove(requestId);
        }
      }
    }
  } catch (_) {
    // Serving a request never throws, so this is a bug in the loop itself.
    // The native handles are freed anyway, and the client told so; the error
    // then ends the isolate and reaches the client through onError and
    // onExit.
    init.replyTo.send(LoopFailed(_closeEngine(engine)));
    rethrow;
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the client never has to kill it.
  Isolate.exit(init.replyTo, CloseAck(_closeEngine(engine)));
}

/// Runs one request and replies. Never throws, so one failure cannot stop the
/// loop that serves the rest.
Future<void> _serve(
  QueuedRequest request,
  GenAiWorkerEngine engine,
  SendPort replyTo,
  bool Function() stopRequested,
  bool Function() closeRequested,
) async {
  switch (request) {
    case GenerateRequest(
      :final id,
      :final turn,
      :final guidance,
      :final seedHistory,
    ):
      // The turn is settled (kept, rewound or reset) before its reply is
      // sent and before the next request is served, so no later turn — of
      // this session or another — ever meets a generator the turn left
      // half done, however the consumer reads the reply.
      void settle(TurnEnd? end) {
        // A close frees every generator anyway.
        if (closeRequested()) return;
        try {
          engine.endTurn(
            sessionId: turn.sessionId,
            how: afterTurn(end, guided: guidance != null),
          );
        } catch (e, st) {
          // endTurn handles its own failures; this is a bug in it.
          // ignore: avoid_print
          print(
            '[flutter_edge_ai_onnx] WARNING: settling an ONNX GenAI turn '
            'failed: $e\n$st',
          );
        }
      }

      try {
        final GenAiTurnResult(:stats, :end) = await engine.generate(
          turn,
          guidance: guidance,
          seedHistory: seedHistory,
          emit: (piece) => replyTo.send(Chunk(id, piece)),
          stopRequested: stopRequested,
        );
        settle(end);
        replyTo.send(
          GenerateDone(
            id,
            end == TurnEnd.stopped && closeRequested() ? TurnEnd.closed : end,
            stats.promptTokens,
            stats.generatedTokens,
            stats.decodeMs,
          ),
        );
      } on GenAiContextFullException catch (e) {
        settle(TurnEnd.contextLimit);
        replyTo.send(GenerateError(id, '$e', end: TurnEnd.contextLimit));
      } catch (e, st) {
        edgeAiLog('[GenAiFfiClient/worker] generate failed: $e\n$st');
        settle(null);
        replyTo.send(GenerateError(id, '$e'));
      }
    case CountTokensRequest(:final id, :final text):
      try {
        replyTo.send(CountTokensReply(id, engine.countTokens(text), null));
      } catch (e) {
        replyTo.send(CountTokensReply(id, null, '$e'));
      }
    case ResetSessionRequest(:final sessionId):
      try {
        engine.resetGenerator(sessionId: sessionId);
        replyTo.send(const ResetSessionAck());
      } catch (e, st) {
        // Carried in the ack, not swallowed: the next turn may continue the
        // old conversation, and the client says so where release builds see.
        edgeAiLog(
          '[GenAiFfiClient/worker] resetting the generator failed: $e\n$st',
        );
        replyTo.send(ResetSessionAck('$e\n$st'));
      }
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

/// Closes [engine], reporting a failure as text — error and stack, since the
/// stack is all the client will ever see of it — instead of throwing, so the
/// caller still sends its last message. Null means it closed cleanly.
String? _closeEngine(GenAiWorkerEngine engine) {
  try {
    engine.close();
    return null;
  } catch (e, st) {
    edgeAiLog('[GenAiFfiClient/worker] close failed: $e\n$st');
    return '$e\n$st';
  }
}
