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

/// One native operation on a conversation — a streamed send or a rewind —
/// from its start until native has posted its end.
class NativeTurn {
  final _ended = Completer<NativeTurnEnd>();

  /// Completes once native has posted the end and, if [NativeTurns.release]
  /// was called meanwhile, the conversation has been deleted.
  Future<NativeTurnEnd> get ended => _ended.future;
  bool get hasEnded => _ended.isCompleted;

  /// A stop was asked for: stopGeneration(), close(), or the consumer
  /// cancelling its subscription.
  bool cancelRequested = false;

  /// The conversation was released while this ran; it is deleted at the end.
  bool deleteWhenEnded = false;
}

/// The native operation running on each conversation. Nothing deletes a
/// conversation, and no later operation starts on it, before the one that runs
/// has ended: a cancel only asks native to stop, and the task — and its
/// callbacks — finish later.
class NativeTurns<C extends Object> {
  NativeTurns({required this.cancelNative, required this.deleteNative});

  /// Asks native to stop what runs on a conversation; returns at once.
  final void Function(C conversation) cancelNative;

  /// Deletes a conversation natively.
  final void Function(C conversation) deleteNative;

  final Map<C, NativeTurn> _running = {};

  /// The operation running on [conversation], if any.
  NativeTurn? runningOn(C conversation) => _running[conversation];

  /// Registers an operation that is about to start on [conversation].
  NativeTurn begin(C conversation) {
    final previous = _running[conversation];
    if (previous != null && !previous.hasEnded) {
      throw StateError(
        'A native operation is still running on this '
        'conversation',
      );
    }
    return _running[conversation] = NativeTurn();
  }

  /// Asks native to stop [conversation]'s running operation, and marks it as
  /// asked so its cancelled end is not taken for a poisoned conversation.
  void cancel(C conversation) {
    _running[conversation]?.cancelRequested = true;
    cancelNative(conversation);
  }

  /// Records that [turn] has ended natively. Deletes the conversation first
  /// when it was released meanwhile, so whoever waits on [NativeTurn.ended] —
  /// the lock that orders native calls among them — runs after the delete.
  void end(C conversation, NativeTurn turn, NativeTurnEnd how) {
    if (turn.hasEnded) return;
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
/// - A consumer that cancels its subscription asks native to stop and waits
///   for native's end, up to [consumerCancelWait]; the operation itself keeps
///   running to its end either way.
class NativeTurnStream<C extends Object> {
  NativeTurnStream(
    this._turns,
    this._conversation, {
    this.consumerCancelWait = const Duration(seconds: 2),
  }) : turn = _turns.begin(_conversation) {
    _controller.onCancel = _onConsumerCancel;
  }

  final NativeTurns<C> _turns;
  final C _conversation;
  final Duration consumerCancelWait;
  final NativeTurn turn;
  final _controller = StreamController<String>();

  Stream<String> get stream => _controller.stream;

  void chunk(String text) {
    if (turn.hasEnded) return;
    if (turn.cancelRequested) _turns.cancel(_conversation);
    if (text.isNotEmpty) _controller.add(text);
  }

  void finished() => _end(NativeTurnEnd.completed);

  void cancelled() => _end(
    NativeTurnEnd.cancelled,
    error: turn.cancelRequested ? null : const LiteRtLmTurnCancelledException(),
  );

  void failed(Object error) => _end(NativeTurnEnd.failed, error: error);

  void _end(NativeTurnEnd how, {Object? error}) {
    if (turn.hasEnded) return;
    // Ended (and any pending delete done) before the consumer hears of it.
    _turns.end(_conversation, turn, how);
    if (error != null) _controller.addError(error);
    _controller.close();
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

/// Runs [start] under [mutex] and returns its stream, keeping [mutex] held
/// until the native operation has ended — not until the consumer stops
/// listening, which can be long before (a cancelled subscription) or after (a
/// paused one).
Stream<String> heldUntilNativeEnd<C extends Object>(
  Mutex mutex,
  NativeTurnStream<C> Function() start,
) {
  final controller = StreamController<String>();
  StreamSubscription<String>? inner;
  var consumerGone = false;
  controller.onListen = () async {
    await mutex.acquire();
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
