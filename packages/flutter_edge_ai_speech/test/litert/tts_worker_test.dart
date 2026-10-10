// Host tests for `tts_worker.dart`'s lifecycle and the
// `LiteRtSpeechSynthesizer` facade over it: the worker loop, close, load
// failure and death handling, driven through a REAL isolate with a fake
// [TtsWorkerEngine] injected via `engineFactory` — no native library is
// loaded.
//
// Same regression as `tts_worker_test.dart`: the old close waited five
// seconds for an ack and then killed the isolate, so a close queued behind a
// voice reply's sentences never got there in time and the killed worker never
// disposed its TTS core. These tests read the fake engine's own log, written
// inside the worker, to see what actually ran there.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai_speech/src/litert/litert_speech_synthesizer.dart';
import 'package:flutter_edge_ai_speech/src/litert/tts_worker.dart';
import 'package:flutter_edge_ai_speech/src/model/tts_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'worker_test_support.dart';

/// How the fake behaves; selected by `artifactPaths['fake']`, `<mode>@<log>`.
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

class _FakeTtsEngine implements TtsWorkerEngine {
  _FakeTtsEngine(String config) {
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
        throw StateError('fake TTS engine refused to load');
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
  int get sampleRate => _fakeSampleRate;

  @override
  Uint8List synthesize(String text) {
    _log('run');
    if (text == 'fail') throw StateError('fake synthesis failed');
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
    return Uint8List.fromList(text.codeUnits);
  }

  @override
  void dispose() {
    switch (_mode) {
      case _Mode.failLoadThenBlockingDispose:
        blockUntilReleased(_logPath);
      case _Mode.failLoadThenDisposeThrows:
        blockUntilReleased(_logPath);
        _log('dispose');
        throw StateError('fake TTS dispose blew up');
      case _Mode.throwOnDispose:
        _log('dispose');
        throw StateError('fake TTS dispose blew up');
      default:
        break;
    }
    _log('dispose');
  }
}

TtsWorkerEngine _buildFake({
  required TtsModelProfile profile,
  required Map<String, String> artifactPaths,
  PreferredBackend? backend,
  required String language,
  Float32List? voice,
}) => _FakeTtsEngine(artifactPaths['fake']!);

const _fakeSampleRate = 22050;
const _text = 'hello';
final _pcm = Uint8List.fromList(_text.codeUnits);
const _shortNotice = Duration(milliseconds: 200);

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('tts_worker_test');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');
  File gated(String name) => gatedLog(tmpDir, name);

  Future<TtsWorker> spawn(
    _Mode mode,
    File log, {
    Duration slowLoadNotice = const Duration(seconds: 30),
    Duration slowCloseNotice = const Duration(seconds: 30),
  }) => TtsWorker.spawn(
    profile: const TtsModelProfile.matcha(),
    artifactPaths: {'fake': '${mode.name}@${log.path}'},
    engineFactory: _buildFake,
    slowLoadNotice: slowLoadNotice,
    slowCloseNotice: slowCloseNotice,
  );

  Future<LiteRtSpeechSynthesizer> synthesizer(
    _Mode mode,
    File log, {
    void Function()? onClose,
  }) => LiteRtSpeechSynthesizer.create(
    profile: const TtsModelProfile.matcha(),
    artifactPaths: {'fake': '${mode.name}@${log.path}'},
    onClose: onClose,
    engineFactory: _buildFake,
  );

