import 'dart:async';

import 'package:flutter_edge_ai/core/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// The state machine the three shells used to each own a copy of. Every case
/// here is a defect that reached review in one shell or another: a rebuild that
/// handed back the model it was closing, a late close that cleared a live model,
/// a join with no comparison, two builds where one was asked for.
void main() {
  ActiveEmbedderParams paramsFor(String model, {String? tokenizer}) =>
      ActiveEmbedderParams(modelPath: model, tokenizerPath: tokenizer);

  group('EmbedderCache reuse rule', () {
    test('an empty cache asks for a build', () async {
      final cache = EmbedderCache();

      expect(
        await cache.reuseOrInvalidate(paramsFor('/a'), label: 'test'),
        isNull,
      );
    });

    test('matching params reuse the model without closing it', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, paramsFor('/a'));

      final reused = await cache.reuseOrInvalidate(
        paramsFor('/a'),
        label: 'test',
      );

      expect(reused, same(model));
      expect(model.closeCount, 0);
      expect(cache.model, same(model));
    });

    test(
      'a changed model path closes the old model and asks for a build',
      () async {
        final cache = EmbedderCache();
        final model = _FakeEmbedder();
        cache.record(model, paramsFor('/a'));

        final reused = await cache.reuseOrInvalidate(
          paramsFor('/b'),
          label: 'test',
        );

        expect(reused, isNull);
        expect(model.closeCount, 1);
        expect(cache.model, isNull);
        expect(cache.params, isNull);
      },
    );

    test('a changed tokenizer path also rebuilds', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, paramsFor('/a', tokenizer: '/t1'));

      expect(
        await cache.reuseOrInvalidate(
          paramsFor('/a', tokenizer: '/t2'),
          label: 'test',
        ),
        isNull,
      );
      expect(model.closeCount, 1);
    });

    test('a model being closed is never handed to a matching caller', () async {
      final cache = EmbedderCache();
      final gate = Completer<void>();
      final model = _FakeEmbedder(closeGate: gate);
      cache.record(model, paramsFor('/a'));

      // A rebuild for /b is in flight and stuck inside close().
      final rebuild = cache.reuseOrInvalidate(
        paramsFor('/b'),
        label: 'rebuild',
      );
      await pumpEventQueue();

      // Someone asks for /a — the config the closing model was built from.
      final duringClose = await cache.reuseOrInvalidate(
        paramsFor('/a'),
        label: 'matching',
      );

      expect(
        duringClose,
        isNull,
        reason: 'the cached model is closing, so it is nobody\'s answer',
      );
      gate.complete();
      expect(await rebuild, isNull);
    });

    test('a rebuild is not asked for until the old model has finished '
        'closing', () async {
      // The shells build as soon as this returns null. Returning before the
      // old model's teardown finished would put two native engines in memory
      // at once — and the worker's close now waits for the request in flight
      // instead of killing it after five seconds, so that teardown can take a
      // while.
      final cache = EmbedderCache();
      final gate = Completer<void>();
      final model = _FakeEmbedder(closeGate: gate);
      cache.record(model, paramsFor('/a'));

      var answered = false;
      final rebuild = cache
          .reuseOrInvalidate(paramsFor('/b'), label: 'rebuild')
          .whenComplete(() => answered = true);
      await pumpEventQueue();

      expect(model.closeCount, 1, reason: 'the close has started');
      expect(
        answered,
        isFalse,
        reason:
            'a "build a new one" answer before the old close finished '
            'means two engines resident at once',
      );

      gate.complete();
      expect(await rebuild, isNull);
      expect(answered, isTrue);
    });
  });

  group('EmbedderCache.record', () {
    test('a model whose addCloseListener throws is never cached', () {
      // `addCloseListener` is abstract on the published interface, so a
      // third-party model can throw from it. Caching before registering would
      // leave a live, open model that the shells' catch then forgets without
      // closing it.
      final cache = EmbedderCache();
      final hostile = _HostileListenerEmbedder();

      expect(
        () => cache.record(hostile, paramsFor('/a')),
        throwsStateError,
        reason: 'the throw belongs to its caller',
      );
      expect(
        cache.model,
        isNull,
        reason: 'nothing may be cached that the cache cannot be told about',
      );
    });
  });

  group('EmbedderCache.adopt', () {
    test(
      'a model the cache refuses is closed, and its caller is told why',
      () async {
        // Both halves of custody fail: the listener cannot be registered, and the
        // close that backs out of it throws too. The caller must see the FIRST
        // error — the one that explains the failure — not the teardown's.
        final cache = EmbedderCache();
        final hostile = _HostileListenerEmbedder(throwOnClose: true);

        await expectLater(
          cache.adopt(hostile, paramsFor('/a')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('does not support close listeners'),
            ),
          ),
        );
        expect(hostile.closeCount, 1, reason: 'the refused model is closed');
        expect(cache.model, isNull);
      },
    );
  });

  test(
    'a throwing close does not fail the caller who asked to rebuild',
    () async {
      // The caller asked for /b. The old model's teardown error names neither
      // model, and failing here means /b is never built at all — while a retry
      // succeeds, erasing the evidence. CloseNotifier does not guard a throwing
      // listener, so an app that registered one on the old embedder is enough.
      final cache = EmbedderCache();
      final hostile = _FakeEmbedder(throwOnClose: true);
      cache.record(hostile, paramsFor('/a'));

      expect(
        await cache.reuseOrInvalidate(paramsFor('/b'), label: 'rebuild'),
        isNull,
        reason: 'the answer is still "build a new one"',
      );
      expect(cache.model, isNull);
    },
  );

  test(
    'a cached model that reports itself closed is rebuilt, not reused',
    () async {
      // Eviction normally rides the close listener. A model that never fires one
      // — or that was already closed when it was recorded, after which
      // `fireCloseListeners` has nothing left to call — would otherwise be
      // handed to every later caller, and every call on it throws.
      final cache = EmbedderCache();
      final silent = _SilentCloseEmbedder();
      cache.record(silent, paramsFor('/a'));
      await silent.close();

      expect(
        await cache.reuseOrInvalidate(paramsFor('/a'), label: 'test'),
        isNull,
        reason: 'the params match, so only isClosed can save this caller',
      );
      expect(cache.model, isNull);
    },
  );

  test('a closed model is not handed to a direct reader either', () async {
    // `initializedEmbeddingModel` and the web RAG helpers read `model`
    // directly rather than through `reuseOrInvalidate`. A model is closed the
    // moment `close()` is called, but its listener evicts it only after the
    // teardown finishes — so without this, those readers got a model whose
    // every call throws.
    final cache = EmbedderCache();
    final silent = _SilentCloseEmbedder();
    cache.record(silent, paramsFor('/a'));
    expect(cache.model, same(silent));

    await silent.close();

    expect(
      cache.model,
      isNull,
      reason: 'no listener fired, so only isClosed can keep this from leaking',
    );
    expect(
      cache.params,
      isNull,
      reason: 'params describing a model the cache no longer hands out',
    );
  });

  group('EmbedderCache close listener', () {
    test('closing the cached model empties the cache', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, paramsFor('/a'));

      await model.close();

      expect(cache.model, isNull);
      expect(cache.params, isNull);
    });

    test(
      'a late close of a superseded model leaves the live one alone',
      () async {
        final cache = EmbedderCache();
        final superseded = _FakeEmbedder();
        final live = _FakeEmbedder();
        cache.record(superseded, paramsFor('/a'));
        cache.record(live, paramsFor('/b'));

        // The caller that still held the old model does the documented thing.
        await superseded.close();

        expect(
          cache.model,
          same(live),
          reason: 'an unguarded listener would evict a live, in-use model',
        );
        expect(cache.params, paramsFor('/b'));
      },
    );
  });

  group('EmbedderCache.serialize', () {
    test('bodies run one at a time', () async {
      final cache = EmbedderCache();
      final order = <String>[];
      final first = Completer<void>();

      final a = cache.serialize(() async {
        order.add('a-start');
        await first.future;
        order.add('a-end');
        return 'a';
      });
      final b = cache.serialize(() async {
        order.add('b-start');
        return 'b';
      });

      await pumpEventQueue();
      expect(order, ['a-start'], reason: 'b must not start while a runs');

      first.complete();
      expect(await a, 'a');
      expect(await b, 'b');
      expect(order, ['a-start', 'a-end', 'b-start']);
    });

    test('a failing body does not poison the lane', () async {
      final cache = EmbedderCache();

      final failed = cache.serialize<void>(
        () async => throw StateError('no embedding backend registered'),
      );
      await expectLater(failed, throwsStateError);

      expect(await cache.serialize(() async => 'after'), 'after');
    });

    test('a body that never settles holds the lane, and releases it', () async {
      // The documented price of having no completer to join: one stuck build
      // (a wedged native createModel) stalls EVERY later request on this shell,
      // not just a matching one. Pinned so the trade-off cannot change by
      // accident — the previous per-shell code stalled them too, via an await
      // on the in-flight completer, so this is not new, only explicit.
      final cache = EmbedderCache();
      final stuck = Completer<void>();
      var secondStarted = false;

      cache.serialize<void>(() => stuck.future);
      final second = cache.serialize<void>(() async {
        secondStarted = true;
      });

      await pumpEventQueue();
      expect(secondStarted, isFalse, reason: 'the lane is held by the first');

      stuck.complete();
      await second;
      expect(secondStarted, isTrue, reason: 'and released when it settles');
    });

    test('an unawaited failure still reaches the zone', () async {
      // The lane must not advance by attaching an error handler to the future
      // it hands back: that marks the caller's error HANDLED, and a
      // fire-and-forget `createEmbeddingModel()` that failed then reported
      // nothing anywhere — measured, not assumed.
      final seen = <Object>[];
      await runZonedGuarded(() async {
        final cache = EmbedderCache();
        cache.serialize<void>(() async => throw StateError('boom'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (e, _) => seen.add(e));

      expect(seen, hasLength(1), reason: 'the failure must not vanish');
    });

    test(
      'a body that throws still lets the next one see fresh state',
      () async {
        final cache = EmbedderCache();

        await expectLater(
          cache.serialize<void>(() async {
            cache.record(_FakeEmbedder(), paramsFor('/a'));
            cache.invalidate();
            throw StateError('build failed');
          }),
          throwsStateError,
        );

        expect(
          await cache.serialize(
            () => cache.reuseOrInvalidate(paramsFor('/a'), label: 'retry'),
          ),
          isNull,
          reason: 'a failed build must not leave a baseline behind',
        );
      },
    );
  });

  group('EmbedderCache.invalidate', () {
    test('forgets the model without closing it', () {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, paramsFor('/a'));

      cache.invalidate();

      expect(cache.model, isNull);
      expect(cache.params, isNull);
      expect(model.closeCount, 0);
    });
  });
}

/// Closes without telling anyone, the way a third-party implementation that
/// does not mix in `CloseNotifier` might.
class _SilentCloseEmbedder extends _FakeEmbedder {
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    _closed = true; // deliberately no fireCloseListeners()
  }
}

/// Refuses to register a close listener, the way a third-party implementation
/// that does not mix in `CloseNotifier` might.
class _HostileListenerEmbedder extends _FakeEmbedder {
  _HostileListenerEmbedder({super.throwOnClose});

  @override
  void addCloseListener(void Function() listener) =>
      throw StateError('this model does not support close listeners');
}

class _FakeEmbedder extends EmbeddingModel with CloseNotifier {
  _FakeEmbedder({this.closeGate, this.throwOnClose = false});

  final Completer<void>? closeGate;
  final bool throwOnClose;
  int closeCount = 0;

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [0.0];

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [
    [0.0],
  ];

  @override
  Future<int> getDimension() async => 1;

  @override
  Future<void> close() async {
    closeCount++;
    if (closeGate != null) await closeGate!.future;
    fireCloseListeners();
    if (throwOnClose) throw StateError('teardown failed');
  }
}
