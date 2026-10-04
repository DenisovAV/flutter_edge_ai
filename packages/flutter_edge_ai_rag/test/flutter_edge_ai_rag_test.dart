import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show
        EmbeddingModel,
        EmbeddingModelSpec,
        ModelSource,
        PreferredBackend,
        TaskType;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider registry', () {
    test(
      'selects by descending priority and stable registration order',
      () async {
        final selected = <String>[];
        final low = _FakeProvider(
          id: 'memory',
          name: 'low',
          priority: 1,
          onCreate: (_) async {
            selected.add('low');
            return _FakeStore();
          },
        );
        final highFirst = _FakeProvider(
          id: 'memory',
          name: 'high-first',
          priority: 10,
          onCreate: (_) async {
            selected.add('high-first');
            return _FakeStore();
          },
        );
        final highSecond = _FakeProvider(
          id: 'memory',
          name: 'high-second',
          priority: 10,
          onCreate: (_) async {
            selected.add('high-second');
            return _FakeStore();
          },
        );

        final rag = FlutterEdgeAiRag(providers: [low, highFirst, highSecond]);
        final index = await rag.open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        );

        expect(selected, ['high-first']);
        await index.dispose();
      },
    );

    test(
      'reports an actionable error when no provider can handle a spec',
      () async {
        final rag = FlutterEdgeAiRag(
          providers: [
            _FakeProvider(id: 'sqlite', name: 'SQLite', handles: false),
          ],
        );

        await expectLater(
          rag.open(
            spec: VectorStoreSpec(providerId: 'qdrant', location: 'index'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('qdrant'),
                contains('sqlite'),
                contains('Register'),
              ),
            ),
          ),
        );
      },
    );

    test('canOpen reports availability without throwing', () {
      final rag = FlutterEdgeAiRag(
        providers: [
          _FakeProvider(
            id: 'broken',
            name: 'Broken',
            probeError: StateError('probe'),
          ),
          _FakeProvider(id: 'memory', name: 'Memory'),
        ],
      );

      expect(
        rag.canOpen(VectorStoreSpec(providerId: 'memory', location: 'index')),
        isTrue,
      );
      expect(
        rag.canOpen(VectorStoreSpec(providerId: 'missing', location: 'index')),
        isFalse,
      );
      expect(
        rag.canOpen(VectorStoreSpec(providerId: 'broken', location: 'index')),
        isFalse,
      );
    });
  });

  group('open lifecycle', () {
    test(
      'configures before initialize and passes the requested location',
      () async {
        final store = _FakeStore();
        final schema = FilterSchema(
          fields: [
            const FilterField(name: 'lang', type: FilterFieldType.string),
          ],
        );
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'knowledge.db',
            filterSchema: schema,
          ),
        );

        expect(store.events.take(2), ['configure', 'initialize:knowledge.db']);
        expect(store.filterSchema, same(schema));
        await index.dispose();
      },
    );

    test(
      'closes on initialization failure and preserves the original error',
      () async {
        final original = _TestException('initialize failed');
        final store = _FakeStore(
          initializeError: original,
          closeError: _TestException('close failed'),
        );

        Object? caught;
        try {
          await _ragFor(store).open(
            spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          );
        } catch (error) {
          caught = error;
        }

        expect(caught, same(original));
        expect(store.closeCalls, 1);
      },
    );

    test(
      'closes on configure failure and preserves the original error',
      () async {
        final original = _TestException('configure failed');
        final store = _FakeStore(configureError: original);

        await expectLater(
          _ragFor(store).open(
            spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          ),
          throwsA(same(original)),
        );
        expect(store.closeCalls, 1);
        expect(store.initializeCalls, 0);
      },
    );
  });

  group('embedding', () {
    test(
      'active adapter resolves single-flight, pins, and never closes',
      () async {
        final specA = _embeddingSpec('a');
        final specB = _embeddingSpec('b');
        var activeSpec = specA;
        var resolveCalls = 0;
        final model = _FakeEmbeddingModel(dimension: 2);
        final modelGate = Completer<EmbeddingModel>();
        final adapter = FlutterEdgeAiActiveEmbedder(
          profileId: 'weights-a-tokenizer-a-prefix-v1',
          specResolver: () => activeSpec,
          modelResolver: () {
            resolveCalls++;
            return modelGate.future;
          },
        );

        final profileFutureA = adapter.profile;
        final profileFutureB = adapter.profile;
        final documentFuture = adapter.embedDocument('document');
        expect(resolveCalls, 1);
        modelGate.complete(model);

        final profileA = await profileFutureA;
        expect(profileA.id, 'weights-a-tokenizer-a-prefix-v1');
        expect(await profileFutureB, same(profileA));
        expect(await documentFuture, [1.0, 2.0]);
        expect(model.taskTypes, [TaskType.retrievalDocument]);

        activeSpec = specB;
        expect(await adapter.embedQuery('query'), [1.0, 2.0]);
        expect(await adapter.profile, same(profileA));
        expect(resolveCalls, 1);
        expect(model.closeCalls, 0);
        expect(model.taskTypes.last, TaskType.retrievalQuery);
      },
    );

    test('vector-only operations never resolve an embedder', () async {
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: EmbeddingProfile(id: 'unused', dimension: 2),
      );
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
        embeddingProfile: _profile2,
      );

      await index.addVector(id: 'doc', content: 'content', embedding: [1, 0]);
      await index.searchVector(embedding: [1, 0]);
      await index.stats();

      expect(embedder.profileCalls, 0);
      expect(embedder.documentCalls, 0);
      expect(embedder.queryCalls, 0);
      await index.dispose();
    });

    test('rejects an existing store with a different dimension', () async {
      final store = _FakeStore(documentCount: 3, vectorDimension: 3);
      final embedder = _FakeEmbedder(
        profileValue: EmbeddingProfile(id: 'two-dimensional', dimension: 2),
      );
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(
          providerId: 'memory',
          location: 'index',
          allowLegacyProfileAdoption: true,
        ),
        embedder: embedder,
      );

      await expectLater(
        index.addText(id: 'doc', content: 'content'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('two-dimensional'), contains('3D')),
          ),
        ),
      );
      expect(embedder.documentCalls, 0);
      await index.dispose();
    });

    test(
      'rejects generated and explicit vectors with the wrong dimension',
      () async {
        final store = _FakeStore();
        final embedder = _FakeEmbedder(
          profileValue: EmbeddingProfile(id: 'two-dimensional', dimension: 2),
          documentVector: [1],
        );
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embedder: embedder,
        );

        await expectLater(
          index.addText(id: 'doc', content: 'content'),
          throwsArgumentError,
        );
        expect(
          () => index.addVector(
            id: 'doc',
            content: 'content',
            embedding: [1, 2, 3],
          ),
          throwsArgumentError,
        );
        await index.dispose();
      },
    );

    test('active adapter retries after a failed resolution attempt', () async {
      final model = _FakeEmbeddingModel(dimension: 2);
      var attempts = 0;
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'retry-weights-tokenizer-prefix-v1',
        specResolver: () => _embeddingSpec('retry'),
        modelResolver: () async {
          attempts++;
          if (attempts == 1) throw StateError('transient');
          return model;
        },
      );

      await expectLater(adapter.profile, throwsStateError);
      expect((await adapter.profile).dimension, 2);
      expect(attempts, 2);
      expect(model.closeCalls, 0);
    });

    test('explicit IDs distinguish replacements at the same source', () async {
      final spec = _embeddingSpec('same-source');
      final model = _FakeEmbeddingModel(dimension: 2);
      FlutterEdgeAiActiveEmbedder adapter(String profileId) =>
          FlutterEdgeAiActiveEmbedder(
            profileId: profileId,
            specResolver: () => spec,
            modelResolver: () async => model,
          );

      final first = await adapter('weights-v1-contract-v1').profile;
      final replacement = await adapter('weights-v2-contract-v1').profile;

      expect(first.dimension, replacement.dimension);
      expect(first.id, isNot(replacement.id));
    });

    test('invalid explicit ID fails before resolving the model', () {
      var modelResolutions = 0;

      expect(
        () => FlutterEdgeAiActiveEmbedder(
          profileId: '   ',
          specResolver: () => _embeddingSpec('never-used'),
          modelResolver: () async {
            modelResolutions++;
            return _FakeEmbeddingModel(dimension: 2);
          },
        ),
        throwsArgumentError,
      );
      expect(modelResolutions, 0);
    });

    test(
      'rejects a text embedder with a different same-size profile',
      () async {
        final store = _FakeStore(persistedProfile: _profile2);
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embedder: _FakeEmbedder(
            profileValue: EmbeddingProfile(id: 'other', dimension: 2),
          ),
        );

        await expectLater(
          index.searchText(query: 'query'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('other'),
            ),
          ),
        );
        await index.dispose();
      },
    );
  });

  group('persistent profile binding', () {
    test('reopens with the same profile and rejects a different one', () async {
      final store = _FakeStore();
      final rag = _ragFor(store);
      final spec = VectorStoreSpec(providerId: 'memory', location: 'index');

      final first = await rag.open(spec: spec, embeddingProfile: _profile2);
      await first.dispose();
      expect(store.persistedProfile, _profile2);
      expect(store.bindCalls, 1);

      final second = await rag.open(spec: spec);
      await second.addVector(id: 'raw', content: 'raw', embedding: [1, 0]);
      await second.dispose();
      expect(store.bindCalls, 1);

      await expectLater(
        rag.open(
          spec: spec,
          embeddingProfile: EmbeddingProfile(id: 'different', dimension: 2),
        ),
        throwsStateError,
      );
      expect(store.closeCalls, 3);
    });

    test('legacy adoption is refused by default', () async {
      final store = _FakeStore(documentCount: 2, vectorDimension: 2);

      await expectLater(
        _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'legacy'),
          embeddingProfile: _profile2,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('allowLegacyProfileAdoption'),
          ),
        ),
      );
      expect(store.persistedProfile, isNull);
      expect(store.closeCalls, 1);
    });

    test('legacy adoption requires opt-in and a matching dimension', () async {
      final accepted = _FakeStore(documentCount: 2, vectorDimension: 2);
      final spec = VectorStoreSpec(
        providerId: 'memory',
        location: 'legacy',
        allowLegacyProfileAdoption: true,
      );
      final index = await _ragFor(
        accepted,
      ).open(spec: spec, embeddingProfile: _profile2);
      expect(accepted.persistedProfile, _profile2);
      await index.dispose();

      final wrongDimension = _FakeStore(documentCount: 2, vectorDimension: 3);
      await expectLater(
        _ragFor(wrongDimension).open(spec: spec, embeddingProfile: _profile2),
        throwsStateError,
      );
      expect(wrongDimension.persistedProfile, isNull);
    });

    test('raw vectors require a bound profile', () async {
      final store = _FakeStore();
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: _FakeEmbedder(profileValue: _profile2),
      );

      expect(
        () => index.addVector(id: 'raw', content: 'raw', embedding: [1, 0]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('embeddingProfile'),
          ),
        ),
      );
      expect(() => index.searchVector(embedding: [1, 0]), throwsStateError);

      await index.addText(id: 'text', content: 'text');
      expect(store.persistedProfile, _profile2);
      await index.addVector(id: 'raw', content: 'raw', embedding: [1, 0]);
      await index.dispose();
    });

    test(
      'missing active profile ID fails before text model resolution',
      () async {
        final store = _FakeStore();
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        );

        await expectLater(
          index.addText(id: 'text', content: 'text'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('activeEmbedderProfileId'),
                contains('not model identities'),
              ),
            ),
          ),
        );
        expect(store.bindCalls, 0);
        await index.dispose();
      },
    );

    test(
      'validates active fallback argument combinations before opening',
      () async {
        final store = _FakeStore();
        final rag = _ragFor(store);
        final spec = VectorStoreSpec(providerId: 'memory', location: 'index');

        await expectLater(
          rag.open(spec: spec, activeEmbedderProfileId: '  '),
          throwsArgumentError,
        );
        await expectLater(
          rag.open(
            spec: spec,
            embedder: _FakeEmbedder(profileValue: _profile2),
            activeEmbedderProfileId: _profile2.id,
          ),
          throwsArgumentError,
        );
        await expectLater(
          rag.open(
            spec: spec,
            embeddingProfile: _profile2,
            activeEmbedderProfileId: 'different',
          ),
          throwsArgumentError,
        );
        expect(store.initializeCalls, 0);
      },
    );

    test('first text bind orders raw operations and barriers', () async {
      final bindGate = Completer<void>();
      final store = _FakeStore(bindWait: bindGate.future);
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );

      final text = index.addText(id: 'text', content: 'text');
      await _pump();
      expect(store.bindCalls, 1);
      expect(embedder.profileCalls, 1);
      store.events.clear();

      final stats = index.stats();
      final remove = index.remove(id: 'old');
      final raw = index.addVector(id: 'raw', content: 'raw', embedding: [1, 0]);
      final flush = index.flush();
      final clear = index.clear();
      await _pump();

      expect(store.events, isEmpty);
      expect(store.flushCalls, 0);
      expect(store.clearCalls, 0);
      expect(store.startedAddIds, isEmpty);

      bindGate.complete();
      await text;
      await stats;
      await remove;
      await raw;
      await flush;
      await clear;

      expect(store.events, [
        'bind:end',
        'add:text',
        'stats',
        'remove:old',
        'add:raw',
        'flush',
        'clear',
      ]);
      expect(store.persistedProfile, _profile2);
      await index.dispose();
    });

    test('concurrent first text operations share one profile bind', () async {
      final bindGate = Completer<void>();
      final store = _FakeStore(bindWait: bindGate.future);
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );

      final add = index.addText(id: 'text', content: 'text');
      final search = index.searchText(query: 'query');
      await _pump();

      expect(store.bindCalls, 1);
      expect(embedder.profileCalls, 1);
      expect(embedder.queryCalls, 0);

      bindGate.complete();
      await Future.wait<Object?>([add, search]);

      expect(store.bindCalls, 1);
      expect(embedder.profileCalls, 1);
      expect(store.startedAddIds, ['text']);
      expect(embedder.queryCalls, 1);
      await index.dispose();
    });

    test('a failed first bind is shared, then a later call retries', () async {
      final store = _FakeStore(bindFailuresRemaining: 1);
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );

      final first = index.addText(id: 'first', content: 'first');
      final follower = index.searchText(query: 'follower');
      final firstFailure = expectLater(first, throwsStateError);
      final followerFailure = expectLater(follower, throwsStateError);
      await Future.wait([firstFailure, followerFailure]);

      expect(store.bindCalls, 1);
      expect(embedder.profileCalls, 1);
      expect(embedder.documentCalls, 0);
      expect(embedder.queryCalls, 0);

      await index.addText(id: 'retry', content: 'retry');
      expect(store.bindCalls, 2);
      expect(embedder.profileCalls, 2);
      expect(store.startedAddIds, ['retry']);
      await index.dispose();
    });

    test('clear preserves the persistent profile binding', () async {
      final store = _FakeStore();
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embeddingProfile: _profile2,
      );
      await index.addVector(id: 'raw', content: 'raw', embedding: [1, 0]);
      await index.clear();

      expect(store.persistedProfile, _profile2);
      expect(index.embeddingProfile, _profile2);
      await index.dispose();
    });
  });

  group('operation lifecycle', () {
    test('text operations are shared after the profile is cached', () async {
      final store = _FakeStore(blockAdds: true);
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );
      await index.searchText(query: 'prime-profile');

      final first = index.addText(id: 'first', content: 'first');
      final second = index.addText(id: 'second', content: 'second');
      await _pump();

      expect(store.activeAdds, 2);
      expect(store.bindCalls, 1);
      expect(embedder.profileCalls, 1);

      store.releaseAdds();
      await Future.wait([first, second]);
      await index.dispose();
    });

    test('normal operations overlap', () async {
      final store = _FakeStore(blockAdds: true);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embeddingProfile: _profile2,
      );

      final first = index.addVector(
        id: 'first',
        content: 'first',
        embedding: [1, 0],
      );
      final second = index.addVector(
        id: 'second',
        content: 'second',
        embedding: [0, 1],
      );
      await _pump();

      expect(store.activeAdds, 2);
      store.releaseAdds();
      await Future.wait([first, second]);
      await index.dispose();
    });

    test('flush is an exclusive barrier', () async {
      final store = _FakeStore(blockAdds: true, blockFlush: true);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embeddingProfile: _profile2,
      );

      final first = index.addVector(
        id: 'first',
        content: 'first',
        embedding: [1, 0],
      );
      await _pump();
      final flush = index.flush();
      final second = index.addVector(
        id: 'second',
        content: 'second',
        embedding: [0, 1],
      );
      await _pump();

      expect(store.flushCalls, 0);
      expect(store.startedAddIds, ['first']);
      store.releaseAdds();
      await first;
      await _pump();
      expect(store.flushCalls, 1);
      expect(store.startedAddIds, ['first']);

      store.releaseFlush();
      await flush;
      await _pump();
      expect(store.startedAddIds, ['first', 'second']);
      store.releaseAdds();
      await second;
      await index.dispose();
    });

    test(
      'addText registers before profile resolution so flush waits',
      () async {
        final profileGate = Completer<EmbeddingProfile>();
        final store = _FakeStore();
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embedder: _FakeEmbedder(
            profileValue: _profile2,
            profileFuture: profileGate.future,
          ),
        );
        store.events.clear();

        final add = index.addText(id: 'text', content: 'text');
        await _pump();
        final flush = index.flush();
        await _pump();

        expect(store.flushCalls, 0);
        profileGate.complete(_profile2);
        await add;
        await flush;
        expect(store.startedAddIds, ['text']);
        expect(store.flushCalls, 1);
        expect(store.events, [
          'stats',
          'bind:start',
          'bind:end',
          'add:text',
          'flush',
        ]);
        await index.dispose();
      },
    );

    test('addText with a cached profile stays ahead of clear', () async {
      final documentGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        documentWait: documentGate.future,
      );
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );
      await index.searchText(query: 'prime-profile');
      store.events.clear();

      final add = index.addText(id: 'text', content: 'text');
      final clear = index.clear();
      await _pump();

      expect(embedder.documentCalls, 1);
      expect(store.clearCalls, 0);
      documentGate.complete();
      await Future.wait([add, clear]);

      expect(store.events, ['add:text', 'clear']);
      await index.dispose();
    });

    test('searchText holds the shared gate until clear can run', () async {
      final queryGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        queryWait: queryGate.future,
      );
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );
      await index.addText(id: 'prime', content: 'prime');

      final search = index.searchText(query: 'blocked');
      await _pump();
      expect(embedder.queryCalls, 1);
      final clear = index.clear();
      await _pump();
      expect(store.clearCalls, 0);

      queryGate.complete();
      await search;
      await clear;
      expect(store.clearCalls, 1);
      await index.dispose();
    });

    test('searchText keeps dispose from closing its store', () async {
      final queryGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        queryWait: queryGate.future,
      );
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
        embedder: embedder,
      );

      final search = index.searchText(query: 'blocked');
      await _pump();
      final dispose = index.dispose();
      await _pump();
      expect(store.closeCalls, 0);

      queryGate.complete();
      await search;
      await dispose;
      expect(store.closeCalls, 1);
    });

    test(
      'dispose rejects new work, waits, closes once, and is idempotent',
      () async {
        final store = _FakeStore(blockAdds: true);
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embeddingProfile: _profile2,
        );
        final add = index.addVector(
          id: 'doc',
          content: 'content',
          embedding: [1, 0],
        );
        await _pump();

        final firstDispose = index.dispose();
        final secondDispose = index.dispose();
        expect(identical(firstDispose, secondDispose), isTrue);
        expect(() => index.stats(), throwsStateError);
        expect(store.closeCalls, 0);

        store.releaseAdds();
        await add;
        await firstDispose;
        expect(store.closeCalls, 1);
        expect(identical(index.dispose(), firstDispose), isTrue);
      },
    );
  });

  group('argument validation', () {
    test(
      'rejects invalid specs, profiles, searches, ids, and vectors',
      () async {
        expect(
          () => VectorStoreSpec(providerId: '', location: 'index'),
          throwsArgumentError,
        );
        expect(
          () => VectorStoreSpec(providerId: 'memory', location: '  '),
          throwsArgumentError,
        );
        expect(
          () => EmbeddingProfile(id: '', dimension: 2),
          throwsArgumentError,
        );
        expect(
          () => EmbeddingProfile(id: 'profile', dimension: 0),
          throwsArgumentError,
        );

        final index = await _ragFor(_FakeStore()).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embeddingProfile: _profile2,
        );
        expect(
          () => index.addVector(id: '', content: '', embedding: [1]),
          throwsArgumentError,
        );
        expect(
          () => index.searchVector(embedding: [1], topK: 0),
          throwsArgumentError,
        );
        expect(
          () => index.searchVector(embedding: [1], threshold: double.nan),
          throwsArgumentError,
        );
        expect(() => index.searchVector(embedding: []), throwsArgumentError);
        expect(
          () => index.searchVector(embedding: [double.infinity]),
          throwsArgumentError,
        );
        await index.dispose();
      },
    );
  });
}

