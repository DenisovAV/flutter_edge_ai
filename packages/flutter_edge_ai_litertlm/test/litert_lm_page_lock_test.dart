// The page lock (lib/src/web/litert_lm_page_lock.dart) on the VM: mutual
// exclusion, call-order fairness, release on every path — and that the
// EmbeddingGemma 2 web pass really takes it: while another holder (the LLM
// web session, in the browser) has the lock, the pass's create + probe and
// its computeEmbedding do not reach the runtime. The LLM session's side —
// held from sendMessageStreaming until the JS stream ends, drained after a
// consumer cancel — is the browser suite test/web/litert_lm_page_lock_web_test.dart.

import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_page_lock.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets every pending microtask and zero timer run.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Engine implements LiteRtLmWebEngine {
  int computes = 0;

  @override
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  ) async {
    computes++;
    final tokens = switch (input) {
      LiteRtLmWebText(:final text) => text.length + 2,
      LiteRtLmWebImage() => 142,
    };
    return (
      embedding: const [0.5, 0.5, 0.5, 0.5],
      inputLength: tokens,
      truncatedLength: tokens > 1024 ? 1024 : null,
      numChunks: 1,
    );
  }

  @override
  Future<void> delete() async {}
}

final class _Runtime implements LiteRtLmWebRuntime {
  final engine = _Engine();
  int creates = 0;

  @override
  Future<LiteRtLmWebRuntimeState> ensureReady() async =>
      LiteRtLmWebRuntimeState.ready;

  @override
  Future<LiteRtLmWebGpuSupport> webGpuSupport() async =>
      LiteRtLmWebGpuSupport.available;

  @override
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings settings) async {
    creates++;
    return engine;
  }
}

LiteRtLmWebEmbeddingPass _pass(_Runtime runtime) => LiteRtLmWebEmbeddingPass(
  LiteRtLmWebEmbeddingConfig(
    modelPath: 'blob:eg2',
    fileName: 'embeddinggemma-2-text-270m.litertlm',
    runtime: runtime,
    resolveUrl: (path) async => path,
    revokeUrl: (_) {},
  ),
);

void main() {
  group('LiteRtLmPageLock', () {
    test('never two holders at once, and holders run in call order', () async {
      final lock = LiteRtLmPageLock();
      var inside = 0;
      var most = 0;
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 8; i++)
          lock.run(() async {
            inside++;
            most = inside > most ? inside : most;
            order.add(i);
            // Hold across real event-loop turns, as a WASM call does.
            await Future<void>.delayed(Duration(milliseconds: 8 - i));
            inside--;
          }),
      ]);
      expect(most, 1);
      expect(order, [for (var i = 0; i < 8; i++) i]);
    });

    test(
      'holders get the lock in the order acquire() was called, even when awaited later',
      () async {
        final lock = LiteRtLmPageLock();
        final first = lock.acquire();
        final second = lock.acquire(); // queued now, awaited later
        final third = lock.run(() async => 'third');
        final lease1 = await first;
        var secondGot = false;
        unawaited(second.then((_) => secondGot = true));
        await _settle();
        expect(secondGot, isFalse, reason: 'the first lease is still held');
        lease1.release();
        final lease2 = await second;
        expect(secondGot, isTrue);
        var thirdDone = false;
        unawaited(third.then((_) => thirdDone = true));
        await _settle();
        expect(thirdDone, isFalse);
        lease2.release();
        expect(await third, 'third');
      },
    );

    test(
      'a body that throws releases the lock; release is idempotent',
      () async {
        final lock = LiteRtLmPageLock();
        await expectLater(
          lock.run<void>(() async => throw StateError('wasm trap')),
          throwsStateError,
        );
        expect(await lock.run(() async => 1), 1);

        final lease = await lock.acquire();
        final next = lock.acquire();
        lease
          ..release()
          ..release();
        expect(lease.isReleased, isTrue);
        final nextLease = await next;
        // A second release of the first lease must not let a third holder in
        // beside the second.
        var thirdGot = false;
        unawaited(lock.acquire().then((_) => thirdGot = true));
        await _settle();
        expect(thirdGot, isFalse);
        nextLease.release();
        await _settle();
        expect(thirdGot, isTrue);
      },
    );
  });

  group('the EmbeddingGemma 2 web pass takes the page lock', () {
    test('its create + load probe wait while another holder (an LLM '
        'generation) has the lock', () async {
      final runtime = _Runtime();
      final pass = _pass(runtime);
      final lease = await liteRtLmPageLock.acquire();
      try {
        final loading = pass.load();
        await _settle();
        expect(runtime.creates, 0, reason: 'entered the module while held');
        expect(runtime.engine.computes, 0);
        lease.release();
        final info = await loading;
        expect(info.dimension, 4);
        expect(runtime.creates, 1);
        expect(runtime.engine.computes, 1, reason: 'the probe');
      } finally {
        lease.release();
        await pass.close();
      }
    });

    test(
      'each computeEmbedding waits too, and the lock is free after it',
      () async {
        final runtime = _Runtime();
        final pass = _pass(runtime);
        await pass.load();
        final lease = await liteRtLmPageLock.acquire();
        try {
          final embedding = pass.embed(EmbeddingInput.text('x'), TaskType.none);
          await _settle();
          expect(runtime.engine.computes, 1, reason: 'only the probe so far');
          lease.release();
          expect(await embedding, hasLength(4));
          expect(runtime.engine.computes, 2);
        } finally {
          lease.release();
        }
        // Released after the embed: the next holder gets in at once.
        await liteRtLmPageLock.run(() async {});
        await pass.close();
      },
    );

    test('an overflow and a failing call release the lock too', () async {
      final runtime = _Runtime();
      final pass = _pass(runtime);
      await pass.load();
      await expectLater(
        pass.embed(EmbeddingInput.text('w' * 2000), TaskType.none),
        throwsA(isA<EmbeddingInputTooLongException>()),
      );
      await liteRtLmPageLock
          .run(() async {})
          .timeout(const Duration(seconds: 1));
      await pass.close();
    });
  });
}
