// Host tests for `stt_worker.dart`'s lifecycle: the worker loop, close and
// death handling, driven through a REAL isolate with a fake
// [SttWorkerEngine] injected via `SttWorker.spawn(engineFactory:)` — no
// native library is loaded.
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
import 'package:flutter_edge_ai_speech/src/litert/stt_worker.dart';
import 'package:flutter_edge_ai_speech/src/model/stt_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'worker_test_support.dart';

/// How the fake behaves; selected by the `<mode>@<log>` model path.
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
    if (_mode == _Mode.failLoad) {
      throw StateError('fake STT engine refused to load');
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
    return 'transcript of ${samples.length}';
  }

  @override
  void dispose() {
    _log('dispose');
    if (_mode == _Mode.throwOnDispose) {
      throw StateError('fake STT dispose blew up');
    }
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

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('stt_worker_test');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  File logFor(String name) => File('${tmpDir.path}/$name.log');

  Future<SttWorker> spawn(_Mode mode, File log) => SttWorker.spawn(
    modelPath: '${mode.name}@${log.path}',
    tokenizerPath: 'unused',
    profile: const SttModelProfile.whisper(),
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
    test('close() lets the request in flight finish, fails every queued one, '
        'disposes exactly once, and does not wait for the queue', () async {
      final log = logFor('queue');
      final worker = await spawn(_Mode.blocking, log);

      final inFlight = outcomeOf(worker.transcribe(_samples));
      final queued = [
        for (var i = 0; i < 20; i++) outcomeOf(worker.transcribe(_samples)),
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
        _transcript,
        reason: 'the request in flight finishes and gets its transcript',
      );
      for (final outcome in await Future.wait(queued)) {
        expect(outcome, closedBeforeRun('SttWorker'));
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

      final inFlight = outcomeOf(worker.transcribe(_samples));
      await waitForLine(log, 'run');
      await worker.close();

      expect(linesOf(log), ['load', 'run', 'dispose']);
      expect(await inFlight, _transcript);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('concurrent close() calls share one teardown', () async {
      final log = logFor('concurrent_close');
      final worker = await spawn(_Mode.blocking, log);
      final inFlight = outcomeOf(worker.transcribe(_samples));
      await waitForLine(log, 'run');

      await Future.wait([worker.close(), worker.close()]);
      await worker.close();

      expect(linesOf(log).where((l) => l == 'dispose'), hasLength(1));
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
            'Bad state: fake STT dispose blew up',
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
            contains('fake STT engine refused to load'),
          ),
        ),
      );
      // No polling: the worker disposes BEFORE it sends the error.
      expect(linesOf(log), ['load', 'dispose']);
    });
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
