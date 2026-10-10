// Close and death handling of the ORT-GenAI worker: the REAL `GenAiFfiClient`
// and the REAL worker loop (`serveGenAiWorker`), with a scripted engine in
// place of the `dart:ffi` one (`test/fakes/fake_gen_ai_worker.dart`).
//
// The old shutdown waited five seconds for an ack and then killed the
// isolate. A prompt's prefill is one synchronous native call that can run
// longer than that on a CPU; the kill landed when it returned, before the
// worker freed anything, and the model, tokenizer and generator stayed
// resident for the life of the process. These tests read the engine's own
// log, written inside the worker, to see what actually ran there.
import 'dart:async';
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
      fail('the worker never logged "$line"');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Every line [body] — and everything it started — printed. The client
/// prints from callbacks registered while it loaded, so `load` must happen
/// inside [body].
Future<List<String>> _capturePrints(Future<void> Function() body) async {
  final printed = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => printed.add(line),
    ),
  );
  return printed;
}

/// One generate() call's observable outcome.
class _Turn {
  _Turn(Stream<String> stream) {
    stream.listen(
      chunks.add,
      onError: (Object e) => error = e,
      onDone: _done.complete,
    );
  }

  final chunks = <String>[];
  Object? error;
  final _done = Completer<void>();
  Future<void> get done => _done.future.timeout(const Duration(seconds: 10));
}

GenAiTurn _script(Map<String, Object> script) =>
    GenAiTurn(userContent: jsonEncode(script));

