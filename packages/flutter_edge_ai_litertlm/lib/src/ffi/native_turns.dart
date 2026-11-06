import 'dart:async';

import 'package:mutex/mutex.dart';

/// How a native operation on a conversation ended.
enum NativeTurnEnd { completed, cancelled, failed }

/// Native cancelled a turn that nobody on this side asked to cancel: the turn
/// depended on an earlier cancelled one, so the conversation is poisoned and
/// has to be rebuilt.
class LiteRtLmTurnCancelledException implements Exception {
  const LiteRtLmTurnCancelledException();

  @override
  String toString() =>
      'LiteRtLmTurnCancelledException: native cancelled a turn that was not '
      'stopped; the conversation answers nothing until it is rebuilt';
}

/// A turn ended by closing its session or model before anyone asked to stop
/// it (B90): a [StateError], so a consumer of `getResponseAsync` sees one,
/// and a type of its own, so the session's `startTurn` can report the close
/// as `TurnEnd.closed` and end the text cleanly instead.
class LiteRtLmTurnClosedException extends StateError {
  LiteRtLmTurnClosedException()
    : super(
        'The session was closed during this turn (close(), uninstallModel, '
        'or a replaced active model); the reply is incomplete.',
      );
}

/// One native operation on a conversation — a streamed send or a rewind —
/// from its start until native has posted its end.
class NativeTurn {
  final _ended = Completer<NativeTurnEnd>();
  final _cancelRequested = Completer<void>();
  final _cancelIssued = Completer<void>();

  /// Completes once native has posted the end and, if [NativeTurns.release]
  /// was called meanwhile, the conversation has been deleted.
  Future<NativeTurnEnd> get ended => _ended.future;
  Future<void> get cancellationRequested => _cancelRequested.future;
  Future<void> get cancellationIssued => _cancelIssued.future;
  bool get hasEnded => _ended.isCompleted;

  /// A stop was asked for: stopGeneration(), close(), or the consumer
  /// cancelling its subscription.
  bool cancelRequested = false;

  /// A streamed send has been registered in Dart but its spawned isolate is
  /// still inside `litert_lm_conversation_send_message_stream`. LiteRT-LM
  /// forbids overlapping calls on one conversation, so [NativeTurns.cancel]
  /// retains a stop until the platform's safe native-entry boundary.
  bool nativeStartPending = false;

  /// The spawned send entry point has not returned yet. On platforms that
  /// permit concurrent cancellation, retries cover native prefill tasks that
  /// may be created after an earlier `cancel_process` call.
  bool nativeCallInFlight = false;

  /// Whether this turn has issued a native cancellation. Serialized platforms
  /// issue exactly one; other platforms may retry while prefill runs.
  bool cancelSent = false;

  bool cancelRetryRunning = false;

  /// The conversation's session or model was closed while this ran, before
  /// anyone asked to stop it: a streamed send then ends with a
  /// [StateError], not as a reply that merely stopped early.
  bool closedUnderConsumer = false;

  /// The conversation was released while this ran; it is deleted at the end.
  bool deleteWhenEnded = false;
}

/// The native operation running on each conversation. Nothing deletes a
/// conversation, and no later operation starts on it, before the one that runs
/// has ended: a cancel only asks native to stop, and the task — and its
/// callbacks — finish later.
class NativeTurns<C extends Object> {
  NativeTurns({
    required this.cancelNative,
    required this.deleteNative,
    void Function(C conversation)? retryCancelNative,
    this.serializeCancelWithNativeStart = true,
    this.cancelEndTimeout,
    this.cancelRetryInterval = const Duration(milliseconds: 20),
  }) : retryCancelNative = retryCancelNative ?? cancelNative;

  /// Asks native to stop what runs on a conversation; returns at once.
  final void Function(C conversation) cancelNative;

  /// Repeats cancellation during native prefill. Production uses a quiet
  /// callback so a retained stop does not flood logs.
  final void Function(C conversation) retryCancelNative;

  /// Deletes a conversation natively.
  final void Function(C conversation) deleteNative;

  /// Whether cancellation must wait until a synchronous streamed-send entry
  /// point has returned. Production leaves this false so a stop can interrupt
  /// prefill; true remains available to exercise the retained-stop policy.
  final bool serializeCancelWithNativeStart;

