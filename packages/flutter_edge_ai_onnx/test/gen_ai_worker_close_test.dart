// Close, load-failure and death handling of the ORT-GenAI worker: the REAL
// `GenAiFfiClient`, the REAL worker loop (`serveGenAiWorker`) and the
// `OnnxInferenceModel` facade, with a scripted engine in place of the
// `dart:ffi` one (`test/fakes/fake_gen_ai_worker.dart`).
//
// The old shutdown waited five seconds for an ack and then killed the
// isolate. A prompt's prefill is one synchronous native call that can run
// longer than that on a CPU; the kill landed when it returned, before the
// worker freed anything, and the model, tokenizer and generator stayed
// resident for the life of the process. These tests read the engine's own
// log, written inside the worker, to see what actually ran there. A call the
// test must hold blocks on a gate the test opens (see the fake's header), so
// no test depends on how fast the machine is.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_worker.dart'
    show closedBeforeRunMessage;
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
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

/// Opens the gate of [log], letting the call it holds return.
void _release(File log) {
  final gate = File('${log.path}.release');
  if (!gate.existsSync()) gate.createSync();
}

ZoneSpecification _capturePrintsInto(List<String> printed) =>
    ZoneSpecification(print: (self, parent, zone, line) => printed.add(line));

/// Every line [body] — and everything it started — printed. The client
/// prints from callbacks registered while it loaded or shut down, so those
/// calls must happen inside [body].
Future<List<String>> _capturePrints(Future<void> Function() body) async {
  final printed = <String>[];
  await runZoned(body, zoneSpecification: _capturePrintsInto(printed));
  return printed;
}

