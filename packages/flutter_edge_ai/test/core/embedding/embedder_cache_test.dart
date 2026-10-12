import 'dart:async';

import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// The model to reuse, or null for "build one" — what most cases here ask.
extension on EmbedderCache {
  Future<EmbeddingModel?> reuseOrNull(
    ActiveEmbedderParams requested, {
    required String label,
  }) => reuseOrInvalidate(requested, label: label).then((d) => d.reuse);
}

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

      expect(await cache.reuseOrNull(paramsFor('/a'), label: 'test'), isNull);
    });

    test('matching params reuse the model without closing it', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, paramsFor('/a'));

      final reused = await cache.reuseOrNull(paramsFor('/a'), label: 'test');

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

        final reused = await cache.reuseOrNull(paramsFor('/b'), label: 'test');

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
        await cache.reuseOrNull(
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
      final rebuild = cache.reuseOrNull(paramsFor('/b'), label: 'rebuild');
      await pumpEventQueue();

      // Someone asks for /a — the config the closing model was built from.
      // They are not handed the closing model, and they are not told to build
      // either until it has finished closing.
      var answered = false;
      final duringClose = cache
          .reuseOrNull(paramsFor('/a'), label: 'matching')
          .whenComplete(() => answered = true);
      await pumpEventQueue();
      expect(answered, isFalse, reason: 'the old model is still closing');

      gate.complete();
      expect(
        await duringClose,
        isNull,
        reason: 'the cached model is closing, so it is nobody\'s answer',
      );
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
          .reuseOrNull(paramsFor('/b'), label: 'rebuild')
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

    test(
      'a close that outlasts the wait fails the caller with a '
      'EmbedderCloseTimeoutException, keeps running, and holds every later build',
      () async {
        // Unbounded, one wedged native close hangs every embedder call in the
        // app behind the serialize lane.
        final cache = EmbedderCache(
          closeWaitLimit: const Duration(milliseconds: 100),
        );
        final gate = Completer<void>();
        final model = _FakeEmbedder(closeGate: gate);
        cache.record(model, paramsFor('/a'));

        await expectLater(
          cache.reuseOrNull(paramsFor('/b'), label: 'first'),
          throwsA(
            isA<EmbedderCloseTimeoutException>()
                .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('/a'), contains('closing')),
                )
                .having(
                  (e) => e.waited,
                  'waited',
                  greaterThanOrEqualTo(const Duration(milliseconds: 90)),
                ),
          ),
        );
        expect(model.closeCount, 1, reason: 'the close was started...');
        expect(model.closed, isFalse, reason: '...and was not cut short');

        // Still closing: the next caller must not be told to build either —
        // and it waits for the SAME close rather than starting another.
        await expectLater(
          cache.reuseOrNull(paramsFor('/b'), label: 'second'),
          throwsA(isA<EmbedderCloseTimeoutException>()),
          reason: 'building now would put two native models in memory',
        );
        expect(model.closeCount, 1);

        gate.complete();
        await pumpEventQueue();
        expect(model.closed, isTrue);
        expect(
          await cache.reuseOrNull(paramsFor('/b'), label: 'third'),
          isNull,
          reason: 'with the old model gone, the build may go ahead',
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('waited is what THIS caller waited: about the limit for the first, '
        'about zero for one that arrives after the deadline', () async {
      const limit = Duration(milliseconds: 200);
      final cache = EmbedderCache(closeWaitLimit: limit);
      final gate = Completer<void>();
      final model = _FakeEmbedder(closeGate: gate);
      cache.record(model, paramsFor('/a'));

      Future<Duration> waitedBy(String label) => cache
          .reuseOrNull(paramsFor('/b'), label: label)
          .then<Duration>(
            (_) => fail('$label was told to build'),
            onError: (Object e) =>
                e is EmbedderCloseTimeoutException ? e.waited : throw e,
          );

      final first = await waitedBy('first');
      final later = await waitedBy('later');
      expect(first, greaterThanOrEqualTo(limit * 0.9));
      expect(first, lessThan(limit * 2));
      expect(
        later,
        lessThan(limit ~/ 4),
        reason: 'the deadline had passed when it asked; it failed at once',
      );

      gate.complete();
      await pumpEventQueue();
    });

    test('callers queued behind a close share one deadline: all fail when it '
        'passes, not one limit apart, and its end is announced', () async {
      // A fresh limit per caller made the Nth queued caller wait N limits:
      // with the 60 s default, a few queued requests meant minutes.
      const limit = Duration(milliseconds: 200);
      final cache = EmbedderCache(closeWaitLimit: limit);
      final gate = Completer<void>();
      final model = _FakeEmbedder(closeGate: gate);
      cache.record(model, paramsFor('/a'));
      final printed = <String>[];

      final failedAt = <Duration>[];
      await runZoned(
        () async {
          final clock = Stopwatch()..start();
          final callers = [
            for (var i = 0; i < 3; i++)
              cache
                  .serialize(
                    () =>
                        cache.reuseOrNull(paramsFor('/b'), label: 'caller $i'),
                  )
                  .then<Object?>(
                    (v) => v,
                    onError: (Object e) {
                      failedAt.add(clock.elapsed);
                      return e;
                    },
                  ),
          ];
          final outcomes = await Future.wait(callers);
          expect(outcomes, everyElement(isA<EmbedderCloseTimeoutException>()));
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(failedAt, hasLength(3));
      expect(
        failedAt.last,
        lessThan(limit * 2),
        reason:
            'the third caller failed at ${failedAt.last.inMilliseconds} '
            'ms; one shared deadline puts all three at about '
            '${limit.inMilliseconds} ms, a limit each at 600',
      );
      expect(model.closeCount, 1, reason: 'one close, waited for by all');

      // The close ends after its callers gave up: say so, once, since they
      // were told to retry.
      gate.complete();
      await pumpEventQueue();
      final announced = printed.where((l) => l.contains('finished closing'));
      expect(announced, hasLength(1));
      expect(announced.single, contains('/a'));
      expect(
        await cache.reuseOrNull(paramsFor('/b'), label: 'after'),
        isNull,
        reason: 'with the close done, the build goes ahead',
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('an embedder the app closed without awaiting is not rebuilt until its '
        'close has finished', () async {
      // `isClosed` turns true the moment close() is called, long before the
      // native model is gone. Answering "build" on that alone put two
      // engines in memory whenever an app closed its embedder and asked for
      // one again without awaiting the close.
      final cache = EmbedderCache();
      final gate = Completer<void>();
      final model = _JoiningCloseEmbedder(gate);
      cache.record(model, paramsFor('/a'));

      unawaited(model.close());
      expect(model.isClosed, isTrue);

      var answered = false;
      final rebuild = cache
          .reuseOrNull(paramsFor('/a'), label: 'after app close')
          .whenComplete(() => answered = true);
      await pumpEventQueue();
      expect(answered, isFalse, reason: 'the app\'s close is still running');

      gate.complete();
      expect(await rebuild, isNull);
      expect(
        model.teardowns,
        1,
        reason: 'the cache joined the app\'s close rather than run another',
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('EmbedderCache: a failed load still closing (R5 §4.6 step 5)', () {
    test('the next build waits for it', () async {
      final cache = EmbedderCache();
      final cleanup = Completer<void>();
      cache.trackFailedLoadCleanup(cleanup.future, paramsFor('/a'));

      var answered = false;
      final next = cache
          .reuseOrInvalidate(paramsFor('/a'), label: 'retry')
          .whenComplete(() => answered = true);
      await pumpEventQueue();
      expect(answered, isFalse, reason: 'two native models at once otherwise');

      cleanup.complete();
      expect((await next).reuse, isNull);
    });

    test('under the same bound as a replaced embedder', () async {
      final cache = EmbedderCache(
        closeWaitLimit: const Duration(milliseconds: 100),
      );
      cache.trackFailedLoadCleanup(Completer<void>().future, paramsFor('/a'));
      await expectLater(
        cache.reuseOrNull(paramsFor('/a'), label: 'retry'),
        throwsA(isA<EmbedderCloseTimeoutException>()),
      );
    });

    test('a cleanup that fails releases the wait too', () async {
      final cache = EmbedderCache();
      cache.trackFailedLoadCleanup(
        Future<void>.error(StateError('close failed')),
        paramsFor('/a'),
      );
      expect(await cache.reuseOrNull(paramsFor('/a'), label: 'retry'), isNull);
    });
  });

  group('EmbedderCache declared media (R5 §4.6)', () {
    ActiveEmbedderParams p({
      String model = '/m',
      Set<EmbeddingModality> media = const {},
    }) => ActiveEmbedderParams(
      modelPath: model,
      tokenizerPath: '/t',
      media: media,
    );

    test('a model loaded for images serves a text-only request', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, p(media: {EmbeddingModality.image}));

      final decision = await cache.reuseOrInvalidate(p(), label: 'text');
      expect(decision.reuse, same(model));
      expect(decision.build.media, {EmbeddingModality.image});
      expect(model.closeCount, 0);
    });

    test(
      'media the model lacks rebuild it with the UNION, never narrower',
      () async {
        final cache = EmbedderCache();
        final model = _FakeEmbedder();
        cache.record(model, p(media: {EmbeddingModality.image}));

        final decision = await cache.reuseOrInvalidate(
          p(media: {EmbeddingModality.audio}),
          label: 'audio',
        );
        expect(decision.reuse, isNull);
        expect(decision.build.media, {
          EmbeddingModality.image,
          EmbeddingModality.audio,
        });
        expect(decision.build.firstDifference(p()), isNull);
        expect(model.closeCount, 1, reason: 'one engine resident at a time');
      },
    );

    test('a different model builds what was asked, not a union', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, p(media: {EmbeddingModality.image}));

      final decision = await cache.reuseOrInvalidate(
        p(model: '/other', media: {EmbeddingModality.audio}),
        label: 'other',
      );
      expect(decision.reuse, isNull);
      expect(decision.build.modelPath, '/other');
      expect(decision.build.media, {EmbeddingModality.audio});
    });

    test('a closed cached model is replaced by the request alone', () async {
      final cache = EmbedderCache();
      final model = _FakeEmbedder();
      cache.record(model, p(media: {EmbeddingModality.image}));
      await model.close();

      final decision = await cache.reuseOrInvalidate(
        p(media: {EmbeddingModality.audio}),
        label: 'after close',
      );
      expect(decision.build.media, {EmbeddingModality.audio});
    });

    test(
      'a text index and an image index used alternately cause one rebuild',
      () async {
        // R5 §4.6: strict keys would close the text index's model whenever
        // the image index opened, and the other way round, for ever.
        final cache = EmbedderCache();
        var builds = 0;
        Future<EmbeddingModel> resolve(Set<EmbeddingModality> media) async {
          final decision = await cache.reuseOrInvalidate(
            p(media: media),
            label: 'index',
          );
          final reused = decision.reuse;
          if (reused != null) return reused;
          builds++;
          final built = _FakeEmbedder();
          await cache.adopt(built, decision.build);
          return built;
        }

        final first = await resolve(const {});
        final imageModel = await resolve({EmbeddingModality.image});
        for (var i = 0; i < 3; i++) {
          expect(await resolve(const {}), same(imageModel));
          expect(await resolve({EmbeddingModality.image}), same(imageModel));
        }
        expect(builds, 2, reason: 'the first build, and one widening rebuild');
        expect((first as _FakeEmbedder).closeCount, 1);
        expect(cache.params!.media, {EmbeddingModality.image});
      },
    );
  });

  group('ActiveEmbedderParams.media', () {
    ActiveEmbedderParams p([Set<EmbeddingModality> media = const {}]) =>
        ActiveEmbedderParams(modelPath: '/m', media: media);

    test('text is implied, never listed', () {
      expect(p({EmbeddingModality.text, EmbeddingModality.image}).media, {
        EmbeddingModality.image,
      });
    });

    test('identity (==, hashCode, firstDifference) ignores media', () {
      final image = p({EmbeddingModality.image});
      expect(image, p());
      expect(image.hashCode, p().hashCode);
      expect(image.firstDifference(p()), isNull);
    });

    test('canServe: same identity and covering media', () {
      final both = p({EmbeddingModality.image, EmbeddingModality.audio});
      expect(both.canServe(p({EmbeddingModality.image})), isTrue);
      expect(both.canServe(p()), isTrue);
      expect(p().canServe(p({EmbeddingModality.image})), isFalse);
      expect(both.canServe(ActiveEmbedderParams(modelPath: '/other')), isFalse);
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
        await cache.reuseOrNull(paramsFor('/b'), label: 'rebuild'),
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
        await cache.reuseOrNull(paramsFor('/a'), label: 'test'),
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
      // (a wedged native load) stalls EVERY later request on this shell,
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
            () => cache.reuseOrNull(paramsFor('/a'), label: 'retry'),
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
final class _SilentCloseEmbedder extends _FakeEmbedder {
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
final class _HostileListenerEmbedder extends _FakeEmbedder {
  _HostileListenerEmbedder({super.throwOnClose});

  @override
  void addCloseListener(void Function() listener) =>
      throw StateError('this model does not support close listeners');
}

/// The fake embedder, and the base of the others in this file (`base`, so
/// they can refine it; each of them is `final`). It never reports itself closed — the cache must learn of a
/// close from the listener — unless a subclass says otherwise.
base class _FakeEmbedder extends EmbeddingModel with CloseNotifier {
  _FakeEmbedder({this.closeGate, this.throwOnClose = false});

  final Completer<void>? closeGate;
  final bool throwOnClose;
  int closeCount = 0;

  /// True once a close has run to the end, gate included.
  bool closed = false;

  @override
  int get dimension => 1;

  @override
  bool get isClosed => false;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async => const [0.0];

  @override
  Future<void> close() async {
    closeCount++;
    if (closeGate != null) await closeGate!.future;
    closed = true;
    fireCloseListeners();
    if (throwOnClose) throw StateError('teardown failed');
  }
}

/// Closes the way `CommonEmbeddingModel` does: `isClosed` turns true at once,
/// the teardown takes as long as [_gate], and every `close()` call returns that
/// same teardown.
final class _JoiningCloseEmbedder extends _FakeEmbedder {
  _JoiningCloseEmbedder(this._gate);

  final Completer<void> _gate;
  Future<void>? _teardown;
  bool _closing = false;

  /// How many teardowns actually ran — one, however many callers closed.
  int teardowns = 0;

  @override
  bool get isClosed => _closing;

  @override
  Future<void> close() => _teardown ??= _close();

  Future<void> _close() async {
    _closing = true;
    teardowns++;
    await _gate.future;
    closed = true;
    fireCloseListeners();
  }
}
