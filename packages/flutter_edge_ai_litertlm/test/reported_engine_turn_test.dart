import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/reported_engine_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<String> source;
  late bool stopped;
  late bool closed;
  late TurnEnd completed;

  setUp(() {
    source = StreamController<String>();
    stopped = false;
    closed = false;
    completed = TurnEnd.endOfSequence;
  });

  EngineTurn turn({bool Function(Object)? isCloseError}) => reportedEngineTurn(
    source.stream,
    stopped: () => stopped,
    closed: () => closed,
    isCloseError: isCloseError,
    completed: () => completed,
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

  test('what a completed turn reports is read when its text ends, not when '
      'it starts', () async {
    final t = turn();
    final text = t.text.toList();
    source.add('ok');
    // The engine's record of how the turn ended exists only now.
    completed = TurnEnd.outputLimit;
    await source.close();
    expect(await text, ['ok']);
    expect(await t.end, TurnEnd.outputLimit);
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

  test('an error with a known end ends the text cleanly with that end; a '
      'stop still wins', () async {
    EngineTurn known() => reportedEngineTurn(
      source.stream,
      stopped: () => stopped,
      closed: () => closed,
      endForError: (_) => TurnEnd.contextLimit,
      completed: () => completed,
    );
    var t = known();
    var text = t.text.toList();
    source.addError(Exception('RESOURCE_EXHAUSTED'));
    expect(await text, isEmpty);
    expect(await t.end, TurnEnd.contextLimit);

    source = StreamController<String>();
    t = known();
    text = t.text.toList();
    await pumpEventQueue();
    stopped = true;
    source.addError(Exception('CANCELLED'));
    expect(await text, isEmpty);
    expect(await t.end, TurnEnd.stopped);
  });
}
