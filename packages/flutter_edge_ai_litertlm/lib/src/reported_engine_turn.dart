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
/// ends cleanly with what was generated, and `end` says why, so core's chat
/// keeps the partial reply (and raises for a close, decision H). Any other
/// error stays on the text; `end` is then not read. A turn that runs to its
/// end reports [completed].
EngineTurn reportedEngineTurn(
  Stream<String> text, {
  required bool Function() stopped,
  required bool Function() closed,
  bool Function(Object error)? isCloseError,
  required TurnEnd completed,
}) {
  final end = Completer<TurnEnd>();
  void finish(TurnEnd how) {
    if (!end.isCompleted) end.complete(how);
  }

  // A session already closed when the turn starts fails it with its own
  // error; that is not a close during the turn.
  final closedAtStart = closed();
  bool closedNow() => !closedAtStart && closed();
  var closeSeen = false;
  StreamSubscription<String>? source;
  late final StreamController<String> out;
  out = StreamController<String>(
    onListen: () {
      source = text.listen(
        out.add,
        onError: (Object error, StackTrace stack) {
          if (isCloseError?.call(error) ?? false) {
            closeSeen = true;
            return;
          }
          if (stopped() || closedNow()) return;
          out.addError(error, stack);
        },
        onDone: () {
          finish(
            stopped()
                ? TurnEnd.stopped
                : closeSeen || closedNow()
                ? TurnEnd.closed
                : completed,
          );
          out.close();
        },
      );
    },
    onPause: () => source?.pause(),
    onResume: () => source?.resume(),
    onCancel: () async {
      await source?.cancel();
      finish(TurnEnd.stopped);
    },
  );
  return EngineTurn(text: out.stream, end: end.future);
}
