// The inline host's per-request yield on the page (MessageChannel, R5 §4.5 as
// decided in R5_adjustments 2026-10-11): it must not pay the browser's >= 4 ms
// clamp on nested zero timers, and it must still let a close() that a timer
// (or an input event) schedules overtake the queue — a microtask-only yield
// would serve the whole queue first.
//
// "Overtake" is W2's requirement as it holds on a page: the close completes
// before the LAST queued request starts. Not before the very next one — the
// timer and the yield's messages are different task sources, which the event
// loop does not order against each other, so a few requests may start after
// the timer was due. The test asserts the first and only prints the second.
//
// Mutation checks for whoever runs this: replace the body of
// `yieldToEventLoop` in lib/src/embedding/event_loop_yield_web.dart with
// `Future<void>.value()` → the overtake test goes red; with
// `Future<void>.delayed(Duration.zero)` → the cost test goes red.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/inline_host_web_yield_test.dart
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/event_loop_yield_web.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request at once, and records which ones it started.
final class _InstantPass extends EmbeddingPass {
  final started = <String>[];

  @override
  Future<EmbeddingPassInfo> load() async =>
      const EmbeddingPassInfo(dimension: 4);

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) {
    started.add(input.text!);
    return Future.value(List<double>.filled(4, 0.0));
  }

  @override
  Future<void> close() async {}
}

final _passes = <_InstantPass>[];

EmbeddingPass _buildInstantPass(String _) {
  final pass = _InstantPass();
  _passes.add(pass);
  return pass;
}

void main() {
  test('200 yields stay far below the 4 ms-per-turn timer clamp', () async {
    const count = 200;
    final watch = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await yieldToEventLoop();
    }
    watch.stop();
    // ignore: avoid_print
    print('[web yield] $count MessageChannel yields: ${watch.elapsed}');
    // The clamp alone would be >= 800 ms; a MessageChannel hop is tens of
    // microseconds. Half the clamp leaves room for a slow VM.
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 400)));
  });

  test('a close scheduled by a timer overtakes the queue: it completes before '
      'the last queued request starts, and what had not started fails as '
      'closed', () async {
    final host = await startEmbeddingHost(
      const EmbeddingPassDescriptor<String>(
        engineTag: 'Instant',
        factory: _buildInstantPass,
        config: 'instant',
        activeBackend: null,
      ),
      declaredMedia: const {},
      label: 'web-yield',
    );
    final model = CommonEmbeddingModel.withHost(host, engine: 'Instant');
    final pass = _passes.single;
    const count = 500;
    final last = 't${count - 1}';
    // Filed all at once (plain embed(), not embedAll, which keeps only two
    // outstanding), so the whole queue sits behind the close.
    final results = [
      for (var i = 0; i < count; i++)
        model
            .embed(EmbeddingInput.text('t$i'), taskType: TaskType.none)
            .then<Object?>((v) => v, onError: (Object e) => e),
    ];
    final closing = Completer<void>();
    var startedWhenTimerRan = -1;
    var startedWhenClosed = -1;
    Timer.run(() {
      startedWhenTimerRan = pass.started.length;
      model.close().then((_) {
        startedWhenClosed = pass.started.length;
        closing.complete();
      });
    });

    final outcomes = await Future.wait(results);
    await closing.future;

    final closed = outcomes.whereType<EmbedderClosedException>().length;
    final served = outcomes.whereType<List<double>>().length;
    // ignore: avoid_print
    print(
      '[web yield] $startedWhenTimerRan of $count requests had started when '
      'the timer ran, $startedWhenClosed when the close completed; $served '
      'served, $closed failed as closed',
    );
    // W2 on a page: the close completed before the LAST queued request
    // started — that one never ran, and nothing started after the close.
    expect(
      pass.started,
      isNot(contains(last)),
      reason:
          'the whole queue ran before the close: the yield never let the '
          'timer through',
    );
    expect(outcomes.last, isA<EmbedderClosedException>());
    expect(pass.started, hasLength(startedWhenClosed));
    // Everything ended either served or closed, in queue order.
    expect(served + closed, count, reason: 'nothing failed any other way');
    expect(pass.started, [for (var i = 0; i < served; i++) 't$i']);
    // Deliberately NOT asserted: startedWhenClosed == startedWhenTimerRan + 1.
    // The yield's messages and the timer are different task sources, so a few
    // more requests may start between the timer being due and it running.
  });
}