Future<void> _waitForPrint(List<String> printed, String text) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!printed.any((l) => l.contains(text))) {
    if (DateTime.now().isAfter(deadline)) {
      fail('nothing printed "$text"; got: ${printed.join('\n')}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
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
const _shortNotice = Duration(milliseconds: 200);

final _closedBeforeRun = isA<StateError>().having(
  (e) => e.message,
  'message',
  closedBeforeRunMessage,
);

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('gen_ai_worker_close');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');

  /// A log whose gate is also opened in a teardown, so a test that fails
  /// before releasing it never leaves a worker blocked behind it.
  File gatedLog(String name) {
    final log = logFor(name);
    addTearDown(() => _release(log));
    return log;
  }

  String config(File log, [Map<String, Object> extra = const {}]) =>
      jsonEncode({'log': log.path, ...extra});

  Future<GenAiFfiClient> loaded(
    File log, {
    Map<String, Object> extra = const {},
    Duration slowLoadNotice = const Duration(seconds: 30),
    Duration slowCloseNotice = const Duration(seconds: 30),
  }) async {
    final client = GenAiFfiClient(
      workerEntry: fakeGenAiWorkerEntry,
      slowLoadNotice: slowLoadNotice,
      slowCloseNotice: slowCloseNotice,
    );
    await client.load(config(log, extra));
    return client;
  }

  OnnxInferenceModel modelOver(
    GenAiClient client, {
    void Function()? onClose,
  }) => OnnxInferenceModel(
    client: client,
    maxTokens: 1024,
    modelType: ModelType.gemmaIt,
    activeBackend: PreferredBackend.cpu,
    onClose: onClose ?? () {},
  );

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
    test('shutdown() never gives up on a prefill: held past 6 s, the engine is '
        'still closed before shutdown() returns, and the turn then ends '
        'normally', () async {
      // The old shutdown() gave up after 5 s and killed the worker, which
      // then never freed its model. Waiting is the whole fix, so pin it.
      final log = gatedLog('never_kill');
      final client = await loaded(log);
      final turn = _Turn(
        client.generate(_script({'chunks': _manyChunks, 'gate': true})),
      );
      await _waitForLine(log, 'generate');

      var returned = false;
      final shuttingDown = client.shutdown().whenComplete(
        () => returned = true,
      );
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(returned, isFalse, reason: 'shutdown() must still be waiting');
      expect(_linesOf(log), isNot(contains('close')));

      _release(log);
      await shuttingDown;
      expect(_linesOf(log), ['load', 'generate', 'close']);
      await turn.done;
      expect(turn.error, isNull, reason: 'a stopped turn ends normally');
      expect(turn.chunks, isEmpty, reason: 'it stopped before a token');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a reset queued behind the call in flight is answered without '
        'running once shutdown() is asked for', () async {
      final log = gatedLog('queued_reset');
      final client = await loaded(log);
      final turn = _Turn(client.generate(_script({'gateAtTail': true})));
      await _waitForLine(log, 'tail');

      // Both are sent while the turn is inside its last native call, in this
      // order; the release comes after them.
      final reset = client.resetSession();
      final shuttingDown = client.shutdown();
      _release(log);
      await shuttingDown;
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
    });

    test('a reset stops the turn in flight at its next token', () async {
      final log = logFor('reset_stops');
      final client = await loaded(log);
      try {
        final turn = _Turn(client.generate(_script({'untilStopped': true})));
        await _waitForLine(log, 'generate');
        await client.resetSession();
        await turn.done;
        expect(turn.error, isNull);
        expect(_linesOf(log), ['load', 'generate', 'reset']);
      } finally {
        await client.shutdown();
      }
    });

    test('a turn the worker had not started when shutdown() arrived gets the '
        "worker's own answer", () async {
      final log = gatedLog('queued_generate');
      final client = await loaded(log, extra: {'gateReset': true});
      await _Turn(client.generate(_script({'chunks': <String>[]}))).done;
      final reset = client.resetSession();
      await _waitForLine(log, 'reset');

      // The worker is inside the reset; this turn's request is filed behind
      // it. One event-loop turn here lets the request leave the mutex.
      final queued = _Turn(client.generate(_script({'chunks': <String>[]})));
      await Future<void>.delayed(Duration.zero);
      final shuttingDown = client.shutdown();
      _release(log);
      await shuttingDown;
      await reset.timeout(const Duration(seconds: 5));
      await queued.done;

      expect(
        queued.error,
        _closedBeforeRun,
        reason: "the worker's reply, not the client's safety net",
      );
      expect(_linesOf(log).where((l) => l == 'generate'), hasLength(1));
    });

    test('a token count the worker had not started when shutdown() arrived '
        "gets the worker's own answer", () async {
      final log = gatedLog('queued_count');
      final client = await loaded(log, extra: {'gateReset': true});
      final reset = client.resetSession();
      await _waitForLine(log, 'reset');

      final counted = client
          .countTokens('queued')
          .then<Object?>((count) => count, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      final shuttingDown = client.shutdown();
      _release(log);
      await shuttingDown;
      await reset.timeout(const Duration(seconds: 5));

      expect(await counted, _closedBeforeRun);
      expect(_linesOf(log), isNot(contains('count')));
    });

    test('a second shutdown() waits for the same teardown instead of '
        'returning early', () async {
      final log = gatedLog('concurrent_shutdown');
      final client = await loaded(log);
      final turn = _Turn(
        client.generate(_script({'chunks': _manyChunks, 'gate': true})),
      );
      await _waitForLine(log, 'generate');

      final first = client.shutdown();
      final second = client.shutdown();
      _release(log);
      await second;

      // Checked before the FIRST shutdown is awaited: a second shutdown()
      // that returned early would get here with nothing closed yet.
      expect(
        _linesOf(log).where((l) => l == 'close'),
        hasLength(1),
        reason: 'the second shutdown() returned before the engine was closed',
      );
      await first;
      await turn.done;
      expect(turn.error, isNull);
    });

    test('a native close that throws still lets shutdown() return, and the '
        'failure is reported with the model and the stack', () async {
      final log = logFor('throw_on_close');
      final printed = await _capturePrints(() async {
        final client = await loaded(log, extra: {'throwOnClose': true});
        await client.shutdown();
      });

      expect(_linesOf(log), ['load', 'close']);
      // Reported through the worker's own ack, not as a death: the throw was
      // caught in the worker, which still left the normal way.
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains(
            'failed to close; its native model may still be resident: '
            'Bad state: fake GenAI close blew up',
          ),
          contains('fake_gen_ai_worker.dart'),
          isNot(contains('exited')),
        ),
      );
    });

    test('shutdown() says once that it is still waiting when the call in '
        'flight outlasts the notice', () async {
      final log = gatedLog('slow_shutdown');
      final printed = <String>[];
      await runZoned(() async {
        final client = await loaded(log, slowCloseNotice: _shortNotice);
        final turn = _Turn(client.generate(_script({'gate': true})));
        await _waitForLine(log, 'generate');
        final shuttingDown = client.shutdown();
        await _waitForPrint(printed, 'has taken 200 ms');
        _release(log);
        await shuttingDown;
        await turn.done;
      }, zoneSpecification: _capturePrintsInto(printed));

      final notices = printed.where((l) => l.contains('has taken'));
      expect(notices, hasLength(1), reason: 'once, not on a timer');
      expect(
        notices.single,
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains('still inside a native call'),
        ),
      );
    });

    test('a quick load and a quick shutdown() say nothing', () async {
      final log = logFor('quick_shutdown');
      final printed = await _capturePrints(() async {
        final client = await loaded(
          log,
          slowLoadNotice: _shortNotice,
          slowCloseNotice: _shortNotice,
        );
        await client.shutdown();
        // Past both notices: a timer left running would fire by now.
        await Future<void>.delayed(_shortNotice * 3);
      });
      expect(printed.where((l) => l.contains('has taken')), isEmpty);
    });
  });

  group('GenAiFfiClient load', () {
    test('a load failure reports the error, then closes the engine', () async {
      final log = logFor('fail_load');
      await expectLater(
        loaded(log, extra: {'failLoad': true}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake GenAI engine refused to load'),
          ),
        ),
      );
      // The error is sent first, so the close is waited for, not assumed.
      await _waitForLine(log, 'close');
      expect(_linesOf(log), ['load', 'close']);
    });

    test('a failed load fails load() at once even while the close blocks, '
        'and that close still runs', () async {
      final log = gatedLog('fail_load_blocking_close');
      await expectLater(
        loaded(log, extra: {'failLoad': true, 'gateClose': true}).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('load() waited for the close'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake GenAI engine refused to load'),
          ),
        ),
      );
      expect(_linesOf(log), ['load'], reason: 'the close is still blocked');

      _release(log);
      await _waitForLine(log, 'close');
      expect(_linesOf(log), ['load', 'close']);
    });

    test('a close that fails after a failed load is reported with the model '
        'and the stack', () async {
      final log = gatedLog('fail_load_close_throws');
      final printed = <String>[];
      await runZoned(
        () => expectLater(
          loaded(
            log,
            extra: {'failLoad': true, 'gateClose': true, 'throwOnClose': true},
          ),
          throwsA(isA<StateError>()),
        ),
        zoneSpecification: _capturePrintsInto(printed),
      );

      _release(log);
      await _waitForPrint(printed, 'failed to close after its load failed');
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains('fake GenAI close blew up'),
          contains('fake_gen_ai_worker.dart'),
        ),
      );
    });

    test(
      'load() says once that it is taking long, and keeps waiting',
      () async {
        final log = gatedLog('slow_load');
        final printed = <String>[];
        late GenAiFfiClient client;
        await runZoned(() async {
          final loading = loaded(
            log,
            extra: {'gateLoad': true},
            slowLoadNotice: _shortNotice,
          );
          await _waitForPrint(printed, 'has taken 200 ms');
          _release(log);
          client = await loading;
        }, zoneSpecification: _capturePrintsInto(printed));

        final notices = printed.where((l) => l.contains('has taken'));
        expect(notices, hasLength(1), reason: 'once, not on a timer');
        expect(
          notices.single,
          allOf(
            contains('WARNING'),
            contains(log.path),
            contains('still inside a native call'),
          ),
        );
        await client.shutdown();
      },
    );
  });

  test(
    'a reset that fails is reported with the stack, not swallowed',
    () async {
      final log = logFor('reset_throws');
      final printed = await _capturePrints(() async {
        final client = await loaded(log, extra: {'throwOnReset': true});
        await client.resetSession();
        await client.shutdown();
      });
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains('may continue the previous conversation'),
          contains('fake generator reset blew up'),
          contains('fake_gen_ai_worker.dart'),
        ),
      );
    },
  );

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
          allOf(
            contains('WARNING'),
            contains('exited unexpectedly'),
            contains('may still be resident'),
          ),
        );
      },
    );

    test('an uncaught error in the worker, with its stack, is the reason the '
        'turn in flight and later calls fail with', () async {
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
        allOf(
          contains('exited unexpectedly'),
          contains('fake native crash'),
          contains('fake_gen_ai_worker.dart'),
        ),
      );
      expect(crashed.error, withReason);
      expect(later, withReason);
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('fake native crash'),
          contains('fake_gen_ai_worker.dart'),
        ),
      );
    });

    test('a serving loop that throws still closes the engine first, and the '
        'warning does not claim the model may be resident', () async {
      final log = logFor('loop_throws');
      late _Turn failed;
      final printed = await _capturePrints(() async {
        final client = await loaded(log);
        failed = _Turn(client.generate(_script({'throwUnprintable': true})));
        await failed.done;
        await client.shutdown().timeout(const Duration(seconds: 5));
      });

      expect(
        failed.error,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('exited unexpectedly'),
            contains('cannot describe itself'),
          ),
        ),
      );
      expect(_linesOf(log), ['load', 'generate', 'close']);
      final warning = printed.join('\n');
      expect(warning, contains('was freed before the worker ended'));
      expect(warning, isNot(contains('may still be resident')));
    });
  });

  group('OnnxInferenceModel', () {
    test('a worker that dies while idle closes the model: onClose and the '
        'close listeners run once, a later call fails with the reason, and '
        'close() does not run them again', () async {
      final log = logFor('model_death');
      var onCloseCalls = 0;
      var listenerCalls = 0;
      final listened = Completer<void>();
      late OnnxInferenceModel model;
      final printed = await _capturePrints(() async {
        final client = await loaded(log, extra: {'dieAfterMs': 100});
        model = modelOver(client, onClose: () => onCloseCalls++);
        model.addCloseListener(() {
          listenerCalls++;
          if (!listened.isCompleted) listened.complete();
        });
        await listened.future.timeout(const Duration(seconds: 10));
      });

      expect(listenerCalls, 1);
      expect(onCloseCalls, 1);
      await expectLater(
        model.createSession(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Model is closed because'),
              contains('exited unexpectedly'),
            ),
          ),
        ),
      );
      await model.close().timeout(const Duration(seconds: 5));
      expect(listenerCalls, 1, reason: 'close() after a death fires nothing');
      expect(onCloseCalls, 1);
      expect(printed.join('\n'), contains('exited unexpectedly'));
      expect(_linesOf(log), ['load'], reason: 'it died idle, before a close');
    });

    test('a caller that retries from its error handler finds the model '
        'already closed', () async {
      final log = logFor('model_retry');
      var listenerCalls = 0;
      int? listenerCallsWhenTheTurnFailed;
      await _capturePrints(() async {
        final client = await loaded(log);
        final model = modelOver(client);
        model.addCloseListener(() => listenerCalls++);
        final failed = Completer<void>();
        client
            .generate(_script({'kill': true}))
            .listen(
              (_) {},
              onError: (Object _) {
                listenerCallsWhenTheTurnFailed = listenerCalls;
                if (!failed.isCompleted) failed.complete();
              },
            );
        await failed.future.timeout(const Duration(seconds: 10));
      });
      expect(
        listenerCallsWhenTheTurnFailed,
        1,
        reason:
            'core drops its cached model on the listener; it must have run '
            'by the time the caller hears of the failure',
      );
    });

    test(
      'a session created while the worker dies fails with the reason',
      () async {
        final log = logFor('model_death_creating_session');
        late OnnxInferenceModel model;
        late Object? failure;
        await _capturePrints(() async {
          final client = await loaded(log, extra: {'killOnReset': true});
          model = modelOver(client);
          await model.createSession();
          // The second session closes the first, whose reset kills the worker.
          failure = await model.createSession().then<Object?>(
            (_) => null,
            onError: (Object e) => e,
          );
          await model.close().timeout(const Duration(seconds: 5));
        });
        expect(
          failure,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('closed while creating a session'),
              contains('exited unexpectedly'),
            ),
          ),
        );
      },
    );

    test(
      'a second close() waits for the teardown the first one started',
      () async {
        final log = gatedLog('model_second_close');
        final client = await loaded(log);
        final model = modelOver(client);
        final turn = _Turn(
          client.generate(_script({'chunks': _manyChunks, 'gate': true})),
        );
        await _waitForLine(log, 'generate');

        final first = model.close();
        final second = model.close();
        _release(log);
        await second;
        expect(
          _linesOf(log).where((l) => l == 'close'),
          hasLength(1),
          reason: 'the second close() returned before the engine was closed',
        );
        await first;
        await turn.done;
      },
    );

    test('a throwing onClose still fires the close listeners, and only the '
        'first close() reports it', () async {
      final log = logFor('model_throwing_on_close');
      var listenerCalls = 0;
      final client = await loaded(log);
      final model = modelOver(
        client,
        onClose: () => throw StateError('onClose failed'),
      );
      model.addCloseListener(() => listenerCalls++);

      await expectLater(
        model.close(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('onClose failed'),
          ),
        ),
      );
      expect(listenerCalls, 1, reason: 'core evicts on the listener');
      expect(_linesOf(log), contains('close'));
      await model.close();
      await model.close();
      expect(listenerCalls, 1);
    });
  });
}
