// Client-side lifecycle/mutex race tests against the REAL `GenAiFfiClient`
// — a scripted fake worker isolate (`test/fakes/fake_gen_ai_worker.dart`)
// stands in for the native ORT-GenAI worker, so these exercise the client's
// real dispatch/mutex/`_closed`-recheck machinery with zero dlopen (hardened
// plan Task 2c). The fake has NO FFI and no native pointers, so it CANNOT
// prove the real worker's native handle teardown (`_defaultWorkerEntry`'s
// `stopRequested = true; await activeGeneration;` guard before
// OgaDestroyGenerator/Tokenizer/Model in `gen_ai_client.dart`) is
// use-after-free-safe — that guard is only exercised by the real-native
// regression test in `onnx_generation_host_smoke_test.dart`
// ('real-worker close-during-generation').
//
// Test (d) below is TDD for a fix landed in the same change: `_closed` is
// now rechecked AFTER `_mutex.acquire()` in both `_runGenerateGuarded` and
// `countTokens` (see `gen_ai_client.dart`). Before that fix, a `generate()`
// call queued behind an in-flight generation would hang forever (and wedge
// the mutex) if `shutdown()` ran while it was parked on the mutex — this
// test pins that it now fails fast instead.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_gemma_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_gen_ai_worker.dart';

String _script({
  List<String> chunks = const ['a', 'b', 'c', 'd', 'e'],
  int delayMs = 0,
  bool echoIsFirstTurn = false,
}) => jsonEncode({
  'chunks': chunks,
  'delayMs': delayMs,
  'echoIsFirstTurn': echoIsFirstTurn,
});

GenAiTurn _turn({
  List<String> chunks = const ['a', 'b', 'c', 'd', 'e'],
  int delayMs = 0,
  bool isFirstTurn = false,
  bool echoIsFirstTurn = false,
}) => GenAiTurn(
  userContent: _script(
    chunks: chunks,
    delayMs: delayMs,
    echoIsFirstTurn: echoIsFirstTurn,
  ),
  isFirstTurn: isFirstTurn,
);

