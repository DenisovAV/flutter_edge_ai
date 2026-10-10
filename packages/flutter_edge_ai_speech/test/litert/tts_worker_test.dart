// Host tests for `tts_worker.dart`'s lifecycle: the worker loop, close and
// death handling, driven through a REAL isolate with a fake
// [TtsWorkerEngine] injected via `TtsWorker.spawn(engineFactory:)` — no
// native library is loaded.
//
// Same regression as `stt_worker_test.dart`: the old close waited five
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
import 'package:flutter_edge_ai_speech/src/litert/tts_worker.dart';
import 'package:flutter_edge_ai_speech/src/model/tts_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'worker_test_support.dart';

/// How the fake behaves; selected by `artifactPaths['fake']`, `<mode>@<log>`.
enum _Mode {
  /// Every call returns at once.
  fast,

  /// Every call blocks the isolate for [_slowCall], like a synchronous FFI
  /// forward pass: nothing — a close included — is delivered until it returns.
  blocking,

  /// Every call blocks for [_longerThanOldCap], longer than the five seconds
  /// the old close waited before it killed the worker.
  blockingPastOldCap,

  /// `load` throws after it "allocated" something.
  failLoad,

  /// `dispose` throws.
  throwOnDispose,

  /// The first call kills the worker isolate from inside, like a crash.
  killOnRun,

  /// The first call answers, then an uncaught error takes the isolate down.
  crashAfterRun,
}

const _slowCall = Duration(milliseconds: 800);
const _longerThanOldCap = Duration(seconds: 6);
const _fakeSampleRate = 22050;

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
    if (_mode == _Mode.failLoad) {
      throw StateError('fake TTS engine refused to load');
    }
  }

  @override
  int get sampleRate => _fakeSampleRate;

  @override
  Uint8List synthesize(String text) {
    _log('run');
    if (text == 'fail') throw StateError('fake synthesis failed');
    switch (_mode) {
      case _Mode.blocking:
        sleep(_slowCall);
      case _Mode.blockingPastOldCap:
        sleep(_longerThanOldCap);
      case _Mode.killOnRun:
        Isolate.current.kill(priority: Isolate.immediate);
      case _Mode.crashAfterRun:
        scheduleMicrotask(() => throw StateError('fake native crash'));
      case _Mode.fast:
      case _Mode.failLoad:
      case _Mode.throwOnDispose:
        break;
    }
    return Uint8List.fromList(text.codeUnits);
  }

  @override
  void dispose() {
    _log('dispose');
    if (_mode == _Mode.throwOnDispose) {
      throw StateError('fake TTS dispose blew up');
    }
  }
}

TtsWorkerEngine _buildFake({
  required TtsModelProfile profile,
  required Map<String, String> artifactPaths,
  PreferredBackend? backend,
  required String language,
  Float32List? voice,
}) => _FakeTtsEngine(artifactPaths['fake']!);

const _text = 'hello';
final _pcm = Uint8List.fromList(_text.codeUnits);

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('tts_worker_test');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');

  Future<TtsWorker> spawn(_Mode mode, File log) => TtsWorker.spawn(
    profile: const TtsModelProfile.matcha(),
    artifactPaths: {'fake': '${mode.name}@${log.path}'},
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
    test('close() lets the request in flight finish, fails every queued one, '
        'disposes exactly once, and does not wait for the queue', () async {
      final log = logFor('queue');
      final worker = await spawn(_Mode.blocking, log);

      final inFlight = outcomeOf(worker.synthesize(_text));
      final queued = [
        for (var i = 0; i < 20; i++) outcomeOf(worker.synthesize(_text)),
      ];
      await waitForLine(log, 'run');

      final stopwatch = Stopwatch()..start();
      await worker.close();
      stopwatch.stop();

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
        expect(outcome, closedBeforeRun('TtsWorker'));
      }
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 4)),
        reason:
            'twenty queued 800 ms requests are 16 s of work; close waits for '
            'the one in flight, not for the queue',
      );
    });

    test('close() waits for a call in flight longer than the old five-second '
        'cap instead of killing the worker', () async {
      final log = logFor('past_old_cap');
      final worker = await spawn(_Mode.blockingPastOldCap, log);

      final inFlight = outcomeOf(worker.synthesize(_text));
      await waitForLine(log, 'run');
      await worker.close();

      expect(linesOf(log), ['load', 'run', 'dispose']);
      expect(await inFlight, _pcm);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('concurrent close() calls share one teardown', () async {
      final log = logFor('concurrent_close');
      final worker = await spawn(_Mode.blocking, log);
      final inFlight = outcomeOf(worker.synthesize(_text));
      await waitForLine(log, 'run');

      await Future.wait([worker.close(), worker.close()]);
      await worker.close();

      expect(linesOf(log).where((l) => l == 'dispose'), hasLength(1));
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
        'is reported', () async {
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
          contains(
            'failed to dispose; its native model may still be resident: '
            'Bad state: fake TTS dispose blew up',
          ),
          isNot(contains('exited')),
        ),
      );
    });

    test('a load failure disposes the engine before the error reaches the '
        'caller', () async {
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
      // No polling: the worker disposes BEFORE it sends the error.
      expect(linesOf(log), ['load', 'dispose']);
    });
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
        allOf(contains('WARNING'), contains('exited unexpectedly')),
      );
    });

    test('an uncaught error in the worker is the reason pending and later '
        'requests fail with', () async {
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
        allOf(contains('exited unexpectedly'), contains('fake native crash')),
      );
      expect(second, crashed);
      expect(later, crashed);
      expect(
        printed.join('\n'),
        allOf(contains('WARNING'), contains('fake native crash')),
      );
      expect(linesOf(log).where((l) => l == 'run'), hasLength(1));
    });
  });
}