final EmbeddingProfile _profile2 = EmbeddingProfile(
  id: 'test-profile',
  dimension: 2,
);

FlutterEdgeAiRag _ragFor(_FakeStore store) => FlutterEdgeAiRag(
  providers: [
    _FakeProvider(id: 'memory', name: 'Memory', onCreate: (_) async => store),
  ],
);

EmbeddingModelSpec _embeddingSpec(String name) => EmbeddingModelSpec(
  name: name,
  modelSource: ModelSource.asset('models/$name.bin'),
  tokenizerSource: ModelSource.asset('models/$name.model'),
);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

class _FakeProvider implements VectorStoreProvider {
  _FakeProvider({
    required this.id,
    required this.name,
    this.priority = 0,
    this.handles = true,
    this.probeError,
    Future<VectorStoreRepository> Function(VectorStoreSpec)? onCreate,
  }) : _onCreate = onCreate ?? ((_) async => _FakeStore());

  @override
  final String id;
  @override
  final String name;
  @override
  final int priority;
  final bool handles;
  final Object? probeError;
  final Future<VectorStoreRepository> Function(VectorStoreSpec) _onCreate;

  @override
  bool canHandle(VectorStoreSpec spec) {
    if (probeError case final error?) throw error;
    return handles;
  }

  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) =>
      _onCreate(spec);
}