void main() {
  group('GenAiFfiClient lifecycle (real client + fake worker isolate)', () {
    late GenAiFfiClient client;

    setUp(() async {
      client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
      await client.load('/tmp/unused-fake-model-dir');
    });

    tearDown(() async {
      await client.shutdown();
    });

    test(
      '(a) cancel-releases-mutex: canceling generate() mid-stream sends '
      'StopSignal, the stream stops via a normal GenerateDone(stopped:true), '
      'and a SECOND generate() completes — the mutex is not wedged',
      () async {
        final receivedA = <String>[];
        final subA = client
            .generate(
              _turn(chunks: List.generate(20, (i) => 'x$i'), delayMs: 15),
            )
            .listen(receivedA.add);

        // Let a few chunks flow, then cancel — StreamController.onCancel
        // wires this to `stopGeneration()` (gen_ai_client.dart).
        while (receivedA.length < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await subA.cancel();

        // The mutex must be free again promptly: a second generate() call
        // completes rather than hanging.
        final receivedB = <String>[];
        await client
            .generate(_turn(chunks: ['second', 'call', 'works']))
            .forEach(receivedB.add);

        expect(receivedB.join(), 'secondcallworks');
        expect(receivedA.length, lessThan(20));
      },
    );

    test('(c) stop-truncates-promptly: stopGeneration() after chunk N lets at '
        'most one further chunk through, and the stream closes', () async {
      final received = <String>[];
      var done = false;
      final completer = Completer<void>();
      final sub = client
          .generate(_turn(chunks: List.generate(50, (i) => 'c$i'), delayMs: 15))
          .listen(
            received.add,
            onDone: () {
              done = true;
              completer.complete();
            },
          );
      addTearDown(() => sub.cancel());

      // Let 3 chunks through, then stop.
      while (received.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final countAtStop = received.length;
      await client.stopGeneration();

      await completer.future.timeout(const Duration(seconds: 5));

      expect(done, isTrue);
      expect(
        received.length,
        lessThanOrEqualTo(countAtStop + 1),
        reason:
            'the worker\'s bounded one-more-token contract: at most one '
            'chunk may arrive after stopGeneration() lands',
      );
      expect(received.length, lessThan(50));
    });

    test(
      '(d) shutdown-while-generating: EVERY generate() call queued behind '
      'an in-flight generation fails fast with the shutdown StateError '
      'instead of hanging (TDD for the _closed-after-acquire recheck fix) '
      "— including the SECOND-in-line caller, which shutdown()'s own "
      "best-effort `_activeStreams` sweep cannot see (it hasn't registered "
      "yet — it's still queued on the mutex ITSELF, behind the first "
      'caller, when that one-shot sweep runs). That sweep can coincidentally '
      "save a single queued caller (registered just before the sweep) — "
      "this test's SECOND caller is what actually pins the recheck fix.",
      () async {
        final receivedA = <String>[];
        client
            .generate(
              _turn(chunks: List.generate(20, (i) => 'a$i'), delayMs: 20),
            )
            .listen(receivedA.add);

        // Give A's `_runGenerateGuarded` a chance to acquire the mutex and
        // send its GenerateRequest before B/C queue behind it.
        await Future<void>.delayed(const Duration(milliseconds: 5));

        Object? errorB;
        var doneB = false;
        final doneCompleterB = Completer<void>();
        client
            .generate(_turn(chunks: ['never', 'arrives']))
            .listen(
              (_) {},
              onError: (Object e) => errorB = e,
              onDone: () {
                doneB = true;
                doneCompleterB.complete();
              },
            );

        Object? errorC;
        var doneC = false;
        final doneCompleterC = Completer<void>();
        client
            .generate(_turn(chunks: ['also', 'never', 'arrives']))
            .listen(
              (_) {},
              onError: (Object e) => errorC = e,
              onDone: () {
                doneC = true;
                doneCompleterC.complete();
              },
            );

        // A, B, and C are all queued/in-flight. Shut down while A is still
        // generating — pre-fix, B *might* get swept by shutdown()'s
        // best-effort `_activeStreams` cleanup (it can register into that
        // map before the sweep runs), but C only gets queued for the mutex
        // once B's `_runGenerateGuarded` finally releases it — which, for C
        // to ever even get a chance to register, requires B to release the
        // mutex, and pre-fix B only does that via ITS OWN worker round trip
        // (dead port ⇒ never) or via that SAME one-shot sweep (which has
        // already run by the time B's release fires C's turn) — so C is
        // left holding a `_commandPort!.send(...)` into thin air with
        // NOTHING left to complete it. That is the recheck fix's actual
        // job: bail out immediately after acquiring, never touch the port.
        await client.shutdown().timeout(const Duration(seconds: 10));
        await doneCompleterB.future.timeout(const Duration(seconds: 5));
        await doneCompleterC.future.timeout(const Duration(seconds: 5));

        expect(doneB, isTrue);
        expect(errorB, isA<StateError>());
        expect((errorB as StateError).message, contains('shut down'));

        expect(doneC, isTrue);
        expect(errorC, isA<StateError>());
        expect((errorC as StateError).message, contains('shut down'));
      },
    );

    test(
      'countTokens queued behind an in-flight generation also fails fast '
      'on shutdown instead of hanging (same recheck fix, countTokens arm)',
      () async {
        client
            .generate(
              _turn(chunks: List.generate(20, (i) => 'a$i'), delayMs: 20),
            )
            .listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // Attach the error handler synchronously, right when the future is
        // created — Dart reports a Future's error as "unhandled" if no
        // listener is attached by the time it completes, even if one is
        // attached later. Since the error here lands mid-`shutdown()` (well
        // before the test would otherwise get around to inspecting it), a
        // bare `client.countTokens(...)` stored in a local and awaited only
        // after `shutdown()` would trip that footgun.
        Object? countError;
        int? countResult;
        final countSettled = Completer<void>();
        unawaited(
          client
              .countTokens('queued behind the mutex')
              .then(
                (r) {
                  countResult = r;
                  countSettled.complete();
                },
                onError: (Object e) {
                  countError = e;
                  countSettled.complete();
                },
              ),
        );

        await client.shutdown().timeout(const Duration(seconds: 10));
        await countSettled.future.timeout(const Duration(seconds: 5));

        expect(countResult, isNull);
        expect(countError, isA<StateError>());
      },
    );

    test(
      'an unexpected worker death (unhandled native crash) fails BOTH an '
      'in-flight generate() stream and a bystander countTokens() instead of '
      'hanging them forever (msg == null / onExit branch of _dispatch)',
      () async {
        final killer = <String>[];
        Object? killerError;
        var killerDone = false;
        final killerDoneCompleter = Completer<void>();
        client
            .generate(GenAiTurn(userContent: jsonEncode({'kill': true})))
            .listen(
              killer.add,
              onError: (Object e) => killerError = e,
              onDone: () {
                killerDone = true;
                killerDoneCompleter.complete();
              },
            );

        // A bystander call racing the dying worker — must fail fast too,
        // not hang forever waiting on a worker that will never reply.
        Object? bystanderError;
        int? bystanderResult;
        final bystanderSettled = Completer<void>();
        unawaited(
          client
              .countTokens('never replies')
              .then(
                (r) {
                  bystanderResult = r;
                  bystanderSettled.complete();
                },
                onError: (Object e) {
                  bystanderError = e;
                  bystanderSettled.complete();
                },
              ),
        );

        await killerDoneCompleter.future.timeout(const Duration(seconds: 10));
        await bystanderSettled.future.timeout(const Duration(seconds: 10));

        expect(killer, isEmpty);
        expect(killerDone, isTrue);
        expect(killerError, isA<StateError>());

        expect(bystanderResult, isNull);
        expect(bystanderError, isA<StateError>());
      },
    );
  });

  group('GenAiFfiClient / OnnxSession-shaped close ordering', () {
    test('(b) close-during-generation: stopGeneration() then resetSession() '
        'round-trips cleanly (ResetAck received, no error surfaced) while a '
        'generation is in flight, and the client is reusable for a fresh, '
        'isFirstTurn:true next turn', () async {
      final client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
      await client.load('/tmp/unused-fake-model-dir');
      addTearDown(() => client.shutdown());

      final received = <String>[];
      Object? error;
      var done = false;
      final doneCompleter = Completer<void>();
      client
          .generate(_turn(chunks: List.generate(30, (i) => 'x$i'), delayMs: 15))
          .listen(
            received.add,
            onError: (Object e) => error = e,
            onDone: () {
              done = true;
              doneCompleter.complete();
            },
          );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // OnnxSession.close()'s exact ordering (onnx_session.dart):
      // stopGeneration() THEN resetSession(), both awaited.
      await client.stopGeneration();
      await client.resetSession();

      await doneCompleter.future.timeout(const Duration(seconds: 5));

      expect(done, isTrue);
      expect(
        error,
        isNull,
        reason:
            'a mid-stream stop completes the stream normally (via '
            'GenerateDone(stopped:true)), never as a stream error',
      );
      expect(received.length, lessThan(30));

      // The client is still usable: resetSession() destroyed the fake
      // worker's generator, so the next turn is free to (and, per
      // OnnxSession's own bookkeeping, always does) start fresh.
      final nextReceived = <String>[];
      await client
          .generate(
            _turn(
              chunks: ['ignored-by-marker'],
              isFirstTurn: true,
              echoIsFirstTurn: true,
            ),
          )
          .forEach(nextReceived.add);

      expect(nextReceived.first, '[isFirstTurn=true]');
    });
  });
}
