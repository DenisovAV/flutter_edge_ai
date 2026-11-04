// The order of the calls on one LlmInference, shared by every session of the
// model. Platform-neutral, so VM tests drive it without MediaPipe.
import 'dart:async';

/// One call to the backend. A stop names the call it stops, so it never
/// reaches the call of another session that shares the model.
final class WebLlmCall {
  WebLlmCall({this.owner});

  /// Who made the call, for the warnings: `session 2`, `sizeInTokens`.
  final String? owner;
}

/// Runs the calls of every session of one model one at a time, in the order
/// they were made: generations and token counts alike.
///
/// MediaPipe runs one call at a time on an `LlmInference` and refuses another
/// while one runs ("engine is currently loading or processing", also for
/// `sizeInTokens`); a stopped call ends a moment after the stop.
///
/// A call that was not stopped is waited for as long as it runs, with no
/// limit: a session's turn waits for the turns of the other sessions, and one
/// that never ends holds every other session until it is stopped or closed.
/// A wait past [slowWaitWarning] is printed once per lane, naming the call it
/// waits for.
class WebLlmLane {
  WebLlmLane({
    this.stoppedCallWait = const Duration(seconds: 30),
    this.slowWaitWarning = const Duration(seconds: 30),
    void Function(String message)? warn,
  }) : _warn = warn ?? _print;

  /// How long the next call waits for a stopped call to end. Past it the next
  /// call starts, and MediaPipe may refuse it as busy.
  final Duration stoppedCallWait;

  /// How long a call waits before the lane says so.
  final Duration slowWaitWarning;

  final void Function(String message) _warn;
  bool _slowWarned = false;
  bool _giveUpWarned = false;

  /// Ends when the last call queued so far has ended or was let go of.
  Future<void> _tail = Future<void>.value();

  /// The call in MediaPipe now, if any.
  _Slot? _running;

  final Expando<_Slot> _slots = Expando<_Slot>();

  _Slot _slotOf(WebLlmCall call) => _slots[call] ??= _Slot(call.owner);

  /// Runs [start] for [call] once every call queued before it has ended, and
  /// returns what it returns. Returns null without running [start] when
  /// [call] is cancelled first; a cancel while it waits returns at once, and
  /// the call after it still waits for the ones before. A call runs once.
  Future<T?> run<T>(WebLlmCall call, Future<T> Function() start) async {
    final slot = _slotOf(call);
    assert(!slot.queued, 'A WebLlmCall runs once.');
    slot.queued = true;
    final previous = _tail;
    _tail = slot.released.future;
    if (!slot.cancelled) {
      final slow = Timer(slowWaitWarning, () => _warnSlow(slot));
      try {
        await Future.any([previous, slot.whenCancelled.future]);
      } finally {
        slow.cancel();
      }
    }
    if (slot.cancelled) {
      unawaited(previous.whenComplete(slot.release));
      return null;
    }
    try {
      slot.started = true;
      _running = slot;
      return await start();
    } finally {
      if (identical(_running, slot)) _running = null;
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
      if (!_giveUpWarned) {
        _giveUpWarned = true;
        _warn(
          'the stopped call of ${slot.name} did not end in '
          '${stoppedCallWait.inSeconds} s; the next call starts anyway and '
          'MediaPipe may refuse it as busy. Shown once per model.',
        );
      }
      slot.release();
    });
    return true;
  }

  void _warnSlow(_Slot waiting) {
    if (_slowWarned) return;
    _slowWarned = true;
    final running = _running;
    _warn(
      'a call of ${waiting.name} has waited ${slowWaitWarning.inSeconds} s '
      'for ${running == null ? 'the calls before it' : 'the call of ${running.name}'}'
      ': the sessions of one web model take turns, and a call that is not '
      'stopped is waited for as long as it runs. Shown once per model.',
    );
  }
}

void _print(String message) {
  // Printed, because a release build is where it gets reported and edgeAiLog
  // is silent there.
  // ignore: avoid_print
  print('[flutter_edge_ai_mediapipe] WARNING: $message');
}

class _Slot {
  _Slot(this.owner);
  final String? owner;
  String get name => owner ?? 'a session';

  bool queued = false;
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
