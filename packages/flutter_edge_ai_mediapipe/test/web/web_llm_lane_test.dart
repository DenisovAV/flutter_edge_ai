// The order of the calls that the sessions of one web model share.
import 'dart:async';

import 'package:flutter_edge_ai_mediapipe/src/web/web_llm_lane.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('a call starts only when the one queued before it has ended', () async {
    final lane = WebLlmLane();
    final first = Completer<String>();
    final started = <String>[];

    final a = lane.run(WebLlmCall(), () {
      started.add('a');
      return first.future;
    });
    final b = lane.run(WebLlmCall(), () async {
      started.add('b');
      return 'b';
    });
    await _settle();
    expect(started, ['a']);

    first.complete('a');
    expect(await a, 'a');
    expect(await b, 'b');
    expect(started, ['a', 'b']);
  });

  test('a call cancelled while it waits never starts, and the next one still '
      'waits for the call that runs', () async {
    final lane = WebLlmLane();
    final first = Completer<String>();
    final started = <String>[];
    final waiting = WebLlmCall();

    final a = lane.run(WebLlmCall(), () {
      started.add('a');
      return first.future;
    });
    final b = lane.run(waiting, () async {
      started.add('b');
      return 'b';
    });
    final c = lane.run(WebLlmCall(), () async {
      started.add('c');
      return 'c';
    });

    expect(lane.cancel(waiting), isFalse, reason: 'it is not in MediaPipe');
    // Returns at once, not when the call before it ends.
    expect(await b.timeout(const Duration(seconds: 1)), isNull);
    await _settle();
    expect(started, ['a'], reason: 'c must not start next to a');

    first.complete('a');
    expect(await a, 'a');
    expect(await c, 'c');
    expect(started, ['a', 'c']);
  });

  test('a call cancelled before it is queued never starts', () async {
    final lane = WebLlmLane();
    final call = WebLlmCall();
    lane.cancel(call);
    var started = false;
    expect(
      await lane.run(call, () async {
        started = true;
        return 'x';
      }),
      isNull,
    );
    expect(started, isFalse);
  });

  test('a running call is waited for as long as it runs', () async {
    final lane = WebLlmLane(stoppedCallWait: const Duration(milliseconds: 20));
    final first = Completer<String>();
    var secondStarted = false;

    final a = lane.run(WebLlmCall(), () => first.future);
    final b = lane.run(WebLlmCall(), () async {
      secondStarted = true;
      return 'b';
    });
    // Well past stoppedCallWait: another session's generation is not a
    // stopped call, and MediaPipe refuses a call next to it.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(secondStarted, isFalse);

    first.complete('a');
    await a;
    expect(await b, 'b');
  });

  test('a stopped call that does not end is let go of after '
      'stoppedCallWait', () async {
    final lane = WebLlmLane(stoppedCallWait: const Duration(milliseconds: 20));
    final running = WebLlmCall();
    var secondStarted = false;

    unawaited(lane.run(running, () => Completer<String>().future));
    await _settle();
    expect(lane.cancel(running), isTrue, reason: 'it is in MediaPipe');
    expect(lane.cancel(running), isFalse, reason: 'cancelled once');

    final b = lane.run(WebLlmCall(), () async {
      secondStarted = true;
      return 'b';
    });
    await _settle();
    expect(secondStarted, isFalse);
    expect(await b.timeout(const Duration(seconds: 1)), 'b');
  });

  test(
    'a cancel of a call that has ended asks MediaPipe for nothing',
    () async {
      final lane = WebLlmLane();
      final call = WebLlmCall();
      await lane.run(call, () async => 'done');
      expect(lane.cancel(call), isFalse);
    },
  );

  test('a failed call lets the next one start', () async {
    final lane = WebLlmLane();
    final a = lane.run<String>(WebLlmCall(), () async => throw StateError('x'));
    final b = lane.run(WebLlmCall(), () async => 'b');
    await expectLater(a, throwsStateError);
    expect(await b, 'b');
  });

  test('a wait past slowWaitWarning is told once, naming the call it '
      'waits for', () async {
    final warnings = <String>[];
    final lane = WebLlmLane(
      slowWaitWarning: const Duration(milliseconds: 20),
      warn: warnings.add,
    );
    final first = Completer<String>();
    unawaited(lane.run(WebLlmCall(owner: 'session 1'), () => first.future));
    final b = lane.run(WebLlmCall(owner: 'session 2'), () async => 'b');
    final c = lane.run(WebLlmCall(owner: 'session 3'), () async => 'c');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('session 2'));
    expect(warnings.single, contains('the call of session 1'));
    first.complete('a');
    await b;
    await c;
  });

  test('a wait that ends in time is not told', () async {
    final warnings = <String>[];
    final lane = WebLlmLane(
      slowWaitWarning: const Duration(milliseconds: 50),
      warn: warnings.add,
    );
    final first = Completer<String>();
    unawaited(lane.run(WebLlmCall(), () => first.future));
    final b = lane.run(WebLlmCall(), () async => 'b');
    first.complete('a');
    await b;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(warnings, isEmpty);
  });

  test('a stopped call let go of is told once', () async {
    final warnings = <String>[];
    final lane = WebLlmLane(
      stoppedCallWait: const Duration(milliseconds: 10),
      warn: warnings.add,
    );
    for (var i = 0; i < 2; i++) {
      final call = WebLlmCall(owner: 'session 1');
      unawaited(lane.run(call, () => Completer<String>().future));
      await _settle();
      lane.cancel(call);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('session 1'));
  });

  test('a call runs once', () async {
    final lane = WebLlmLane();
    final call = WebLlmCall();
    await lane.run(call, () async => 'a');
    await expectLater(
      lane.run(call, () async => 'b'),
      throwsA(isA<AssertionError>()),
    );
  });
}