  /// How long a consumer waits for native to post its end after cancellation.
  /// A timeout fails the consumer but deliberately does not end the native
  /// turn or release its lock: doing either could use or delete a conversation
  /// while native still owns it.
  final Duration? cancelEndTimeout;

  /// Delay between cancellation retries while a non-serialized native send
  /// entry point is still synchronously prefilling.
  final Duration cancelRetryInterval;

  final Map<C, NativeTurn> _running = {};

  /// The operation running on [conversation], if any.
  NativeTurn? runningOn(C conversation) => _running[conversation];

  /// Registers an operation that is about to start on [conversation].
  NativeTurn begin(C conversation, {bool nativeStartPending = false}) {
    final previous = _running[conversation];
    if (previous != null && !previous.hasEnded) {
      throw StateError(
        'A native operation is still running on this '
        'conversation',
      );
    }
    return _running[conversation] = NativeTurn()
      ..nativeStartPending = nativeStartPending
      ..nativeCallInFlight = nativeStartPending;
  }

  /// Asks native to stop [conversation]'s running operation, and marks it as
  /// asked so its cancelled end is not taken for a poisoned conversation.
  void cancel(C conversation) {
    final turn = _running[conversation];
    if (turn != null) {
      turn.cancelRequested = true;
      if (!turn._cancelRequested.isCompleted) {
        turn._cancelRequested.complete();
      }
      if (turn.nativeStartPending ||
          (serializeCancelWithNativeStart && turn.cancelSent)) {
        return;
      }
      turn.cancelSent = true;
    }
    _issueCancel(conversation, turn, cancelNative);
    if (turn != null) _retryCancelDuringNativeStart(conversation, turn);
  }

  /// Marks the boundary immediately before a spawned isolate enters the C
  /// streamed-send call. Platforms that allow concurrent cancellation issue a
  /// retained stop here, once native has work to cancel. A serialized policy
  /// keeps it retained until [nativeReturned].
  void nativeEntered(C conversation, NativeTurn turn) {
    if (turn.hasEnded || !identical(_running[conversation], turn)) return;
    if (serializeCancelWithNativeStart) return;
    turn.nativeStartPending = false;
    if (turn.cancelRequested && !turn.cancelSent) {
      turn.cancelSent = true;
      _issueCancel(conversation, turn, cancelNative);
    }
    _retryCancelDuringNativeStart(conversation, turn);
  }

  /// Marks the boundary where the spawned streamed-send call has returned.
  /// This is the first cancellation point for a serialized policy, and the
  /// final reliable boundary when an earlier notification raced or was lost.
  void nativeReturned(C conversation, NativeTurn turn) {
    if (turn.hasEnded || !identical(_running[conversation], turn)) return;
    turn.nativeCallInFlight = false;
    turn.nativeStartPending = false;
    if (turn.cancelRequested &&
        (!turn.cancelSent || !serializeCancelWithNativeStart)) {
      turn.cancelSent = true;
      _issueCancel(conversation, turn, cancelNative);
    }
  }

  void _issueCancel(
    C conversation,
    NativeTurn? turn,
    void Function(C conversation) cancel,
  ) {
    if (turn != null && !turn._cancelIssued.isCompleted) {
      turn._cancelIssued.complete();
    }
    cancel(conversation);
  }

  void _retryCancelDuringNativeStart(C conversation, NativeTurn turn) {
    if (serializeCancelWithNativeStart ||
        !turn.nativeCallInFlight ||
        !turn.cancelRequested ||
        turn.cancelRetryRunning ||
        turn.hasEnded) {
      return;
    }
    turn.cancelRetryRunning = true;
    unawaited(() async {
      final timeout = cancelEndTimeout ?? const Duration(seconds: 5);
      final deadline = DateTime.now().add(timeout);
      try {
        while (turn.nativeCallInFlight &&
            !turn.hasEnded &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(cancelRetryInterval);
          if (turn.nativeCallInFlight && !turn.hasEnded) {
            turn.cancelSent = true;
            _issueCancel(conversation, turn, retryCancelNative);
          }
        }
      } finally {
        turn.cancelRetryRunning = false;
      }
    }());
  }