class _FakeStore implements VectorStoreRepository {
  _FakeStore({
    this.documentCount = 0,
    this.vectorDimension = 0,
    this.persistedProfile,
    this.initializeError,
    this.configureError,
    this.closeError,
    this.blockAdds = false,
    this.blockFlush = false,
    this.bindWait,
    this.bindFailuresRemaining = 0,
  });

  int documentCount;
  int vectorDimension;
  EmbeddingProfile? persistedProfile;
  final Object? initializeError;
  final Object? configureError;
  final Object? closeError;
  final bool blockAdds;
  final bool blockFlush;
  final Future<void>? bindWait;
  int bindFailuresRemaining;

  @override
  bool isInitialized = false;
  @override
  FilterSchema filterSchema = const FilterSchema();
  int initializeCalls = 0;
  int closeCalls = 0;
  int flushCalls = 0;
  int clearCalls = 0;
  int bindCalls = 0;
  int activeAdds = 0;
  final List<String> events = [];
  final List<String> startedAddIds = [];
  Completer<void>? _addGate;
  Completer<void>? _flushGate;

  @override
  void configure(FilterSchema schema) {
    events.add('configure');
    if (configureError case final error?) throw error;
    filterSchema = schema;
  }

  @override
  Future<void> initialize(String location) async {
    initializeCalls++;
    events.add('initialize:$location');
    if (initializeError case final error?) throw error;
    isInitialized = true;
  }