final _manyChunks = [for (var i = 0; i < 50; i++) 'c$i'];

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('gen_ai_worker_close');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');

  Future<GenAiFfiClient> loaded(
    File log, {
    bool failLoad = false,
    bool throwOnClose = false,
  }) async {
    final client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
    await client.load(
      jsonEncode({
        'log': log.path,
        'failLoad': failLoad,
        'throwOnClose': throwOnClose,
      }),
    );
    return client;
  }

  test('a turn that fails fails alone — the worker keeps serving', () async {
    final log = logFor('serve_errors');
    final client = await loaded(log);
    try {
      final failed = _Turn(client.generate(_script({'throw': true})));
      await failed.done;
      expect(
        failed.error,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('fake generation failed'),
        ),
      );
      final next = _Turn(
        client.generate(
          _script({
            'chunks': ['still', ' ', 'serving'],
          }),
        ),
      );
      await next.done;
      expect(next.error, isNull);
      expect(next.chunks.join(), 'still serving');
    } finally {
      await client.shutdown();
    }
  });

  group('GenAiFfiClient.shutdown never abandons the native model', () {
    test('shutdown() waits for a prefill longer than the old five-second cap '
        'instead of killing the worker; the turn then stops at its next token '
        'and ends normally, and the engine is closed once', () async {
      final log = logFor('past_old_cap');
      final client = await loaded(log);
      final turn = _Turn(
        client.generate(_script({'chunks': _manyChunks, 'blockMs': 6000})),
      );
      await _waitForLine(log, 'generate');

      await client.shutdown();

      // Read the moment shutdown() returns, without polling: it waits for
      // the worker's own teardown, so the line is already on disk — and a
      // worker that was killed never writes it at all.
      expect(_linesOf(log), ['load', 'generate', 'close']);
      await turn.done;
      expect(turn.error, isNull, reason: 'a stopped turn ends normally');
      expect(turn.chunks, isEmpty, reason: 'it stopped before a token');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a request queued behind the call in flight is answered without '
        'running once shutdown() is asked for', () async {
      final log = logFor('queued_reset');
      final client = await loaded(log);
      final turn = _Turn(
        client.generate(
          _script({'chunks': _manyChunks, 'delayMs': 10, 'tailBlockMs': 800}),
        ),
      );
      await _waitForLine(log, 'generate');

      // Queued behind the turn; it stops the turn at its next token, and the
      // turn then spends 800 ms in its last native call.
      final reset = client.resetSession();
      await _waitForLine(log, 'tail');
      await client.shutdown();
      await reset.timeout(const Duration(seconds: 5));
      await turn.done;

      expect(
        _linesOf(log),
        ['load', 'generate', 'tail', 'close'],
        reason:
            'the reset had not started when the shutdown arrived, so it is '
            'answered without running; the close runs once',
      );
      expect(turn.error, isNull);
      expect(turn.chunks.length, lessThan(_manyChunks.length));
    });

    test('concurrent shutdown() calls share one teardown', () async {
      final log = logFor('concurrent_shutdown');
      final client = await loaded(log);
      final turn = _Turn(
        client.generate(_script({'chunks': _manyChunks, 'delayMs': 10})),
      );
      await _waitForLine(log, 'generate');

      await Future.wait([client.shutdown(), client.shutdown()]);
      await client.shutdown();

      expect(_linesOf(log).where((l) => l == 'close'), hasLength(1));
      await turn.done;
      expect(turn.error, isNull);
    });

    test('a native close that throws still lets shutdown() return, and the '
        'failure is reported', () async {
      final log = logFor('throw_on_close');
      final printed = await _capturePrints(() async {
        final client = await loaded(log, throwOnClose: true);
        await client.shutdown();
      });

      expect(_linesOf(log), ['load', 'close']);
      // Reported through the worker's own ack, not as a death: the throw was
      // caught in the worker, which still left the normal way.
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(
            'failed to close; its native model may still be resident: '
            'Bad state: fake GenAI close blew up',
          ),
          isNot(contains('exited')),
        ),
      );
    });

    test('a load failure closes the engine before the error reaches the '
        'caller', () async {
      final log = logFor('fail_load');
      await expectLater(
        loaded(log, failLoad: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake GenAI engine refused to load'),
          ),
        ),
      );
      // No polling: the worker closes the engine BEFORE it sends the error.
      expect(_linesOf(log), ['load', 'close']);
    });
  });

  group('GenAiFfiClient unexpected worker death', () {
    test(
      'a killed worker warns and refuses later calls with the reason',
      () async {
        final log = logFor('kill');
        late _Turn killer;
        late Object? laterGenerate;
        late Object? laterCount;
        final printed = await _capturePrints(() async {
          final client = await loaded(log);
          killer = _Turn(client.generate(_script({'kill': true})));
          await killer.done;
          final later = _Turn(
            client.generate(
              _script({
                'chunks': ['x'],
              }),
            ),
          );
          await later.done;
          laterGenerate = later.error;
          try {
            await client.countTokens('later');
          } on StateError catch (e) {
            laterCount = e;
          }
          await client.shutdown().timeout(const Duration(seconds: 5));
        });

        final exited = isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('exited unexpectedly'),
        );
        expect(killer.error, exited);
        final refused = isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('closed'), contains('exited unexpectedly')),
        );
        expect(laterGenerate, refused);
        expect(laterCount, refused);
        expect(
          printed.join('\n'),
          allOf(contains('WARNING'), contains('exited unexpectedly')),
        );
      },
    );

    test('an uncaught error in the worker is the reason the turn in flight and '
        'later calls fail with', () async {
      final log = logFor('crash');
      late _Turn crashed;
      late Object? later;
      final printed = await _capturePrints(() async {
        final client = await loaded(log);
        crashed = _Turn(
          client.generate(
            _script({
              'chunks': ['a'],
              'crash': true,
            }),
          ),
        );
        await crashed.done;
        final next = _Turn(
          client.generate(
            _script({
              'chunks': ['x'],
            }),
          ),
        );
        await next.done;
        later = next.error;
        await client.shutdown().timeout(const Duration(seconds: 5));
      });

      final withReason = isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(contains('exited unexpectedly'), contains('fake native crash')),
      );
      expect(crashed.error, withReason);
      expect(later, withReason);
      expect(
        printed.join('\n'),
        allOf(contains('WARNING'), contains('fake native crash')),
      );
    });
  });
}
