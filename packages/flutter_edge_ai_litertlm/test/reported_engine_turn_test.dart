import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/reported_engine_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<String> source;
  late bool stopped;
  late bool closed;

  setUp(() {
    source = StreamController<String>();
    stopped = false;
    closed = false;
  });

  EngineTurn turn({bool Function(Object)? isCloseError}) => reportedEngineTurn(
    source.stream,
    stopped: () => stopped,
    closed: () => closed,
    isCloseError: isCloseError,
    completed: TurnEnd.endOfSequence,
  );

  test('a stop\'s own error ends the text cleanly although the source never '
      'ends, and end is stopped', () async {
    final t = turn();
    final text = t.text.toList();
    source.add('Par');
    await pumpEventQueue();
    stopped = true;
    source.addError(StateError('cancelled'));
    expect(await text.timeout(const Duration(seconds: 5)), ['Par']);
    expect(await t.end, TurnEnd.stopped);
    expect(source.hasListener, isFalse, reason: 'the source is let go');
  });

  test('a close\'s own error ends the turn as closed', () async {
    final t = turn(isCloseError: (e) => e is UnsupportedError);
    final text = t.text.toList();
    source
      ..add('Par')
      ..addError(UnsupportedError('closed'));
    expect(await text, ['Par']);
    expect(await t.end, TurnEnd.closed);
  });

  test('any other error is the turn\'s', () async {
    final t = turn();
    final text = t.text.toList();
    source.addError(StateError('decode failed'));
    await expectLater(text, throwsStateError);
  });

  test(
    'a session already closed at the start fails with its own error',
    () async {
      closed = true;
      final t = turn();
      final text = t.text.toList();
      source.addError(StateError('Session is closed'));
      await expectLater(text, throwsStateError);
    },
  );

  test('a cancelled subscription is a stop', () async {
    final t = turn();
    final sub = t.text.listen(null);
    source.add('Par');
    await pumpEventQueue();
    await sub.cancel();
    expect(await t.end, TurnEnd.stopped);
  });

  test('end completes after the text has closed', () async {
    final t = turn();
    final order = <String>[];
    final done = Completer<void>();
    t.text.listen(
      null,
      onDone: () {
        order.add('text done');
        done.complete();
      },
    );
    unawaited(t.end!.then((_) => order.add('end')));
    await source.close();
    await done.future;
    await t.end;
    await pumpEventQueue();
    expect(order, ['text done', 'end']);
    expect(await t.end, TurnEnd.endOfSequence);
  });
}