  @override
  Future<EmbeddingProfile?> readEmbeddingProfile() async => persistedProfile;

  @override
  Future<void> bindEmbeddingProfile(EmbeddingProfile profile) async {
    final existing = persistedProfile;
    if (existing != null && existing != profile) {
      throw StateError('Profile already bound to $existing');
    }
    if (existing == null) {
      bindCalls++;
      events.add('bind:start');
      await bindWait;
      if (bindFailuresRemaining > 0) {
        bindFailuresRemaining--;
        events.add('bind:error');
        throw StateError('injected bind failure');
      }
      persistedProfile = profile;
      events.add('bind:end');
    }
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    events.add('add:$id');
    startedAddIds.add(id);
    activeAdds++;
    try {
      if (blockAdds) {
        _addGate ??= Completer<void>();
        await _addGate!.future;
      }
      documentCount++;
      vectorDimension = embedding.length;
    } finally {
      activeAdds--;
    }
  }

  void releaseAdds() {
    _addGate?.complete();
    _addGate = null;
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    events.add('search');
    return const [];
  }

  @override
  Future<void> removeDocument({required String id}) async {
    events.add('remove:$id');
    if (documentCount > 0) documentCount--;
  }

  @override
  Future<VectorStoreStats> getStats() async {
    events.add('stats');
    return VectorStoreStats(
      documentCount: documentCount,
      vectorDimension: vectorDimension,
    );
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    events.add('clear');
    documentCount = 0;
    vectorDimension = 0;
  }

