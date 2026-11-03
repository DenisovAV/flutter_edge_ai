import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';

/// [text] as an [EngineTurn] whose `end` says how the turn ended, for a
/// session that knows when it was stopped or closed.
///
/// - [stopped]: the consumer asked during this turn (`stopGeneration()`); a
///   cancelled subscription is a stop too.
/// - [closed]: the session or its model was closed during this turn, or the
///   stream failed with an error [isCloseError] recognises as the close's.
///
/// An error that a stop or a close causes is not the turn's error: the text
/// ends there, cleanly, with what was generated — whether or not the source
/// ever ends (iOS sends no end after a cancelled generation) — and `end`
/// says why, so core's chat keeps the partial reply (and raises for a close,
/// decision H). Any other error stays on the text; `end` is then not read. A
/// turn that runs to its end reports [completed]. `end` completes after the
/// text has closed.
EngineTurn reportedEngineTurn(
  Stream<String> text, {
  required bool Function() stopped,
  required bool Function() closed,
  bool Function(Object error)? isCloseError,
  required TurnEnd completed,
}) {
  final end = Completer<TurnEnd>();

  // A session already closed when the turn starts fails it with its own
  // error; that is not a close during the turn.
  final closedAtStart = closed();
  bool closedNow() => !closedAtStart && closed();
  var closeSeen = false;
  TurnEnd how() => stopped()
      ? TurnEnd.stopped
      : closeSeen || closedNow()
      ? TurnEnd.closed
      : completed;

  StreamSubscription<String>? source;
  late final StreamController<String> out;
  var ending = false;

  /// Closes the text, then completes `end` with [how].
  Future<void> endAs(TurnEnd how) async {
    if (ending) return;
    ending = true;
    try {
      await out.close();
    } finally {
      if (!end.isCompleted) end.complete(how);
    }
  }

  out = StreamController<String>(
    onListen: () {
      source = text.listen(
        out.add,
        onError: (Object error, StackTrace stack) {
          if (isCloseError?.call(error) ?? false) {
            closeSeen = true;
          } else if (!stopped() && !closedNow()) {
            out.addError(error, stack);
            return;
          }
          // The stop's or the close's own error ends the turn here.
          unawaited(source?.cancel());
          unawaited(endAs(how()));
        },
        onDone: () => unawaited(endAs(how())),
      );
    },
    onPause: () => source?.pause(),
    onResume: () => source?.resume(),
    // Also runs once the text has delivered its done; only a cancel before
    // that is the consumer's stop.
    onCancel: () async {
      final stop = !ending;
      try {
        await source?.cancel();
      } finally {
        if (stop && !end.isCompleted) end.complete(TurnEnd.stopped);
      }
    },
  );
  return EngineTurn(text: out.stream, end: end.future);
}

/// What a LiteRT-LM 0.18 turn that ran to its end reports: a placeholder.
/// The runtime cannot tell a natural end from `maxOutputTokens`, nor a full
/// context in decode from either, so a session with a cap reports
/// [TurnEnd.outputLimit] (the safe side) and one without
/// [TurnEnd.endOfSequence]. Nothing reads it in core 2.6.0's plain turns;
/// an engine whose ends are guessed keeps `StructuredOutputSupport.none`.
// TODO(L2): read the native turn-end record (L1's
// litert_lm_conversation_get_last_turn_end) instead of guessing.
TurnEnd liteRtLmPlaceholderCompletedEnd(int? maxOutputTokens) =>
    maxOutputTokens == null ? TurnEnd.endOfSequence : TurnEnd.outputLimit;
