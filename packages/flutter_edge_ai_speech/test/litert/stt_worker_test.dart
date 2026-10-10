// Host tests for `stt_worker.dart`'s lifecycle and the
// `LiteRtSpeechRecognizer` facade over it: the worker loop, close, load
// failure and death handling, driven through a REAL isolate with a fake
// [SttWorkerEngine] injected via `engineFactory` — no native library is
// loaded.
//
// The old close waited five seconds for an ack and then killed the isolate.
// The worker served its port one `await for` turn at a time, so a close
// queued behind a batch of transcriptions never got there in time — and a
// killed isolate never ran `SttCore.dispose()`, leaving the compiled model
// resident for the life of the process. These tests read the fake engine's
// own log, written inside the worker, to see what actually ran there.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai_speech/src/litert/litert_speech_recognizer.dart';
import 'package:flutter_edge_ai_speech/src/litert/stt_worker.dart';
import 'package:flutter_edge_ai_speech/src/model/stt_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'worker_test_support.dart';

/// How the fake behaves; selected by the `<mode>@<log>` model path.
enum _Mode {
  /// Every call returns at once.
  fast,

  /// Every call blocks the isolate until the test releases the gate, like a
  /// synchronous FFI forward pass: nothing — a close included — is delivered
  /// until it returns.
  blockingUntilReleased,

  /// `load` blocks until the gate is released.
  blockingLoad,

  /// `load` throws; `dispose` returns.
  failLoad,

  /// `load` throws; `dispose` blocks until the gate is released.
  failLoadThenBlockingDispose,

  /// `load` throws; `dispose` waits for the gate, then throws.
  failLoadThenDisposeThrows,

  /// `dispose` throws.
  throwOnDispose,

  /// The first call kills the worker isolate from inside, like a crash.
  killOnRun,

  /// The first call answers, then an uncaught error takes the isolate down.
  crashAfterRun,

  /// A call throws an error whose `toString` throws, so serving it fails and
  /// the serving loop itself throws.
  unprintableOnRun,

  /// The isolate kills itself shortly after load, with nothing in flight.
  dieWhileIdle,
}

class _FakeSttEngine implements SttWorkerEngine {
  _FakeSttEngine(String config) {
    final (mode, logPath) = parseFakeConfig(config);
    _mode = _Mode.values.byName(mode);
    _logPath = logPath;
  }

  late final _Mode _mode;
  late final String? _logPath;

  void _log(String line) => appendLogLine(_logPath, line);

  @override
  Future<void> load() async {
    _log('load');
    switch (_mode) {
      case _Mode.failLoad:
      case _Mode.failLoadThenBlockingDispose:
      case _Mode.failLoadThenDisposeThrows:
        throw StateError('fake STT engine refused to load');
      case _Mode.blockingLoad:
        blockUntilReleased(_logPath);
      case _Mode.dieWhileIdle:
        Timer(
          const Duration(milliseconds: 100),
          () => Isolate.current.kill(priority: Isolate.immediate),
        );
      case _Mode.fast:
      case _Mode.blockingUntilReleased:
      case _Mode.throwOnDispose:
      case _Mode.killOnRun:
      case _Mode.crashAfterRun:
      case _Mode.unprintableOnRun:
        break;
    }
  }

  @override
  String transcribe(Float32List samples, {String? language}) {
    _log('run');
    switch (language) {
      case 'fail':
        throw StateError('fake transcription failed');
      case 'zz':
        throw ArgumentError.value('zz', 'language', 'not a whisper language');
    }
    switch (_mode) {
      case _Mode.blockingUntilReleased:
        blockUntilReleased(_logPath);
      case _Mode.killOnRun:
        Isolate.current.kill(priority: Isolate.immediate);
      case _Mode.crashAfterRun:
        scheduleMicrotask(() => throw StateError('fake native crash'));
      case _Mode.unprintableOnRun:
        throw UnprintableError();
      case _Mode.fast:
      case _Mode.blockingLoad:
      case _Mode.failLoad:
      case _Mode.failLoadThenBlockingDispose:
      case _Mode.failLoadThenDisposeThrows:
      case _Mode.throwOnDispose:
      case _Mode.dieWhileIdle:
        break;
    }
    return 'transcript of ${samples.length}';
  }