  /// Records that [turn] has ended natively. Deletes the conversation first
  /// when it was released meanwhile, so whoever waits on [NativeTurn.ended] —
  /// the lock that orders native calls among them — runs after the delete.
  void end(C conversation, NativeTurn turn, NativeTurnEnd how) {
    if (turn.hasEnded) return;
    turn.nativeCallInFlight = false;
    if (identical(_running[conversation], turn)) _running.remove(conversation);
    try {
      if (turn.deleteWhenEnded) deleteNative(conversation);
    } finally {
      // Whatever the delete did, the lock waiting on this end must go.
      turn._ended.complete(how);
    }
  }

  /// Deletes [conversation] now, or — when an operation runs on it — stops
  /// that operation and deletes the conversation once it has ended.
  void release(C conversation) {
    final turn = _running[conversation];
    if (turn == null) {
      // Nothing of ours runs, but native may still be finishing a generation
      // whose error already ended our turn; a delete would wait for it (#364).
      cancelNative(conversation);
      deleteNative(conversation);
      return;
    }
    turn.deleteWhenEnded = true;
    cancelForClose(conversation);
  }

  /// Stops [conversation]'s running operation because its session or model
  /// is closing. Unlike [cancel], an operation nobody had asked to stop then
  /// ends as closed under its consumer.
  void cancelForClose(C conversation) {
    final turn = _running[conversation];
    if (turn != null && !turn.cancelRequested) turn.closedUnderConsumer = true;
    cancel(conversation);
  }

  /// Completes when every operation registered so far has ended.
  Future<void> allEnded() => Future.wait([
    for (final turn in _running.values) turn.ended,
  ]).then<void>((_) {});
}

/// The stream of one native send, fed by the native callbacks.
///
/// - A chunk that arrives after a stop was asked for repeats the cancel: a
///   cancel only reaches the tasks that exist when it is made, so one that
///   lands between a prefill and its decode would otherwise be lost.
/// - A cancelled end that nobody asked for is an error
///   ([LiteRtLmTurnCancelledException]), never a clean end: it means the
///   conversation is poisoned.
/// - A cancelled end caused by closing the session or model, before anyone
///   asked to stop, is a [LiteRtLmTurnClosedException] (a [StateError]): the
///   reply is incomplete.
/// - A consumer that cancels its subscription asks native to stop and waits
///   for native's end, up to [consumerCancelWait]; the operation itself keeps
///   running to its end either way.
class NativeTurnStream<C extends Object> {
  NativeTurnStream(
    this._turns,
    this._conversation, {
    this.consumerCancelWait = const Duration(seconds: 2),
    bool nativeStartPending = false,
  }) : turn = _turns.begin(
         _conversation,
         nativeStartPending: nativeStartPending,
       ) {
    _controller.onCancel = _onConsumerCancel;
    final timeout = _turns.cancelEndTimeout;
    if (timeout != null) {
      unawaited(_failConsumerWhenCancellationStalls(timeout));
    }
  }

  final NativeTurns<C> _turns;
  final C _conversation;
  final Duration consumerCancelWait;
  final NativeTurn turn;
  final _controller = StreamController<String>();
  bool _consumerEnded = false;

  /// Called when a cancelled native operation has not ended by the deadline.
  /// The owner uses this to reject operations queued behind the stuck turn.
  void Function(Object error)? onCancelTimeout;

  Stream<String> get stream => _controller.stream;

  /// See [NativeTurns.nativeEntered].
  void nativeEntered() => _turns.nativeEntered(_conversation, turn);

  /// See [NativeTurns.nativeReturned].
  void nativeReturned() => _turns.nativeReturned(_conversation, turn);

  void chunk(String text) {
    // A consumer timeout poisons the engine but deliberately leaves this
    // native turn and its callback alive. Native may still post chunks before
    // its final callback; dropping them is the only safe action. Writing to
    // the closed controller would throw through the FFI callback and release
    // that callback while native can still invoke it.
    if (turn.hasEnded || _consumerEnded) return;
    if (turn.cancelRequested) _turns.cancel(_conversation);
    if (text.isNotEmpty) _controller.add(text);
  }

