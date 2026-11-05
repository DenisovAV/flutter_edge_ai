// The order of the calls on one LlmInference, shared by every session of the
// model. Platform-neutral, so VM tests drive it without MediaPipe.
import 'dart:async';
import 'dart:collection';

/// One call to the backend. A stop names the call it stops, so it never
/// reaches the call of another session that shares the model.
final class WebLlmCall {
  WebLlmCall({this.owner});

  /// Who made the call, for the warnings: `session 2`, `sizeInTokens`.
  final String? owner;
}

/// Runs the calls of every session of one model one at a time: generations
/// in the order they were made, and token counts ([run] with `priority`)
/// right after the call in MediaPipe, ahead of the generations that wait. A
/// count starts no generation, so the order of the generations is kept, and
/// a chat that counts its reply after its turn waits for at most one call,
/// not for every generation queued behind it.
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

  /// The call MediaPipe has, until it ends or is let go of.
  _Slot? _active;

  /// The calls that wait for [_active]: counts first, then generations.
  final Queue<_Slot> _counts = Queue<_Slot>();
  final Queue<_Slot> _generations = Queue<_Slot>();

  final Expando<_Slot> _slots = Expando<_Slot>();

  _Slot _slotOf(WebLlmCall call) => _slots[call] ??= _Slot(call.owner);

  /// Runs [start] for [call] when its turn comes, and returns what it
  /// returns. Returns null without running [start] when [call] is cancelled
  /// first; a cancel while it waits returns at once. With [priority] (a token
  /// count) the turn comes right after the call in MediaPipe. A call runs
  /// once.
  Future<T?> run<T>(
    WebLlmCall call,
    Future<T> Function() start, {
    bool priority = false,
  }) async {
    final slot = _slotOf(call);
    assert(!slot.queued, 'A WebLlmCall runs once.');
    slot.queued = true;
    if (slot.cancelled) return null;
    if (_active == null) {
      _active = slot;
    } else {
      (priority ? _counts : _generations).add(slot);
      final slow = Timer(slowWaitWarning, () => _warnSlow(slot));
      try {
        await Future.any([slot.turn.future, slot.whenCancelled.future]);
      } finally {
        slow.cancel();
      }
      if (slot.cancelled) {
        _counts.remove(slot);
        _generations.remove(slot);
        // Its turn may have come with the cancel: it passes it on.
        _release(slot);
        return null;
      }
    }
    try {
      slot.started = true;
      return await start();
    } finally {
      _release(slot);
    }
  }

  /// Ends [slot]'s hold on MediaPipe, if it has it, and gives the turn to
  /// the next call.
  void _release(_Slot slot) {
    slot.release();
    if (!identical(_active, slot)) return;
    _active = null;
    while (_counts.isNotEmpty || _generations.isNotEmpty) {
      final next = _counts.isNotEmpty
          ? _counts.removeFirst()
          : _generations.removeFirst();
      if (next.cancelled) continue;
      _active = next;
      next.turn.complete();
      return;
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
      _release(slot);
    });
    return true;
  }

  void _warnSlow(_Slot waiting) {
    if (_slowWarned) return;
    _slowWarned = true;
    final running = _active;
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

  /// Completes when the lane gives it MediaPipe.
  final Completer<void> turn = Completer<void>();

  /// Completes when the call has ended, or was let go of.
  final Completer<void> released = Completer<void>();

  void release() {
    if (!released.isCompleted) released.complete();
  }
}
