import 'dart:async';

import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

void main() {
  late List<String> log;
  late NativeTurns<String> turns;

  setUp(() {
    log = [];
    turns = NativeTurns<String>(
      cancelNative: (c) => log.add('cancel $c'),
      deleteNative: (c) => log.add('delete $c'),
    );
  });

  group('NativeTurns', () {
    test('releasing an idle conversation cancels and deletes it at once: '
        'native may still be finishing a generation whose error already ended '
        'our turn', () {
      turns.release('a');
      expect(log, ['cancel a', 'delete a']);
    });

    test(
      'releasing a conversation with a running operation stops it and '
      'deletes it at its end, before anyone waiting on the end runs',
      () async {
        final turn = turns.begin('a');
        turns.release('a');
        expect(log, ['cancel a']);

        turn.ended.then((_) => log.add('waiter'));
        turns.end('a', turn, NativeTurnEnd.cancelled);
        expect(log, ['cancel a', 'delete a']);
        await pumpEventQueue();
        expect(log, ['cancel a', 'delete a', 'waiter']);
      },
    );

    test(
      'a delete that throws still ends the operation, so its lock goes',
      () async {
        final throwing = NativeTurns<String>(
          cancelNative: (_) {},
          deleteNative: (_) => throw StateError('native delete failed'),
        );
        final turn = throwing.begin('a');
        throwing.release('a');
        expect(
          () => throwing.end('a', turn, NativeTurnEnd.cancelled),
          throwsStateError,
        );
        expect(turn.hasEnded, isTrue);
      },
    );

    test('a second operation cannot begin while one runs', () {
      final turn = turns.begin('a');
      expect(() => turns.begin('a'), throwsStateError);
      turns.end('a', turn, NativeTurnEnd.completed);
      expect(turns.begin('a'), isNot(same(turn)));
    });

    test('allEnded waits for every running operation', () async {
      final a = turns.begin('a');
      final b = turns.begin('b');
      var done = false;
      turns.allEnded().then((_) => done = true);
      turns.end('a', a, NativeTurnEnd.completed);
      await pumpEventQueue();
      expect(done, isFalse);
      turns.end('b', b, NativeTurnEnd.failed);
      await pumpEventQueue();
      expect(done, isTrue);
    });
  });

  group('NativeTurnStream', () {
    test('chunks, then a natural end', () async {
      final send = NativeTurnStream(turns, 'a');
      final out = send.stream.toList();
      send
        ..chunk('Hel')
        ..chunk('')
        ..chunk('lo')
        ..finished();
      expect(await out, ['Hel', 'lo']);
      expect(await send.turn.ended, NativeTurnEnd.completed);
    });

    test(
      'a cancelled end that was asked for closes the stream cleanly',
      () async {
        final send = NativeTurnStream(turns, 'a');
        final out = send.stream.toList();
        send.chunk('Hi');
        turns.cancel('a');
        send.cancelled();
        expect(await out, ['Hi']);
      },
    );

    test('a conversation released mid-turn (session or model closed) ends the '
        'stream with done after the chunks that arrived: the consumer cannot '
        'tell it from a finished reply (B90, pending a decision)', () async {
      final send = NativeTurnStream(turns, 'a');
      final out = send.stream.toList();
      send
        ..chunk('The capital')
        ..chunk(' of France');
      // FfiConversationHandle.close() and shutdown() release the conversation.
      turns.release('a');
      expect(send.turn.cancelRequested, isTrue);
      expect(send.turn.deleteWhenEnded, isTrue);
      // Native answers the release's cancel with CANCELLED.
      send.cancelled();
      expect(await out, ['The capital', ' of France']);
      expect(await send.turn.ended, NativeTurnEnd.cancelled);
      expect(log, ['cancel a', 'delete a']);
    });

    test('a cancelled end that nobody asked for is an error: the conversation '
        'is poisoned', () async {
      final send = NativeTurnStream(turns, 'a');
      send.cancelled();
      await expectLater(
        send.stream.toList(),
        throwsA(isA<LiteRtLmTurnCancelledException>()),
      );
    });

    test('a chunk after a stop repeats the cancel', () {
      final send = NativeTurnStream(turns, 'a');
      send.stream.listen(null);
      turns.cancel('a');
      send.chunk('late');
      expect(log, ['cancel a', 'cancel a']);
    });

    test('a consumer that cancels waits for the native end', () async {
      final send = NativeTurnStream(turns, 'a');
      final sub = send.stream.listen(null);
      var cancelled = false;
      sub.cancel().then((_) => cancelled = true);
      expect(log, ['cancel a']);
      await pumpEventQueue();
      expect(cancelled, isFalse, reason: 'native has not ended yet');
      send.cancelled();
      await pumpEventQueue();
      expect(cancelled, isTrue);
    });

    test(
      'a consumer that cancels waits no longer than consumerCancelWait',
      () async {
        final send = NativeTurnStream(
          turns,
          'a',
          consumerCancelWait: const Duration(milliseconds: 50),
        );
        final sub = send.stream.listen(null);
        final printed = <String>[];
        await runZoned(
          () => sub.cancel().timeout(const Duration(seconds: 5)),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        );
        expect(send.turn.hasEnded, isFalse, reason: 'native still runs');
        expect(
          printed.single,
          contains('has not ended'),
          reason: 'release builds hear that the engine stays locked',
        );
      },
    );

    test(
      'the cancel that follows a natural end reaches nothing native',
      () async {
        final send = NativeTurnStream(turns, 'a');
        final out = send.stream.toList();
        send.finished();
        await out;
        expect(log, isEmpty);
      },
    );
  });

  group('heldUntilNativeEnd', () {
    late Mutex mutex;
    late NativeTurnStream<String> send;
    var starts = 0;

    Stream<String> run({Object? throwOnStart}) {
      starts = 0;
      return heldUntilNativeEnd(mutex, () {
        starts++;
        if (throwOnStart != null) throw throwOnStart;
        return send = NativeTurnStream(turns, 'a');
      });
    }

    setUp(() => mutex = Mutex());

    test(
      'the lock is held after the consumer cancels, until native ends',
      () async {
        final sub = run().listen(null);
        await pumpEventQueue();
        expect(mutex.isLocked, isTrue);

        final cancel = sub.cancel();
        await pumpEventQueue();
        expect(mutex.isLocked, isTrue, reason: 'native still runs');

        send.cancelled();
        await cancel;
        await pumpEventQueue();
        expect(mutex.isLocked, isFalse);
      },
    );

    test(
      'a paused consumer does not hold the lock past the native end',
      () async {
        final sub = run().listen(null);
        await pumpEventQueue();
        sub.pause();
        send
          ..chunk('x')
          ..finished();
        await pumpEventQueue();
        expect(mutex.isLocked, isFalse);
        await sub.cancel();
      },
    );

    test('a failed start releases the lock and reports the error', () async {
      await expectLater(
        run(throwOnStart: StateError('no proxy')).toList(),
        throwsStateError,
      );
      expect(mutex.isLocked, isFalse);
    });

    test('a consumer gone before the lock was taken starts nothing', () async {
      await mutex.acquire();
      final sub = run().listen(null);
      await pumpEventQueue();
      await sub.cancel();
      mutex.release();
      await pumpEventQueue();
      expect(starts, 0);
      expect(mutex.isLocked, isFalse);
    });

    test('the next operation waits for the previous native end', () async {
      final first = run().listen(null);
      await pumpEventQueue();
      final firstSend = send;
      unawaited(first.cancel());

      final second = run().toList();
      await pumpEventQueue();
      expect(starts, 0, reason: 'the second waits for the lock');

      firstSend.cancelled();
      await pumpEventQueue();
      expect(starts, 1);
      send.finished();
      expect(await second, isEmpty);
    });
  });
}
