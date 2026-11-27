// Engine.createSession on a real model (opt-in): what a cancel and the
// engine's close do to a session.
//
//   GEMMA4_E2B_LITERTLM      Gemma 4 E2B (.litertlm)
//   LITERTLM_SESSION_BACKEND cpu (default) or gpu
//   LITERTLM_SESSION_CACHE   the engine's cache directory
//
// Prints what each run saw, for the record.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

String? _file(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

String _turn(String text) => '<|turn>user\n$text<turn|>\n<|turn>model\n';

const _long = 'Count from 1 to 400, one number per line, with no other text.';

void main() {
  final model = _file('GEMMA4_E2B_LITERTLM');
  final gpu = Platform.environment['LITERTLM_SESSION_BACKEND'] == 'gpu';
  final tag = gpu ? 'gpu' : 'cpu';
  final skip = model == null ? 'GEMMA4_E2B_LITERTLM' : null;

  Future<Engine> engine() => Engine.create(
    EngineConfig(
      modelPath: model!,
      backend: gpu ? const Backend.gpu() : const Backend.cpu(),
      maxNumTokens: 2048,
      cacheDir: Platform.environment['LITERTLM_SESSION_CACHE'],
    ),
  );

  test(
    'a cancelled session refuses every later call; an idle one too; a '
    'cancel mid-stream ends the stream with what came ($tag)',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final e = await engine();
      try {
        final idle = await e.createSession();
        await idle.runPrefill([InputData.text(_turn('Say hi.'))]);
        idle.cancelProcess();
        expect(
          () => idle.runDecode(),
          throwsA(
            isA<StateError>().having(
              (s) => s.message,
              'message',
              contains('cancelled'),
            ),
          ),
        );
        await idle.close();

        final streaming = await e.createSession();
        final chunks = <String>[];
        final done = Completer<void>();
        late final StreamSubscription<String> sub;
        sub = streaming
            .generateContentStream([InputData.text(_turn(_long))])
            .listen(
              (c) {
                chunks.add(c);
                if (chunks.length == 8) streaming.cancelProcess();
              },
              onError: done.completeError,
              onDone: done.complete,
            );
        await done.future;
        await sub.cancel();
        print(
          '[session $tag] cancelled mid-stream after '
          '${chunks.length} chunks: ${chunks.join().replaceAll('\n', ' ')}',
        );
        expect(chunks.length, inInclusiveRange(8, 40));
        expect(
          () => streaming.runPrefill([InputData.text('more')]),
          throwsStateError,
        );
        expect(streaming.clone, throwsStateError);
        await streaming.close();

        // A blocking call stopped while it decodes returns what it had; one
        // stopped during its prefill completes with nothing more.
        final blocking = await e.createSession();
        final reply = blocking.generateContent([InputData.text(_turn(_long))]);
        await Future<void>.delayed(const Duration(seconds: 2));
        blocking.cancelProcess();
        final stopwatch = Stopwatch()..start();
        final text = await reply;
        print(
          '[session $tag] blocking generateContent stopped '
          '${stopwatch.elapsedMilliseconds} ms after the cancel: '
          '${text.replaceAll('\n', ' ')}',
        );
        expect(text, startsWith('1'));
        expect(text.length, lessThan(400));
        await blocking.close();

        final prefilling = await e.createSession();
        final big = List.filled(300, 'The quick brown fox.').join(' ');
        final prefill = prefilling.runPrefill([InputData.text(_turn(big))]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        prefilling.cancelProcess();
        final prefillWatch = Stopwatch()..start();
        await prefill;
        print(
          '[session $tag] runPrefill of ~1500 tokens stopped: completed '
          '${prefillWatch.elapsedMilliseconds} ms after the cancel',
        );
        await prefilling.close();
      } finally {
        await e.close();
      }
    },
  );

  test(
    'a cancel asked for before a queued call reaches native is not lost: '
    'the call does not run, the stream ends with nothing ($tag)',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final e = await engine();
      try {
        final busy = await e.createSession();
        final queued = await e.createSession();
        final queuedStream = await e.createSession();
        // Holds the engine's lock for a while.
        final first = busy.generateContent([
          InputData.text(_turn('Write two sentences about the sea.')),
        ]);
        // Queued behind it, then cancelled before they start. The prefill is
        // long (~1500 tokens, seconds on the CPU): run, it would show.
        final big = List.filled(300, 'The quick brown fox.').join(' ');
        final prefill = queued.runPrefill([InputData.text(_turn(big))]);
        final chunks = <String>[];
        final streamDone = queuedStream
            .generateContentStream([InputData.text(_turn(_long))])
            .listen(chunks.add)
            .asFuture<void>();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        queued.cancelProcess();
        queuedStream.cancelProcess();
        final answer = await first;
        final afterBusy = Stopwatch()..start();
        await prefill;
        final prefillMs = afterBusy.elapsedMilliseconds;
        await streamDone;
        print(
          '[session $tag] busy answered "${answer.trim()}"; the queued '
          'prefill ended $prefillMs ms after it; queued stream chunks: '
          '${chunks.length}',
        );
        expect(answer.trim(), isNotEmpty);
        expect(prefillMs, lessThan(500));
        expect(chunks, isEmpty);
        await busy.close();
      } finally {
        await e.close();
      }
    },
  );

  test(
    'engine.close during a long session decode returns promptly and the '
    'stream ends with a StateError ($tag)',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final e = await engine();
      final session = await e.createSession();
      final chunks = <String>[];
      final firstChunk = Completer<void>();
      final ended = Completer<Object?>();
      session
          .generateContentStream([InputData.text(_turn(_long))])
          .listen(
            (c) {
              chunks.add(c);
              if (!firstChunk.isCompleted) firstChunk.complete();
            },
            onError: (Object error) {
              if (!ended.isCompleted) ended.complete(error);
            },
            onDone: () {
              if (!ended.isCompleted) ended.complete(null);
            },
          );
      await firstChunk.future;
      final stopwatch = Stopwatch()..start();
      await e.close();
      final closeMs = stopwatch.elapsedMilliseconds;
      final error = await ended.future.timeout(const Duration(seconds: 5));
      print(
        '[session $tag] engine.close took $closeMs ms after '
        '${chunks.length} chunks; the stream ended with $error',
      );
      expect(closeMs, lessThan(5000));
      expect(error, isA<StateError>());
      expect('$error', contains('engine was closed'));
      expect(() => session.runDecode(), throwsStateError);
    },
  );
}