  group('TtsWorker serving', () {
    test('learns the sample rate at load and serves concurrent requests '
        'correlated by id', () async {
      final worker = await spawn(_Mode.fast, logFor('serve'));
      try {
        expect(worker.sampleRate, _fakeSampleRate);
        final results = await Future.wait([
          worker.synthesize('a'),
          worker.synthesize('bb'),
          worker.synthesize('ccc'),
        ]);
        expect(results.map((pcm) => pcm.length), [1, 2, 3]);
      } finally {
        await worker.close();
      }
    });

    test('a failing request fails alone — the loop keeps serving', () async {
      final worker = await spawn(_Mode.fast, logFor('serve_errors'));
      try {
        await expectLater(
          worker.synthesize('fail'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('fake synthesis failed'),
            ),
          ),
        );
        expect(await worker.synthesize(_text), _pcm);
      } finally {
        await worker.close();
      }
    });
  });

  group('TtsWorker close never abandons the native model', () {
    test('close() lets the request in flight finish, the worker fails every '
        'queued one, and the model is disposed exactly once', () async {
      final log = gated('queue');
      final worker = await spawn(_Mode.blockingUntilReleased, log);

      final inFlight = outcomeOf(worker.synthesize(_text));
      final queued = [
        for (var i = 0; i < 20; i++) outcomeOf(worker.synthesize(_text)),
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
        _pcm,
        reason: 'the request in flight finishes and gets its PCM',
      );
      for (final outcome in await Future.wait(queued)) {
        expect(
          outcome,
          closedBeforeRun('TtsWorker'),
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
      final inFlight = outcomeOf(worker.synthesize(_text));
      await waitForLine(log, 'run');

      var returned = false;
      final closing = worker.close().whenComplete(() => returned = true);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(returned, isFalse, reason: 'close() must still be waiting');
      expect(linesOf(log), isNot(contains('dispose')));

      release(log);
      await closing;
      expect(linesOf(log), ['load', 'run', 'dispose']);
      expect(await inFlight, _pcm);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a second close() waits for the same teardown instead of returning '
        'early', () async {
      final log = gated('concurrent_close');
      final worker = await spawn(_Mode.blockingUntilReleased, log);
      final inFlight = outcomeOf(worker.synthesize(_text));
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
      expect(await inFlight, _pcm);
    });

    test(
      'synthesize() fails at once from the moment close() is called',
      () async {
        final log = logFor('synthesize_after_close');
        final worker = await spawn(_Mode.fast, log);

        final closing = worker.close();
        await expectLater(
          worker.synthesize(_text),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
        );
        await closing;
        await expectLater(worker.synthesize(_text), throwsA(isA<StateError>()));
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
          contains('matchaCfm TTS model in'),
          contains(
            'failed to dispose; its native model may still be resident: '
            'Bad state: fake TTS dispose blew up',
          ),
          contains('tts_worker_test.dart'),
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
        final inFlight = outcomeOf(worker.synthesize(_text));
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
          contains('matchaCfm TTS model in'),
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

  group('TtsWorker load', () {
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
              contains('fake TTS engine refused to load'),
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
            contains('fake TTS engine refused to load'),
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
          contains('matchaCfm TTS model in'),
          contains('fake TTS dispose blew up'),
          contains('tts_worker_test.dart'),
        ),
      );
    });

    test(
      'spawn says once that a load is taking long, and keeps waiting',
      () async {
        final log = gated('slow_load');
        final printed = <String>[];
        late TtsWorker worker;
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
            contains('matchaCfm TTS model in'),
            contains('still inside a native call'),
          ),
        );
        await worker.close();
      },
    );
  });

  group('TtsWorker unexpected death', () {
    test('a worker killed mid-request fails the request in flight and every '
        'queued one, warns, and refuses later calls with the reason', () async {
      final log = logFor('kill');
      late Object? killer;
      late Object? bystander;
      late Object? later;
      final printed = await capturePrints(() async {
        final worker = await spawn(_Mode.killOnRun, log);
        final killerFuture = outcomeOf(worker.synthesize(_text));
        final bystanderFuture = outcomeOf(worker.synthesize(_text));
        killer = await killerFuture.timeout(const Duration(seconds: 10));
        bystander = await bystanderFuture.timeout(const Duration(seconds: 10));
        later = await outcomeOf(worker.synthesize(_text));
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
        final firstFuture = outcomeOf(worker.synthesize(_text));
        final secondFuture = outcomeOf(worker.synthesize(_text));
        first = await firstFuture.timeout(const Duration(seconds: 10));
        second = await secondFuture.timeout(const Duration(seconds: 10));
        later = await outcomeOf(worker.synthesize(_text));
        await worker.close().timeout(const Duration(seconds: 5));
      });

      expect(first, _pcm, reason: 'it answered before the crash');
      final crashed = isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('exited unexpectedly'),
          contains('fake native crash'),
          contains('tts_worker_test.dart'),
        ),
      );
      expect(second, crashed);
      expect(later, crashed);
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('fake native crash'),
          contains('tts_worker_test.dart'),
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
          worker.synthesize(_text),
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

  group('LiteRtSpeechSynthesizer', () {
    test('a worker that dies while idle closes the synthesizer: onClose and '
        'the close listeners run once, a later call fails with the reason, '
        'and close() does not run them again', () async {
      final log = logFor('synthesizer_death');
      var onCloseCalls = 0;
      var listenerCalls = 0;
      final listened = Completer<void>();
      late LiteRtSpeechSynthesizer tts;
      final printed = await capturePrints(() async {
        tts = await synthesizer(
          _Mode.dieWhileIdle,
          log,
          onClose: () => onCloseCalls++,
        );
        tts.addCloseListener(() {
          listenerCalls++;
          if (!listened.isCompleted) listened.complete();
        });
        await listened.future.timeout(const Duration(seconds: 10));
      });

      expect(listenerCalls, 1);
      expect(onCloseCalls, 1);
      expect(
        () => tts.synthesize(_text),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('LiteRtSpeechSynthesizer is closed because'),
              contains('exited unexpectedly'),
            ),
          ),
        ),
      );
      await tts.close().timeout(const Duration(seconds: 5));
      expect(listenerCalls, 1, reason: 'close() after a death fires nothing');
      expect(onCloseCalls, 1);
      expect(printed.join('\n'), contains('exited unexpectedly'));
      expect(linesOf(log), ['load'], reason: 'it died idle, before a dispose');
    });

    test('a caller that retries from its error handler finds the synthesizer '
        'already closed', () async {
      final log = logFor('synthesizer_retry');
      var listenerCalls = 0;
      int? listenerCallsWhenTheCallFailed;
      await capturePrints(() async {
        final tts = await synthesizer(_Mode.killOnRun, log);
        tts.addCloseListener(() => listenerCalls++);
        await tts
            .synthesize(_text)
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
            'core drops its cached synthesizer on the listener; it must have '
            'run by the time the caller hears of the failure',
      );
    });

    test(
      'a second close() waits for the teardown the first one started',
      () async {
        final log = gated('synthesizer_second_close');
        final tts = await synthesizer(_Mode.blockingUntilReleased, log);
        final inFlight = outcomeOf(tts.synthesize(_text));
        await waitForLine(log, 'run');

        final first = tts.close();
        final second = tts.close();
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
      final log = logFor('synthesizer_throwing_on_close');
      var listenerCalls = 0;
      final tts = await synthesizer(
        _Mode.fast,
        log,
        onClose: () => throw StateError('onClose failed'),
      );
      tts.addCloseListener(() => listenerCalls++);

      await expectLater(
        tts.close(),
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
      await tts.close();
      await tts.close();
      expect(listenerCalls, 1);
    });
  });
}
