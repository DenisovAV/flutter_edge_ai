// The order of the calls on one LlmInference, shared by every session of the
// model. Platform-neutral, so VM tests drive it without MediaPipe.
import 'dart:async';

import 'package:flutter_edge_ai/engine.dart' show edgeAiLog;

/// One call of a session to the backend. A stop names the call it stops, so
/// it never reaches the call of another session that shares the model.
final class WebLlmCall {}

/// Runs the calls of every session of one model one at a time, in the order
/// they were made.
///
/// MediaPipe runs one call at a time on an `LlmInference` and refuses another
/// while the one before it is still ending ("Previous invocation or loading
/// is still ongoing"); a stopped call ends a moment after the stop.
class WebLlmLane {
  WebLlmLane({this.stoppedCallWait = const Duration(seconds: 30)});

  /// How long the next call waits for a stopped call to end. A call that was
  /// not stopped is waited for as long as it runs: it is another session's
  /// generation, and MediaPipe would refuse a call next to it.
  final Duration stoppedCallWait;

  /// Ends when the last call queued so far has ended or was let go of.
  Future<void> _tail = Future<void>.value();

  final Expando<_Slot> _slots = Expando<_Slot>();

  _Slot _slotOf(WebLlmCall call) => _slots[call] ??= _Slot();

  /// Runs [start] for [call] once every call queued before it has ended, and
  /// returns what it returns. Returns null without running [start] when
  /// [call] is cancelled first; a cancel while it waits returns at once, and
  /// the call after it still waits for the ones before.
  Future<T?> run<T>(WebLlmCall call, Future<T> Function() start) async {
    final slot = _slotOf(call);
    final previous = _tail;
    _tail = slot.released.future;
    if (!slot.cancelled) {
      await Future.any([previous, slot.whenCancelled.future]);
    }
    if (slot.cancelled) {
      unawaited(previous.whenComplete(slot.release));
      return null;
    }
    try {
      slot.started = true;
      return await start();
    } finally {
      slot.release();
    }
  }

  /// Marks [call] cancelled. One still waiting never starts; for one that has
  /// started, returns true: the caller stops it in MediaPipe, and the next
  /// call waits for it at most [stoppedCallWait].
  bool cancel(WebLlmCall call) {
    final slot = _slotOf(call);
    if (slot.cancelled) return false;
    slot.cancelled = true;
    slot.whenCancelled.complete();
    if (!slot.started || slot.released.isCompleted) return false;
    Timer(stoppedCallWait, () {
      if (slot.released.isCompleted) return;
      edgeAiLog(
        '[MediaPipe Web] the stopped call did not end in '
        '${stoppedCallWait.inMilliseconds} ms',
      );
      slot.release();
    });
    return true;
  }
}

class _Slot {
  bool cancelled = false;
  final Completer<void> whenCancelled = Completer<void>();
  bool started = false;

  /// Completes when the call has ended, or when the next call stops waiting
  /// for it.
  final Completer<void> released = Completer<void>();

  void release() {
    if (!released.isCompleted) released.complete();
  }
}