  @override
  void dispose() {
    switch (_mode) {
      case _Mode.failLoadThenBlockingDispose:
        blockUntilReleased(_logPath);
      case _Mode.failLoadThenDisposeThrows:
        blockUntilReleased(_logPath);
        _log('dispose');
        throw StateError('fake STT dispose blew up');
      case _Mode.throwOnDispose:
        _log('dispose');
        throw StateError('fake STT dispose blew up');
      default:
        break;
    }
    _log('dispose');
  }
}

SttWorkerEngine _buildFake({
  required String modelPath,
  required String tokenizerPath,
  required SttModelProfile profile,
  PreferredBackend? backend,
}) => _FakeSttEngine(modelPath);

final _samples = Float32List(16);
const _transcript = 'transcript of 16';
const _shortNotice = Duration(milliseconds: 200);

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('stt_worker_test');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');
  File gated(String name) => gatedLog(tmpDir, name);

  Future<SttWorker> spawn(
    _Mode mode,
    File log, {
    Duration slowLoadNotice = const Duration(seconds: 30),
    Duration slowCloseNotice = const Duration(seconds: 30),
  }) => SttWorker.spawn(
    modelPath: '${mode.name}@${log.path}',
    tokenizerPath: 'unused',
    profile: const SttModelProfile.whisper(),
    engineFactory: _buildFake,
    slowLoadNotice: slowLoadNotice,
    slowCloseNotice: slowCloseNotice,
  );

  Future<LiteRtSpeechRecognizer> recognizer(
    _Mode mode,
    File log, {
    void Function()? onClose,
  }) => LiteRtSpeechRecognizer.create(
    profile: const SttModelProfile.whisper(),
    modelPath: '${mode.name}@${log.path}',
    tokenizerPath: 'unused',
    onClose: onClose,
    engineFactory: _buildFake,
  );

  group('SttWorker serving', () {
    test('serves concurrent requests correlated by id', () async {
      final worker = await spawn(_Mode.fast, logFor('serve'));
      try {
        final results = await Future.wait([
          worker.transcribe(Float32List(1)),
          worker.transcribe(Float32List(2)),
          worker.transcribe(Float32List(3)),
        ]);
        expect(results, [
          'transcript of 1',
          'transcript of 2',
          'transcript of 3',
        ]);
      } finally {
        await worker.close();
      }
    });

    test('a failing request fails alone — the loop keeps serving, and an '
        'ArgumentError comes back as one', () async {
      final worker = await spawn(_Mode.fast, logFor('serve_errors'));
      try {
        await expectLater(
          worker.transcribe(_samples, language: 'fail'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('fake transcription failed'),
            ),
          ),
        );
        await expectLater(
          worker.transcribe(_samples, language: 'zz'),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'language')
                .having((e) => e.invalidValue, 'invalidValue', 'zz'),
          ),
        );
        expect(await worker.transcribe(_samples), _transcript);
      } finally {
        await worker.close();
      }
    });
  });

  group('SttWorker close never abandons the native model', () {
    test('close() lets the request in flight finish, the worker fails every '
        'queued one, and the model is disposed exactly once', () async {
      final log = gated('queue');
      final worker = await spawn(_Mode.blockingUntilReleased, log);

      final inFlight = outcomeOf(worker.transcribe(_samples));
      final queued = [
        for (var i = 0; i < 20; i++) outcomeOf(worker.transcribe(_samples)),
      ];
      await waitForLine(log, 'run');

      // The close is sent synchronously inside close(), so it is in the
      // worker's queue before the run is released: the order is fixed here,
      // not by how fast this machine is.
      final closing = worker.close();
      release(log);
      await closing;

      // Read the moment close() returns, without polling: close() waits for
      // the worker's own teardown, so the line is already on disk — and a
      // worker that was killed never writes it at all.
      final lines = linesOf(log);
      expect(
        lines.where((l) => l == 'dispose'),
        hasLength(1),
        reason: 'the model must be disposed, once, before close() returns',
      );
      expect(
        lines.where((l) => l == 'run'),
        hasLength(1),
        reason: 'nothing queued may start once a close has been asked for',
      );
      expect(
        await inFlight,
        _transcript,
        reason: 'the request in flight finishes and gets its transcript',
      );
      for (final outcome in await Future.wait(queued)) {
        expect(
          outcome,
          closedBeforeRun('SttWorker'),
          reason: "the worker's own answer, not the main side's net",
        );
      }
    });

    test('close() never gives up on the call in flight: held past 6 s, the '
        'model is still disposed before close() returns', () async {
      // The old close() gave up after 5 s and killed the worker, which then
      // never disposed its model. Waiting is the whole fix, so pin it.
      final log = gated('never_kill');
      final worker = await spawn(_Mode.blockingUntilReleased, log);
      final inFlight = outcomeOf(worker.transcribe(_samples));
      await waitForLine(log, 'run');

      var returned = false;
      final closing = worker.close().whenComplete(() => returned = true);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(returned, isFalse, reason: 'close() must still be waiting');
      expect(linesOf(log), isNot(contains('dispose')));

      release(log);
      await closing;
      expect(linesOf(log), ['load', 'run', 'dispose']);
      expect(await inFlight, _transcript);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a second close() waits for the same teardown instead of returning '
        'early', () async {
      final log = gated('concurrent_close');
      final worker = await spawn(_Mode.blockingUntilReleased, log);
      final inFlight = outcomeOf(worker.transcribe(_samples));
      await waitForLine(log, 'run');

      final first = worker.close();
      final second = worker.close();
      release(log);
      await second;

      // Checked before the FIRST close is awaited: a second close() that
      // returned early would get here while the worker is still running,
      // with nothing disposed yet.
      expect(
        linesOf(log).where((l) => l == 'dispose'),
        hasLength(1),
        reason: 'the second close() returned before the model was disposed',
      );
      await first;
      expect(await inFlight, _transcript);
    });

    test(
      'transcribe() fails at once from the moment close() is called',
      () async {
        final log = logFor('transcribe_after_close');
        final worker = await spawn(_Mode.fast, log);

        final closing = worker.close();
        await expectLater(
          worker.transcribe(_samples),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
        );
        await closing;
        await expectLater(
          worker.transcribe(_samples),
          throwsA(isA<StateError>()),
        );
        expect(linesOf(log), ['load', 'dispose']);
      },
    );

    test('a dispose that throws still lets close() return, and the failure '
        'is reported with the model and the stack', () async {
      final log = logFor('throw_on_dispose');
      final printed = await capturePrints(() async {
        final worker = await spawn(_Mode.throwOnDispose, log);
        await worker.close();
      });

      expect(linesOf(log), ['load', 'dispose']);
      // Reported through the worker's own ack, not as a death: the throw was
      // caught in the worker, which still left the normal way.
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains(
            'failed to dispose; its native model may still be resident: '
            'Bad state: fake STT dispose blew up',
          ),
          contains('stt_worker_test.dart'),
          isNot(contains('exited')),
        ),
      );
    });

    test('close() says once that it is still waiting when the call in flight '
        'outlasts the notice', () async {
      final log = gated('slow_close');
      final printed = <String>[];
      await runZoned(() async {
        final worker = await spawn(
          _Mode.blockingUntilReleased,
          log,
          slowCloseNotice: _shortNotice,
        );
        final inFlight = outcomeOf(worker.transcribe(_samples));
        await waitForLine(log, 'run');
        final closing = worker.close();
        await waitForPrint(printed, 'has taken 200 ms');
        release(log);
        await closing;
        await inFlight;
      }, zoneSpecification: capturePrintsInto(printed));

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

    test('a quick load and a quick close() say nothing', () async {
      final log = logFor('quick_close');
      final printed = await capturePrints(() async {
        final worker = await spawn(
          _Mode.fast,
          log,
          slowLoadNotice: _shortNotice,
          slowCloseNotice: _shortNotice,
        );
        await worker.close();
        // Past both notices: a timer left running would fire by now.
        await Future<void>.delayed(_shortNotice * 3);
      });
      expect(printed.where((l) => l.contains('has taken')), isEmpty);
    });
  });

  group('SttWorker load', () {
    test(
      'a load failure reports the error, then disposes the engine',
      () async {
        final log = logFor('fail_load');
        await expectLater(
          spawn(_Mode.failLoad, log),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('fake STT engine refused to load'),
            ),
          ),
        );
        // The error is sent first, so the dispose is waited for, not assumed.
        await waitForLine(log, 'dispose');
        expect(linesOf(log), ['load', 'dispose']);
      },
    );

    test('a failed load fails spawn at once even while the dispose blocks, '
        'and that dispose still runs', () async {
      final log = gated('fail_load_blocking_dispose');
      await expectLater(
        spawn(_Mode.failLoadThenBlockingDispose, log).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('spawn waited for the dispose'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake STT engine refused to load'),
          ),
        ),
      );
      expect(linesOf(log), ['load'], reason: 'the dispose is still blocked');

      release(log);
      await waitForLine(log, 'dispose');
      expect(linesOf(log), ['load', 'dispose']);
    });

    test('a dispose that fails after a failed load is reported with the '
        'model and the stack', () async {
      final log = gated('fail_load_dispose_throws');
      final printed = <String>[];
      await runZoned(
        () => expectLater(
          spawn(_Mode.failLoadThenDisposeThrows, log),
          throwsA(isA<StateError>()),
        ),
        zoneSpecification: capturePrintsInto(printed),
      );

      release(log);
      await waitForPrint(printed, 'failed to dispose after its load failed');
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains('fake STT dispose blew up'),
          contains('stt_worker_test.dart'),
        ),
      );
    });

    test(
      'spawn says once that a load is taking long, and keeps waiting',
      () async {
        final log = gated('slow_load');
        final printed = <String>[];
        late SttWorker worker;
        await runZoned(() async {
          final spawning = spawn(
            _Mode.blockingLoad,
            log,
            slowLoadNotice: _shortNotice,
          );
          await waitForPrint(printed, 'has taken 200 ms');
          release(log);
          worker = await spawning;
        }, zoneSpecification: capturePrintsInto(printed));

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
        await worker.close();
      },
    );
  });

  group('SttWorker unexpected death', () {
    test('a worker killed mid-request fails the request in flight and every '
        'queued one, warns, and refuses later calls with the reason', () async {
      final log = logFor('kill');
      late Object? killer;
      late Object? bystander;
      late Object? later;
      final printed = await capturePrints(() async {
        final worker = await spawn(_Mode.killOnRun, log);
        final killerFuture = outcomeOf(worker.transcribe(_samples));
        final bystanderFuture = outcomeOf(worker.transcribe(_samples));
        killer = await killerFuture.timeout(const Duration(seconds: 10));
        bystander = await bystanderFuture.timeout(const Duration(seconds: 10));
        later = await outcomeOf(worker.transcribe(_samples));
        await worker.close().timeout(const Duration(seconds: 5));
      });

      final exitedUnexpectedly = isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('exited unexpectedly'),
      );
      expect(killer, exitedUnexpectedly);
      expect(bystander, exitedUnexpectedly);
      expect(
        later,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('closed'), contains('exited unexpectedly')),
        ),
      );
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('exited unexpectedly'),
          contains('may still be resident'),
        ),
      );
    });

    test('an uncaught error in the worker, with its stack, is the reason '
        'pending and later requests fail with', () async {
      final log = logFor('crash');
      late Object? first;
      late Object? second;
      late Object? later;
      final printed = await capturePrints(() async {
        final worker = await spawn(_Mode.crashAfterRun, log);
        final firstFuture = outcomeOf(worker.transcribe(_samples));
        final secondFuture = outcomeOf(worker.transcribe(_samples));
        first = await firstFuture.timeout(const Duration(seconds: 10));
        second = await secondFuture.timeout(const Duration(seconds: 10));
        later = await outcomeOf(worker.transcribe(_samples));
        await worker.close().timeout(const Duration(seconds: 5));
      });

      expect(first, _transcript, reason: 'it answered before the crash');
      final crashed = isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('exited unexpectedly'),
          contains('fake native crash'),
          contains('stt_worker_test.dart'),
        ),
      );
      expect(second, crashed);
      expect(later, crashed);
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('fake native crash'),
          contains('stt_worker_test.dart'),
        ),
      );
      expect(linesOf(log).where((l) => l == 'run'), hasLength(1));
    });

    test('a serving loop that throws still disposes the model first, and the '
        'warning does not claim it may be resident', () async {
      final log = logFor('loop_throws');
      late Object? failed;
      final printed = await capturePrints(() async {
        final worker = await spawn(_Mode.unprintableOnRun, log);
        failed = await outcomeOf(
          worker.transcribe(_samples),
        ).timeout(const Duration(seconds: 10));
        await worker.close().timeout(const Duration(seconds: 5));
      });

      expect(
        failed,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('exited unexpectedly'),
            contains('cannot describe itself'),
          ),
        ),
      );
      expect(linesOf(log), ['load', 'run', 'dispose']);
      final warning = printed.join('\n');
      expect(warning, contains('was disposed before the worker ended'));
      expect(warning, isNot(contains('may still be resident')));
    });
  });

  group('LiteRtSpeechRecognizer', () {
    test('a worker that dies while idle closes the recognizer: onClose and '
        'the close listeners run once, a later call fails with the reason, '
        'and close() does not run them again', () async {
      final log = logFor('recognizer_death');
      var onCloseCalls = 0;
      var listenerCalls = 0;
      final listened = Completer<void>();
      late LiteRtSpeechRecognizer stt;
      final printed = await capturePrints(() async {
        stt = await recognizer(
          _Mode.dieWhileIdle,
          log,
          onClose: () => onCloseCalls++,
        );
        stt.addCloseListener(() {
          listenerCalls++;
          if (!listened.isCompleted) listened.complete();
        });
        await listened.future.timeout(const Duration(seconds: 10));
      });

      expect(listenerCalls, 1);
      expect(onCloseCalls, 1);
      expect(
        () => stt.transcribe(Uint8List(32)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('LiteRtSpeechRecognizer is closed because'),
              contains('exited unexpectedly'),
            ),
          ),
        ),
      );
      await stt.close().timeout(const Duration(seconds: 5));
      expect(listenerCalls, 1, reason: 'close() after a death fires nothing');
      expect(onCloseCalls, 1);
      expect(printed.join('\n'), contains('exited unexpectedly'));
      expect(linesOf(log), ['load'], reason: 'it died idle, before a dispose');
    });

    test('a caller that retries from its error handler finds the recognizer '
        'already closed', () async {
      final log = logFor('recognizer_retry');
      var listenerCalls = 0;
      int? listenerCallsWhenTheCallFailed;
      await capturePrints(() async {
        final stt = await recognizer(_Mode.killOnRun, log);
        stt.addCloseListener(() => listenerCalls++);
        await stt
            .transcribe(Uint8List(32))
            .then<void>(
              (_) => fail('the call should have failed'),
              onError: (Object _) =>
                  listenerCallsWhenTheCallFailed = listenerCalls,
            )
            .timeout(const Duration(seconds: 10));
      });
      expect(
        listenerCallsWhenTheCallFailed,
        1,
        reason:
            'core drops its cached recognizer on the listener; it must have '
            'run by the time the caller hears of the failure',
      );
    });

    test(
      'a second close() waits for the teardown the first one started',
      () async {
        final log = gated('recognizer_second_close');
        final stt = await recognizer(_Mode.blockingUntilReleased, log);
        final inFlight = outcomeOf(stt.transcribe(Uint8List(32)));
        await waitForLine(log, 'run');

        final first = stt.close();
        final second = stt.close();
        release(log);
        await second;
        expect(
          linesOf(log).where((l) => l == 'dispose'),
          hasLength(1),
          reason: 'the second close() returned before the model was disposed',
        );
        await first;
        await inFlight;
      },
    );

    test('a throwing onClose still fires the close listeners, and only the '
        'first close() reports it', () async {
      final log = logFor('recognizer_throwing_on_close');
      var listenerCalls = 0;
      final stt = await recognizer(
        _Mode.fast,
        log,
        onClose: () => throw StateError('onClose failed'),
      );
      stt.addCloseListener(() => listenerCalls++);

      await expectLater(
        stt.close(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('onClose failed'),
          ),
        ),
      );
      expect(listenerCalls, 1, reason: 'core evicts on the listener');
      expect(linesOf(log), contains('dispose'));
      await stt.close();
      await stt.close();
      expect(listenerCalls, 1);
    });
  });
}