  void finished() => _end(NativeTurnEnd.completed);

  void cancelled() => _end(
    NativeTurnEnd.cancelled,
    error: turn.closedUnderConsumer
        ? LiteRtLmTurnClosedException()
        : turn.cancelRequested
        ? null
        : const LiteRtLmTurnCancelledException(),
  );

  void failed(Object error) => _end(NativeTurnEnd.failed, error: error);

  void _end(NativeTurnEnd how, {Object? error}) {
    if (turn.hasEnded) return;
    // Ended (and any pending delete done) before the consumer hears of it.
    _turns.end(_conversation, turn, how);
    if (!_consumerEnded) {
      _consumerEnded = true;
      if (error != null) _controller.addError(error);
      _controller.close();
    }
  }

  Future<void> _failConsumerWhenCancellationStalls(Duration timeout) async {
    await Future.any<void>([
      turn.cancellationIssued,
      turn.ended.then<void>((_) {}),
    ]);
    if (turn.hasEnded || _consumerEnded) return;
    await Future.any<void>([
      turn.ended.then<void>((_) {}),
      Future<void>.delayed(timeout),
    ]);
    if (turn.hasEnded || _consumerEnded) return;
    final error = TimeoutException(
      'LiteRT-LM did not end a cancelled generation within '
      '${timeout.inMilliseconds} ms; the engine remains locked to keep the '
      'native conversation alive safely.',
      timeout,
    );
    _consumerEnded = true;
    onCancelTimeout?.call(error);
    _controller.addError(error);
    await _controller.close();
  }

  Future<void>? _onConsumerCancel() {
    if (turn.hasEnded) return null;
    _turns.cancel(_conversation);
    return turn.ended
        .then<void>((_) {})
        .timeout(
          consumerCancelWait,
          onTimeout: () {
            // Release builds too: the engine stays locked until native ends it.
            // ignore: avoid_print
            print(
              '[flutter_edge_ai_litertlm] a stopped generation has not ended '
              'after ${consumerCancelWait.inSeconds} s; the next one waits for it',
            );
          },
        );
  }
}

/// Acquires [mutex], unless [abort] completes first with the error to throw.
///
/// A mutex acquisition cannot itself be cancelled. When abort wins, the
/// pending acquisition is therefore left in the queue and releases the lock
/// immediately when it eventually obtains it.
Future<void> acquireUntilAbort(Mutex mutex, Future<Object> abort) async {
  var abandoned = false;
  final acquired = Completer<void>();
  unawaited(
    mutex.acquire().then((_) {
      if (abandoned) {
        mutex.release();
      } else {
        acquired.complete();
      }
    }),
  );
  try {
    await Future.any<void>([
      acquired.future,
      abort.then<void>((error) => throw error),
    ]);
  } catch (_) {
    abandoned = true;
    rethrow;
  }
}

/// Runs [start] under [mutex] and returns its stream, keeping [mutex] held
/// until the native operation has ended — not until the consumer stops
/// listening, which can be long before (a cancelled subscription) or after (a
/// paused one).
Stream<String> heldUntilNativeEnd<C extends Object>(
  Mutex mutex,
  NativeTurnStream<C> Function() start, {
  Future<Object>? abort,
}) {
  final controller = StreamController<String>();
  StreamSubscription<String>? inner;
  var consumerGone = false;
  controller.onListen = () async {
    try {
      if (abort == null) {
        await mutex.acquire();
      } else {
        await acquireUntilAbort(mutex, abort);
      }
    } catch (e, st) {
      if (!consumerGone) {
        controller.addError(e, st);
        await controller.close();
      }
      return;
    }
    if (consumerGone) {
      mutex.release();
      return;
    }
    final NativeTurnStream<C> send;
    try {
      send = start();
    } catch (e, st) {
      mutex.release();
      controller.addError(e, st);
      await controller.close();
      return;
    }
    unawaited(send.turn.ended.whenComplete(mutex.release));
    inner = send.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
  };
  controller.onPause = () => inner?.pause();
  controller.onResume = () => inner?.resume();
  controller.onCancel = () {
    consumerGone = true;
    return inner?.cancel();
  };
  return controller.stream;
}
