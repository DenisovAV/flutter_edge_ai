import 'dart:async';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/benchmark_peak_sampler.dart';

const _tick = Duration(milliseconds: 5);

/// Lets the sampler run until [reads] reads have been requested.
Future<void> _until(int Function() reads, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (reads() < count) {
    if (DateTime.now().isAfter(deadline)) fail('sampler never reached $count');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test('reports the highest value read, not the last one', () async {
    final values = [10, 90, 40, 20];
    var calls = 0;
    final sampler = PeakSampler(
      read: () async => values[calls++ % values.length],
      interval: _tick,
    )..start();
    await _until(() => calls, 4);
    final reading = await sampler.stop();

    expect(reading.bytes, 90);
    expect(reading.samples, greaterThanOrEqualTo(4));
    expect(reading.failures, 0);
    expect(reading.firstFailure, isNull);
  });

  test('boundary readings count toward the peak but not as samples', () async {
    final sampler = PeakSampler(read: () async => 5, interval: _tick)
      ..observe(100)
      ..observe(null);
    final reading = await sampler.stop(last: 70);

    expect(reading.bytes, 100);
    expect(reading.samples, 0, reason: 'never started: no periodic reads');
  });

  test('a boundary reading higher than any sample wins', () async {
    var calls = 0;
    final sampler = PeakSampler(
      read: () async {
        calls++;
        return 10;
      },
      interval: _tick,
    )..start();
    await _until(() => calls, 2);

    expect((await sampler.stop(last: 500)).bytes, 500);
  });

  test('a failed read is counted and the first message kept', () async {
    var calls = 0;
    final sampler = PeakSampler(
      read: () async {
        calls++;
        if (calls <= 2) throw MemoryReadException('read #$calls failed');
        return 7;
      },
      interval: _tick,
    )..start();
    await _until(() => calls, 4);
    final reading = await sampler.stop();

    expect(reading.failures, 2);
    expect(reading.firstFailure, contains('read #1 failed'));
    expect(reading.bytes, 7, reason: 'later reads still count');
    expect(reading.samples, greaterThanOrEqualTo(2));
    expect(
      reading.samples + reading.failures,
      calls,
      reason: 'every read is a sample or a failure, nothing in between',
    );
  });

  test('nothing readable gives a null peak, not zero', () async {
    var calls = 0;
    final sampler = PeakSampler(
      read: () async {
        calls++;
        return null;
      },
      interval: _tick,
    )..start();
    await _until(() => calls, 2);
    final reading = await sampler.stop();

    expect(reading.bytes, isNull);
    expect(reading.failures, 0);
    expect(reading.samples, 0, reason: 'a null read is not a sample');
    expect(reading.readMs, isNull);
  });

  test('read time covers the successful reads only', () async {
    var calls = 0;
    final sampler = PeakSampler(
      read: () async {
        calls++;
        if (calls == 1) throw MemoryReadException('slow and failed');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 1;
      },
      interval: _tick,
    )..start();
    await _until(() => calls, 3);
    final reading = await sampler.stop();

    expect(reading.intervalMs, _tick.inMilliseconds);
    expect(reading.readMs!.mean, greaterThanOrEqualTo(15));
    expect(reading.readMs!.max, greaterThanOrEqualTo(15));
    expect(reading.readMs!.max, greaterThanOrEqualTo(reading.readMs!.mean));
  });

  test('a zero interval switches the sampler off', () async {
    var calls = 0;
    final sampler =
        PeakSampler(
            read: () async {
              calls++;
              return 1;
            },
            interval: Duration.zero,
          )
          ..observe(42)
          ..start();
    await Future<void>.delayed(_tick * 6);
    final reading = await sampler.stop(last: 10);

    expect(calls, 0);
    expect(reading.bytes, 42);
    expect(reading.samples, 0);
    expect(reading.intervalMs, isNull);
    expect(reading.readMs, isNull);
  });

  test(
    'cancel stops reads and hides an error from the read in flight',
    () async {
      final release = Completer<void>();
      var calls = 0;
      final sampler = PeakSampler(
        read: () async {
          calls++;
          await release.future;
          throw StateError('bug in the reader');
        },
        interval: _tick,
      )..start();
      await _until(() => calls, 1);

      final cancelling = sampler.cancel();
      release.complete();
      await cancelling; // must not throw
      final atCancel = calls;
      await Future<void>.delayed(_tick * 6);
      expect(calls, atCancel);
    },
  );

  test('a slow read makes ticks skip instead of piling up', () async {
    var started = 0;
    final release = Completer<void>();
    final sampler = PeakSampler(
      read: () async {
        started++;
        await release.future;
        return 1;
      },
      interval: _tick,
    )..start();
    await Future<void>.delayed(_tick * 8);
    expect(started, 1, reason: 'one read in flight, later ticks skipped');

    release.complete();
    final reading = await sampler.stop();
    expect(reading.samples, 1);
  });

  test('stop waits for a read already in flight', () async {
    final release = Completer<void>();
    var started = 0;
    final sampler = PeakSampler(
      read: () async {
        started++;
        await release.future;
        return 999;
      },
      interval: _tick,
    )..start();
    await _until(() => started, 1);

    final stopping = sampler.stop();
    var done = false;
    unawaited(stopping.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse, reason: 'stop() must not return mid-read');

    release.complete();
    expect((await stopping).bytes, 999);
  });

  test('no reads happen after stop', () async {
    var calls = 0;
    final sampler = PeakSampler(
      read: () async {
        calls++;
        return 1;
      },
      interval: _tick,
    )..start();
    await _until(() => calls, 2);
    await sampler.stop();
    final atStop = calls;
    await Future<void>.delayed(_tick * 6);

    expect(calls, atStop);
  });

  test('an unexpected exception surfaces instead of being swallowed', () async {
    final surfaced = <Object>[];
    await runZonedGuarded(() async {
      final sampler = PeakSampler(
        read: () async => throw StateError('a bug, not a failed read'),
        interval: _tick,
      )..start();
      await Future<void>.delayed(_tick * 4);
      try {
        await sampler.stop();
      } catch (e) {
        surfaced.add(e);
      }
    }, (e, _) => surfaced.add(e));

    expect(surfaced, isNotEmpty);
    expect(surfaced.first, isA<StateError>());
  });
}
