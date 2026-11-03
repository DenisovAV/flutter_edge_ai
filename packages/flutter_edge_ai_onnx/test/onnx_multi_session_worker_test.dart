// Independent sessions (#703) against the REAL `GenAiFfiClient` and the REAL
// worker loop, with a scripted engine whose per-session turn counter stands in
// for a KV cache (`test/fakes/fake_gen_ai_worker.dart`, `echoSession`). They
// pin what the fake client cannot: one session's stop or release must never
// cut off another session's turn in flight, and each session's context stays
// its own across interleaved turns.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_gen_ai_worker.dart';

List<String> _linesOf(File log) =>
    log.existsSync() ? log.readAsLinesSync() : const <String>[];

Future<void> _waitForLine(File log, String line) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!_linesOf(log).contains(line)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the worker never logged "$line"; it logged ${_linesOf(log)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

GenAiTurn _turn(
  int? session, {
  bool first = false,
  bool untilStopped = false,
}) => GenAiTurn(
  userContent: jsonEncode({
    'chunks': const ['x'],
    'echoSession': true,
    'untilStopped': untilStopped,
  }),
  sessionId: session,
  isFirstTurn: first,
);

/// Waits until [condition] holds, or fails.
Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<String> _run(GenAiClient client, GenAiTurn turn) async =>
    (await client.generate(turn).toList()).join();

void main() {
  late Directory tmp;
  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('multi_s'));
  tearDownAll(() => tmp.delete(recursive: true));

  Future<(GenAiFfiClient, File)> loaded(
    String name, {
    Map<String, Object?> extra = const {},
  }) async {
    final log = File('${tmp.path}/$name.log');
    final client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
    await client.load(jsonEncode({'log': log.path, ...extra}));
    addTearDown(client.shutdown);
    return (client, log);
  }

  test('interleaved turns keep each session\'s context separate', () async {
    final (client, _) = await loaded('interleave');

    expect(
      await _run(client, _turn(1, first: true)),
      startsWith('[session=1 turn=1]'),
    );
    expect(
      await _run(client, _turn(2, first: true)),
      startsWith('[session=2 turn=1]'),
    );
    expect(
      await _run(client, _turn(null, first: true)),
      startsWith('[session=null turn=1]'),
    );
    expect(await _run(client, _turn(1)), startsWith('[session=1 turn=2]'));
    expect(await _run(client, _turn(2)), startsWith('[session=2 turn=2]'));
    expect(await _run(client, _turn(1)), startsWith('[session=1 turn=3]'));
    expect(
      await _run(client, _turn(null)),
      startsWith('[session=null turn=2]'),
    );
  });

  test('stats are per session', () async {
    final (client, _) = await loaded('stats');
    await _run(client, _turn(1, first: true));
    await _run(client, _turn(2, first: true));

    expect(client.generationStatsOf(1), isNotNull);
    expect(client.generationStatsOf(2), isNotNull);
    expect(client.lastGenerationStats, isNull);

    await client.resetSession(sessionId: 1);
    expect(client.generationStatsOf(1), isNull);

    // The legacy session starts clean after a reset, as an opened one does.
    await _run(client, _turn(null, first: true));
    expect(client.lastGenerationStats, isNotNull);
    await client.resetSession();
    expect(client.lastGenerationStats, isNull);
    expect(client.generationStatsOf(2), isNotNull);
  });

  test('a stop for session A leaves the turn of session B running', () async {
    final (client, log) = await loaded('stop');
    final b = <String>[];
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen(b.add, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    await client.stopGeneration(sessionId: 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bDone, isFalse, reason: 'B was stopped by a stop meant for A');
    expect(_linesOf(log), isNot(contains('stopped')));

    await client.stopGeneration(sessionId: 2);
    await _waitForLine(log, 'stopped');
    await _until(() => bDone, 'B to end after its own stop');
  });

  test('releasing session A while B runs neither cuts B nor frees B\'s '
      'generator, and A\'s generator is gone afterwards', () async {
    final (client, log) = await loaded('release');
    await _run(client, _turn(1, first: true));
    final b = <String>[];
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen(b.add, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    final released = client.resetSession(sessionId: 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bDone, isFalse, reason: 'B was stopped by the release of A');
    // The release is served after B's turn, so it is still queued.
    expect(_linesOf(log), isNot(contains('reset:1')));

    await client.stopGeneration(sessionId: 2);
    await released;
    await _waitForLine(log, 'reset:1');
    await _until(() => bDone, 'B to end after its own stop');
    expect(_linesOf(log), isNot(contains('reset:2')));

    // A released session's id is never served again; a new session starts
    // clean and B's context is still there.
    await expectLater(
      _run(client, _turn(1, first: true)),
      throwsA(isA<StateError>()),
    );
    expect(
      await _run(client, _turn(3, first: true)),
      startsWith('[session=3 turn=1]'),
    );
    expect(await _run(client, _turn(2)), startsWith('[session=2 turn=2]'));
  });

  test(
    'a stop for the legacy session does not stop an opened session',
    () async {
      final (client, log) = await loaded('legacy');
      var done = false;
      client
          .generate(_turn(3, first: true, untilStopped: true))
          .listen((_) {}, onDone: () => done = true);
      await _waitForLine(log, 'generate:3');

      await client.stopGeneration();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(done, isFalse);

      await client.stopGeneration(sessionId: 3);
      await _waitForLine(log, 'stopped');
    },
  );

  test('two resets in flight each get their own ack', () async {
    final (client, log) = await loaded('acks');
    await _run(client, _turn(1, first: true));
    await _run(client, _turn(2, first: true));

    // resetSession gives up waiting for an ack after 5 s without saying so,
    // so a lost ack shows only as a slow call: both must return well before.
    final sw = Stopwatch()..start();
    await Future.wait([
      client.resetSession(sessionId: 1),
      client.resetSession(sessionId: 2),
    ]);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));

    expect(_linesOf(log), containsAll(['reset:1', 'reset:2']));
  });

  test('a session released while its turn waits behind another session\'s '
      'never builds a generator', () async {
    final (client, log) = await loaded('parked_release');
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen((_) {}, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    // A's turn parks on the client's lock behind B's.
    final a = client.generate(_turn(1, first: true)).toList();
    final aErrors = expectLater(a, throwsA(isA<StateError>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.stopGeneration(sessionId: 1);
    final released = client.resetSession(sessionId: 1);

    await client.stopGeneration(sessionId: 2);
    await _until(() => bDone, 'B to end');
    await released;
    // Stopped and released, as OnnxSession.close does: the waiting caller is
    // told, it does not get an empty reply that looks like success.
    await aErrors;
    expect(_linesOf(log), isNot(contains('generate:1')));
  });

  test('a session released without a stop, while its turn waits, errors and '
      'never builds a generator', () async {
    final (client, log) = await loaded('parked_release_only');
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen((_) {}, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    final a = client.generate(_turn(1, first: true)).toList();
    final aErrors = expectLater(a, throwsA(isA<StateError>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final released = client.resetSession(sessionId: 1);

    await client.stopGeneration(sessionId: 2);
    await _until(() => bDone, 'B to end');
    await released;
    await aErrors;
    expect(_linesOf(log), isNot(contains('generate:1')));
  });

  test('a turn waiting behind another session\'s errors when the worker dies, '
      'not an empty reply', () async {
    final (client, log) = await loaded(
      'parked_death',
      extra: {'dieAfterMs': 600},
    );
    final b = client
        .generate(_turn(2, first: true, untilStopped: true))
        .toList();
    await _waitForLine(log, 'generate:2');
    final a = client.generate(_turn(1, first: true)).toList();
    final bFailed = expectLater(b, throwsA(isA<StateError>()));
    await bFailed;
    // As the model does on a dead worker: stop, then release, then A wakes.
    await client.stopGeneration(sessionId: 1);
    await client.resetSession(sessionId: 1);
    await expectLater(
      a,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('exited unexpectedly'),
        ),
      ),
    );
  });

  test(
    'stats do not come back when the session was reset during its turn',
    () async {
      final (client, log) = await loaded('stats_after_reset');
      var done = false;
      client
          .generate(_turn(1, first: true, untilStopped: true))
          .listen((_) {}, onDone: () => done = true);
      await _waitForLine(log, 'generate:1');
      await client.resetSession(sessionId: 1);
      await _until(() => done, 'the turn to end');
      expect(client.generationStatsOf(1), isNull);
    },
  );

  test('a stream cancelled while its turn waits behind another session\'s '
      'never reaches the worker', () async {
    final (client, log) = await loaded('parked_cancel');
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen((_) {}, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    final sub = client.generate(_turn(1, first: true)).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    await client.stopGeneration(sessionId: 2);
    await _until(() => bDone, 'B to end');
    // The lock is free again and A's turn never ran.
    expect(await _run(client, _turn(3, first: true)), startsWith('[session=3'));
    expect(_linesOf(log), isNot(contains('generate:1')));
  });

  test('a stop filed while the turn waits behind another session\'s ends it '
      'without running', () async {
    final (client, log) = await loaded('parked_stop');
    var bDone = false;
    client
        .generate(_turn(2, first: true, untilStopped: true))
        .listen((_) {}, onDone: () => bDone = true);
    await _waitForLine(log, 'generate:2');

    final a = client.generate(_turn(1, first: true)).toList();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.stopGeneration(sessionId: 1);

    await client.stopGeneration(sessionId: 2);
    await _until(() => bDone, 'B to end');
    expect(await a, isEmpty);
    expect(_linesOf(log), isNot(contains('generate:1')));
  });
}