  @override
  Future<void> flush() async {
    flushCalls++;
    events.add('flush');
    if (blockFlush) {
      _flushGate ??= Completer<void>();
      await _flushGate!.future;
    }
  }

  void releaseFlush() {
    _flushGate?.complete();
    _flushGate = null;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (closeError case final error?) throw error;
    isInitialized = false;
  }
}

class _FakeEmbedder implements RagEmbedder {
  _FakeEmbedder({
    required this.profileValue,
    this.documentVector,
    this.profileFuture,
    this.documentWait,
    this.queryWait,
  });

  final EmbeddingProfile profileValue;
  final List<double>? documentVector;
  final Future<EmbeddingProfile>? profileFuture;
  final Future<void>? documentWait;
  final Future<void>? queryWait;
  int profileCalls = 0;
  int documentCalls = 0;
  int queryCalls = 0;

  @override
  Future<EmbeddingProfile> get profile async {
    profileCalls++;
    return await (profileFuture ?? Future.value(profileValue));
  }

  @override
  Future<List<double>> embedDocument(String text) async {
    documentCalls++;
    await documentWait;
    return documentVector ?? List<double>.filled(profileValue.dimension, 1);
  }

  @override
  Future<List<double>> embedQuery(String text) async {
    queryCalls++;
    await queryWait;
    return List<double>.filled(profileValue.dimension, 1);
  }
}

class _FakeEmbeddingModel implements EmbeddingModel {
  _FakeEmbeddingModel({required this.dimension});

  final int dimension;
  final List<TaskType> taskTypes = [];
  int closeCalls = 0;

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  bool get isClosed => closeCalls != 0;

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    taskTypes.add(taskType);
    return [1, 2];
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    taskTypes.add(taskType);
    return [
      for (final _ in texts) [1, 2],
    ];
  }

  @override
  Future<int> getDimension() async => dimension;
}

class _TestException implements Exception {
  const _TestException(this.message);

  final String message;
}
