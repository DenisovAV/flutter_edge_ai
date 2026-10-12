import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show EmbeddingModel, EmbeddingModelSpec, ModelSource, PreferredBackend;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_rag/src/active_model_profile_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider registry', () {
    test(
      'selects by descending priority and stable registration order',
      () async {
        final selected = <String>[];
        _FakeProvider provider(String name, int priority) => _FakeProvider(
          id: 'memory',
          name: name,
          priority: priority,
          onCreate: (_) async {
            selected.add(name);
            return _FakeStore();
          },
        );

        final rag = FlutterEdgeAiRag(
          providers: [
            provider('low', 1),
            provider('high-first', 10),
            provider('high-second', 10),
          ],
        );
        final index = await rag.openVectors(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          profile: _profile2,
        );

        expect(selected, ['high-first']);
        await index.dispose();
      },
    );

    test(
      'reports an actionable error when no provider can handle a spec',
      () async {
        final embedder = _FakeEmbedder(profileValue: _profile2);
        final rag = FlutterEdgeAiRag(
          providers: [
            _FakeProvider(id: 'sqlite', name: 'SQLite', handles: false),
          ],
        );

        await expectLater(
          rag.open(
            spec: VectorStoreSpec(providerId: 'qdrant', location: 'index'),
            embedder: embedder,
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
        expect(
          embedder.profileCalls,
          0,
          reason: 'a missing provider is known before the model is loaded',
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

    test('open skips a throwing probe and uses the next provider', () async {
      final selected = <String>[];
      final rag = FlutterEdgeAiRag(
        providers: [
          _FakeProvider(
            id: 'memory',
            name: 'Broken high priority',
            priority: 10,
            probeError: StateError('probe failed'),
          ),
          _FakeProvider(
            id: 'memory',
            name: 'Working fallback',
            onCreate: (_) async {
              selected.add('fallback');
              return _FakeStore();
            },
          ),
        ],
      );
      final spec = VectorStoreSpec(providerId: 'memory', location: 'index');

      expect(rag.canOpen(spec), isTrue);
      final index = await rag.open(
        spec: spec,
        embedder: _FakeEmbedder(profileValue: _profile2),
      );

      expect(selected, ['fallback']);
      await index.dispose();
    });
  });

  group('open lifecycle', () {
    test(
      'configures before initialize and passes the requested location',
      () async {
        final store = _FakeStore();
        final schema = FilterSchema(
          fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
        );
        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'knowledge.db',
            filterSchema: schema,
          ),
          embedder: _FakeEmbedder(profileValue: _profile2),
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
            embedder: _FakeEmbedder(profileValue: _profile2),
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
          _ragFor(store).openVectors(
            spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
            profile: _profile2,
          ),
          throwsA(same(original)),
        );
        expect(store.closeCalls, 1);
        expect(store.initializeCalls, 0);
      },
    );
  });

  group('open binds the location', () {
    test(
      'resolves the profile at open and binds (profile, documents)',
      () async {
        final store = _FakeStore();
        final embedder = _FakeEmbedder(profileValue: _profile2);

        final index = await _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embedder: embedder,
        );

        expect(embedder.profileCalls, 1);
        expect(index.embeddingProfile, _profile2);
        expect(index.documents, EmbeddingModality.text);
        expect(store.cell.binding, _textBinding(_profile2));
        expect(store.bindCalls, 1);
        expect(
          embedder.documentCalls + embedder.queryCalls,
          0,
          reason: 'opening embeds nothing',
        );
        await index.dispose();
      },
    );

    test('reopens with the same binding without binding again', () async {
      final cell = _BindingCell();
      final rag = _ragForCell(cell);
      final spec = VectorStoreSpec(providerId: 'memory', location: 'index');

      await (await rag.openVectors(spec: spec, profile: _profile2)).dispose();
      final reopened = await rag.open(
        spec: spec,
        embedder: _FakeEmbedder(profileValue: _profile2),
      );

      expect(cell.binds, 1);
      expect(reopened.embeddingProfile, _profile2);
      await reopened.dispose();
    });

    test('refuses a location bound to another profile', () async {
      final store = _FakeStore()..cell.binding = _textBinding(_profile2);

      await expectLater(
        _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'kb'),
          embedder: _FakeEmbedder(
            profileValue: EmbeddingProfile(id: 'other', dimension: 2),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Vector store "kb" is bound to'),
              contains('test-profile'),
              contains('other'),
              contains('Use a different location.'),
            ),
          ),
        ),
      );
      expect(store.bindCalls, 0);
      expect(store.closeCalls, 1);
    });

    test('refuses a location bound to another document modality', () async {
      final store = _FakeStore()
        ..cell.binding = VectorStoreBinding(
          profile: _profile2,
          documents: EmbeddingModality.image,
        );

      await expectLater(
        _ragFor(store).open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'photos'),
          embedder: _FakeEmbedder(
            profileValue: _profile2,
            modalities: const {EmbeddingModality.text, EmbeddingModality.image},
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('documents: image'), contains('documents: text')),
          ),
        ),
      );
      expect(store.closeCalls, 1);
    });

    test('an embedder that cannot embed spec.documents is refused before the '
        'model loads and before the store is created', () async {
      var created = 0;
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final rag = FlutterEdgeAiRag(
        providers: [
          _FakeProvider(
            id: 'memory',
            name: 'Memory',
            onCreate: (_) async {
              created++;
              return _FakeStore();
            },
          ),
        ],
      );

      await expectLater(
        rag.open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'photos',
            documents: EmbeddingModality.image,
          ),
          embedder: embedder,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            allOf(contains('{text}'), contains('image')),
          ),
        ),
      );
      expect(embedder.profileCalls, 0);
      expect(created, 0);
    });

    test('a failing profile resolution opens nothing', () async {
      var created = 0;
      final failure = _TestException('model failed to load');
      final rag = FlutterEdgeAiRag(
        providers: [
          _FakeProvider(
            id: 'memory',
            name: 'Memory',
            onCreate: (_) async {
              created++;
              return _FakeStore();
            },
          ),
        ],
      );

      await expectLater(
        rag.open(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          embedder: _FakeEmbedder(
            profileValue: _profile2,
            profileError: failure,
          ),
        ),
        throwsA(same(failure)),
      );
      expect(created, 0);
    });

    test('a provider that does not persist the binding is refused', () async {
      final store = _FakeStore(dropBindings: true);

      await expectLater(
        _ragFor(store).openVectors(
          spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
          profile: _profile2,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('did not persist'),
          ),
        ),
      );
      expect(store.closeCalls, 1);
    });

    test(
      'a stored binding that contradicts the stored vectors is corrupt',
      () async {
        final store = _FakeStore(documentCount: 3, vectorDimension: 3)
          ..cell.binding = _textBinding(_profile2);

        await expectLater(
          _ragFor(store).openVectors(
            spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
            profile: _profile2,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('corrupted'),
            ),
          ),
        );
      },
    );

    test('two concurrent opens of one location bind it once', () async {
      final cell = _BindingCell(bindWait: Completer<void>());
      final rag = _ragForCell(cell);
      final spec = VectorStoreSpec(providerId: 'memory', location: 'index');

      final first = rag.openVectors(spec: spec, profile: _profile2);
      final second = rag.openVectors(spec: spec, profile: _profile2);
      await _pump();
      cell.bindWait!.complete();
      final indexes = await Future.wait([first, second]);

      expect(cell.binding, _textBinding(_profile2));
      expect(cell.binds, 1, reason: 'the same binding again is a no-op');
      for (final index in indexes) {
        await index.dispose();
      }
    });

    test(
      'two concurrent opens with different bindings: exactly one wins',
      () async {
        final cell = _BindingCell(bindWait: Completer<void>());
        final rag = _ragForCell(cell);

        Future<Object> attempt(EmbeddingModality documents) => rag
            .open(
              spec: VectorStoreSpec(
                providerId: 'memory',
                location: 'index',
                documents: documents,
              ),
              embedder: _FakeEmbedder(
                profileValue: _profile2,
                modalities: const {
                  EmbeddingModality.text,
                  EmbeddingModality.image,
                },
              ),
            )
            .then<Object>((index) => index, onError: (Object error) => error);

        final text = attempt(EmbeddingModality.text);
        final image = attempt(EmbeddingModality.image);
        await _pump();
        cell.bindWait!.complete();
        final outcomes = await Future.wait([text, image]);

        expect(outcomes.whereType<RagIndex>(), hasLength(1));
        expect(outcomes.whereType<VectorStoreException>(), hasLength(1));
        final winner = outcomes.whereType<RagIndex>().single;
        expect(
          cell.binding,
          VectorStoreBinding(profile: _profile2, documents: winner.documents),
        );
        await winner.dispose();
      },
    );
  });

  group('legacy adoption', () {
    test('is refused by default', () async {
      final store = _FakeStore(documentCount: 2, vectorDimension: 2);

      await expectLater(
        _ragFor(store).openVectors(
          spec: VectorStoreSpec(providerId: 'memory', location: 'legacy'),
          profile: _profile2,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('allowLegacyProfileAdoption'),
          ),
        ),
      );
      expect(store.cell.binding, isNull);
      expect(store.closeCalls, 1);
    });

    test('requires opt-in and a matching dimension', () async {
      final accepted = _FakeStore(documentCount: 2, vectorDimension: 2);
      final spec = VectorStoreSpec(
        providerId: 'memory',
        location: 'legacy',
        allowLegacyProfileAdoption: true,
      );
      final index = await _ragFor(accepted).open(
        spec: spec,
        embedder: _FakeEmbedder(profileValue: _profile2),
      );
      expect(accepted.cell.binding, _textBinding(_profile2));
      await index.dispose();

      final wrongDimension = _FakeStore(documentCount: 2, vectorDimension: 3);
      await expectLater(
        _ragFor(wrongDimension).openVectors(spec: spec, profile: _profile2),
        throwsStateError,
      );
      expect(wrongDimension.cell.binding, isNull);
    });

    test('applies to text bindings only', () async {
      expect(
        () => VectorStoreSpec(
          providerId: 'memory',
          location: 'legacy',
          allowLegacyProfileAdoption: true,
          documents: EmbeddingModality.image,
        ),
        throwsArgumentError,
      );

      final store = _FakeStore(documentCount: 2, vectorDimension: 2);
      await expectLater(
        _ragFor(store).openVectors(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'legacy',
            documents: EmbeddingModality.image,
          ),
          profile: _profile2,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('cannot be opened as image documents'),
          ),
        ),
      );
      expect(store.cell.binding, isNull);
    });
  });

  group('openVectors', () {
    test('binds the profile and spec.documents and never embeds', () async {
      final store = _FakeStore();
      final index = await _ragFor(store).openVectors(
        spec: VectorStoreSpec(
          providerId: 'memory',
          location: 'photos',
          documents: EmbeddingModality.image,
        ),
        profile: _profile2,
      );

      expect(
        store.cell.binding,
        VectorStoreBinding(
          profile: _profile2,
          documents: EmbeddingModality.image,
        ),
      );
      expect(index.documents, EmbeddingModality.image);
      await index.addVector(id: 'doc', content: 'photo.jpg', embedding: [1, 0]);
      await index.searchVector(embedding: [1, 0]);
      await _expectFailedFuture(
        () => index.add(id: 'x', document: _image, content: 'x.png'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('openVectors'),
          ),
        ),
      );
      await _expectFailedFuture(
        () => index.search(query: EmbeddingInput.text('q')),
        throwsStateError,
      );
      await index.dispose();
    });
  });

  group('add and search', () {
    test('text: embeds the document role and stores its text', () async {
      final store = _FakeStore();
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _openText(store, embedder);

      await index.add(id: 'a', document: EmbeddingInput.text('alpha'));
      await index.add(
        id: 'b',
        document: EmbeddingInput.text('cleaned beta'),
        content: 'Beta, as written',
        metadata: '{"k":1}',
      );

      expect(embedder.documents.map((d) => d.text), ['alpha', 'cleaned beta']);
      expect(store.addedContents, ['alpha', 'Beta, as written']);
      expect(store.addedMetadata, [null, '{"k":1}']);
      await index.dispose();
    });

    test('text: refuses a media document', () async {
      final index = await _openText(
        _FakeStore(),
        _FakeEmbedder(profileValue: _profile2),
      );

      await _expectFailedFuture(
        () => index.add(id: 'a', document: _image, content: 'a.png'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('holds text documents'),
          ),
        ),
      );
      await index.dispose();
    });

    test(
      'image: requires a content reference and the image modality',
      () async {
        final store = _FakeStore();
        final embedder = _FakeEmbedder(
          profileValue: _profile2,
          modalities: const {EmbeddingModality.text, EmbeddingModality.image},
        );
        final index = await _openImages(store, embedder);

        await _expectFailedFuture(
          () => index.add(id: 'a', document: _image),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              'content',
            ),
          ),
        );
        await _expectFailedFuture(
          () => index.add(id: 'a', document: _image, content: '  '),
          throwsArgumentError,
        );
        await _expectFailedFuture(
          () => index.add(
            id: 'a',
            document: EmbeddingInput.text('caption'),
            content: 'caption',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('holds image documents'),
            ),
          ),
        );
        await _expectFailedFuture(
          () => index.add(id: 'a', document: _audio, content: 'a.wav'),
          throwsArgumentError,
        );
        expect(embedder.documentCalls, 0);

        await index.add(
          id: 'a',
          document: _image,
          content: 'content://media/42',
        );
        expect(store.addedContents, ['content://media/42']);
        expect(embedder.documents.single.images, hasLength(1));
        await index.dispose();
      },
    );

    test('search sends the index documents as the query context', () async {
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        modalities: const {EmbeddingModality.text, EmbeddingModality.image},
      );
      final index = await _openImages(store, embedder);

      await index.search(query: EmbeddingInput.text('a red bicycle'));
      await index.search(query: _image);

      expect(embedder.queryDocumentModalities, [
        EmbeddingModality.image,
        EmbeddingModality.image,
      ]);
      expect(embedder.queries.first.text, 'a red bicycle');
      expect(store.queryEmbeddings, hasLength(2));
      await index.dispose();
    });

    test(
      'search refuses a query modality the embedder does not embed',
      () async {
        final embedder = _FakeEmbedder(profileValue: _profile2);
        final index = await _openText(_FakeStore(), embedder);

        await _expectFailedFuture(
          () => index.search(query: _image),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              allOf(contains('{image}'), contains('{text}')),
            ),
          ),
        );
        expect(embedder.queryCalls, 0);
        await index.dispose();
      },
    );

    test(
      'embedded and explicit vectors must match the bound dimension',
      () async {
        final embedder = _FakeEmbedder(
          profileValue: _profile2,
          documentVector: [1],
        );
        final index = await _openText(_FakeStore(), embedder);

        await expectLater(
          index.add(id: 'doc', document: EmbeddingInput.text('content')),
          throwsArgumentError,
        );
        await _expectFailedFuture(
          () => index.addVector(
            id: 'doc',
            content: 'content',
            embedding: [1, 2, 3],
          ),
          throwsArgumentError,
        );
        await _expectFailedFuture(
          () => index.searchVector(embedding: [1, 2, 3]),
          throwsArgumentError,
        );
        await index.dispose();
      },
    );

    test('embedder failures reach the caller unchanged', () async {
      final failure = EmbeddingInputTooLongException(
        'too long',
        maxInputTokens: 256,
        actualTokens: 300,
      );
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        documentError: failure,
      );
      final store = _FakeStore();
      final index = await _openText(store, embedder);

      await expectLater(
        index.add(id: 'doc', document: EmbeddingInput.text('long')),
        throwsA(same(failure)),
      );
      expect(store.startedAddIds, isEmpty);
      await index.dispose();
    });
  });

  group('filters', () {
    final schema = FilterSchema(
      fields: [
        FilterField(name: 'lang', type: FilterFieldType.string),
        FilterField(name: 'year', type: FilterFieldType.number),
      ],
    );

    Future<(RagIndex, _FakeStore, _FakeEmbedder)> open() async {
      final store = _FakeStore();
      final embedder = _FakeEmbedder(profileValue: _profile2);
      final index = await _ragFor(store).open(
        spec: VectorStoreSpec(
          providerId: 'memory',
          location: 'index',
          filterSchema: schema,
        ),
        embedder: embedder,
      );
      return (index, store, embedder);
    }

    test('declared fields pass through to the store', () async {
      final (index, store, _) = await open();
      final filter = Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
        should: [FieldRange(key: 'year', gte: 2000)],
        mustNot: [
          FieldMatchAny(key: 'lang', values: const ['fr']),
        ],
      );

      await index.search(query: EmbeddingInput.text('q'), filter: filter);
      await index.searchVector(embedding: [1, 0], filter: filter);

      expect(store.filters, [same(filter), same(filter)]);
      await index.dispose();
    });

    for (final (clause, filter) in [
      (
        'must',
        Filter(
          must: [FieldEquals(key: 'author', value: 'x')],
        ),
      ),
      ('should', Filter(should: [FieldRange(key: 'pages', lte: 3)])),
      (
        'mustNot',
        Filter(
          mustNot: [
            FieldMatchAny(key: 'tag', values: const ['a']),
          ],
        ),
      ),
    ]) {
      test('an undeclared field in $clause is an ArgumentError', () async {
        final (index, store, embedder) = await open();

        await _expectFailedFuture(
          () => index.search(query: EmbeddingInput.text('q'), filter: filter),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              allOf(contains('not declared'), contains('lang, year')),
            ),
          ),
        );
        await _expectFailedFuture(
          () => index.searchVector(embedding: [1, 0], filter: filter),
          throwsArgumentError,
        );
        expect(embedder.queryCalls, 0);
        expect(store.filters, isEmpty);
        await index.dispose();
      });
    }
  });

  group('FlutterEdgeAiActiveEmbedder', () {
    test('role policy: document, text query, cross-modal and media', () async {
      final model = _FakeEmbeddingModel(dimension: 2);
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        supportImage: true,
        specResolver: () => _spec,
        modelResolver: () async => model,
      );

      await adapter.embedDocument(EmbeddingInput.text('doc'));
      await adapter.embedDocument(_image);
      await adapter.embedQuery(
        EmbeddingInput.text('q'),
        documentModality: EmbeddingModality.text,
      );
      await adapter.embedQuery(
        EmbeddingInput.text('q'),
        documentModality: EmbeddingModality.image,
      );
      await adapter.embedQuery(
        _image,
        documentModality: EmbeddingModality.image,
      );
      await adapter.embedQuery(
        _image,
        documentModality: EmbeddingModality.text,
      );

      expect(model.taskTypes, [
        TaskType.retrievalDocument,
        TaskType.retrievalDocument,
        TaskType.retrievalQuery,
        TaskType.none,
        TaskType.none,
        TaskType.none,
      ]);
    });

    test(
      'queryTask applies to text queries over text documents only',
      () async {
        final model = _FakeEmbeddingModel(dimension: 2);
        final adapter = FlutterEdgeAiActiveEmbedder(
          profileId: 'eg-v1',
          supportImage: true,
          queryTask: TaskType.questionAnswering,
          specResolver: () => _spec,
          modelResolver: () async => model,
        );

        await adapter.embedQuery(
          EmbeddingInput.text('q'),
          documentModality: EmbeddingModality.text,
        );
        await adapter.embedQuery(
          EmbeddingInput.text('q'),
          documentModality: EmbeddingModality.image,
        );
        await adapter.embedDocument(EmbeddingInput.text('d'));

        expect(model.taskTypes, [
          TaskType.questionAnswering,
          TaskType.none,
          TaskType.retrievalDocument,
        ]);
      },
    );

    test('modalities are text plus the declared media', () {
      FlutterEdgeAiActiveEmbedder adapter({
        bool image = false,
        bool audio = false,
      }) => FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        supportImage: image,
        supportAudio: audio,
        specResolver: () => _spec,
        modelResolver: () async => _FakeEmbeddingModel(dimension: 2),
      );

      expect(adapter().modalities, {EmbeddingModality.text});
      expect(adapter(image: true).modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      expect(adapter(image: true, audio: true).modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
        EmbeddingModality.audio,
      });
    });

    test('resolves the model per operation and never closes it', () async {
      final first = _FakeEmbeddingModel(dimension: 2);
      final replacement = _FakeEmbeddingModel(dimension: 2);
      var current = first;
      var resolutions = 0;
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => _spec,
        modelResolver: () async {
          resolutions++;
          return current;
        },
      );

      expect(await adapter.resolveProfile(), _profileNamed('eg-v1', 2));
      await adapter.embedDocument(EmbeddingInput.text('a'));
      current = replacement;
      await adapter.embedDocument(EmbeddingInput.text('b'));

      expect(resolutions, 3);
      expect(first.taskTypes, hasLength(1));
      expect(replacement.taskTypes, hasLength(1));
      expect(first.closeCalls + replacement.closeCalls, 0);
    });

    test(
      'a request that never ran is retried once on the replacement',
      () async {
        final closed = _FakeEmbeddingModel(
          dimension: 2,
          failWith: const EmbedderClosedException(),
        );
        final replacement = _FakeEmbeddingModel(dimension: 2);
        final models = [closed, replacement];
        var resolutions = 0;
        final adapter = FlutterEdgeAiActiveEmbedder(
          profileId: 'eg-v1',
          specResolver: () => _spec,
          modelResolver: () async => models[resolutions++],
        );

        expect(await adapter.embedDocument(EmbeddingInput.text('a')), [1, 2]);
        expect(resolutions, 2);
        expect(closed.taskTypes, [TaskType.retrievalDocument]);
        expect(replacement.taskTypes, [TaskType.retrievalDocument]);
      },
    );

    test('retries only once, and only on EmbedderClosedException', () async {
      var resolutions = 0;
      final alwaysClosed = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => _spec,
        modelResolver: () async {
          resolutions++;
          return _FakeEmbeddingModel(
            dimension: 2,
            failWith: const EmbedderClosedException(),
          );
        },
      );
      await expectLater(
        alwaysClosed.embedQuery(
          EmbeddingInput.text('q'),
          documentModality: EmbeddingModality.text,
        ),
        throwsA(isA<EmbedderClosedException>()),
      );
      expect(resolutions, 2);

      resolutions = 0;
      final failure = EmbeddingEngineException('boom', engine: 'fake');
      final failing = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => _spec,
        modelResolver: () async {
          resolutions++;
          return _FakeEmbeddingModel(dimension: 2, failWith: failure);
        },
      );
      await expectLater(
        failing.embedDocument(EmbeddingInput.text('d')),
        throwsA(same(failure)),
      );
      expect(resolutions, 1, reason: 'an engine failure may have run');
    });

    test('pins the active spec it was created with', () async {
      final specA = _embeddingSpec('a');
      final specB = _embeddingSpec('b');
      var active = specA;
      var resolutions = 0;
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => active,
        modelResolver: () async {
          resolutions++;
          return _FakeEmbeddingModel(dimension: 2);
        },
      );

      await adapter.resolveProfile();
      active = specB;
      await expectLater(
        adapter.embedDocument(EmbeddingInput.text('d')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('changed after'),
          ),
        ),
      );
      await expectLater(adapter.resolveProfile(), throwsStateError);
      expect(resolutions, 1);

      active = specA;
      expect(await adapter.resolveProfile(), _profileNamed('eg-v1', 2));
    });

    group('the pin compares the installed model, not credentials', () {
      const base = 'https://huggingface.co/acme/embedder/resolve/abc123';
      EmbeddingModelSpec network({String? token, String model = 'm'}) =>
          EmbeddingModelSpec(
            name: model,
            modelSource: ModelSource.network(
              '$base/$model.tflite',
              authToken: token,
            ),
            tokenizerSource: ModelSource.network(
              '$base/tokenizer.json',
              authToken: token,
            ),
            modelFilename: '${model}__rev-abc123.tflite',
            tokenizerFilename: '${model}__rev-abc123.json',
          );

      Future<int> embedsAfterSwitch(
        EmbeddingModelSpec pinned,
        EmbeddingModelSpec active,
      ) async {
        var current = pinned;
        final model = _FakeEmbeddingModel(dimension: 2);
        final adapter = FlutterEdgeAiActiveEmbedder(
          profileId: 'eg-v1',
          specResolver: () => current,
          modelResolver: () async => model,
        );
        current = active;
        await adapter.embedDocument(EmbeddingInput.text('d'));
        return model.taskTypes.length;
      }

      test('a restart restores the spec without the token; a re-install '
          'with the token is the same model', () async {
        // ModelSource.encode() drops credentials, so the restored spec has
        // no authToken while the app's next install() passes one.
        expect(
          await embedsAfterSwitch(network(), network(token: 'hf_secret')),
          1,
        );
        expect(
          await embedsAfterSwitch(
            network(token: 'hf_a'),
            network(token: 'hf_b'),
          ),
          1,
        );
      });

      test('a native restore points at the installed files', () async {
        // The native shell restores the spec as the persisted record's
        // toSpec(runtimeModelSource: FileSource(...), ...) does: FileSources
        // at the managed paths, the explicit file names kept.
        final restored = EmbeddingModelSpec(
          name: 'm',
          modelSource: ModelSource.file(
            '/data/app/flutter_gemma/m__rev-abc123.tflite',
          ),
          tokenizerSource: ModelSource.file(
            '/data/app/flutter_gemma/m__rev-abc123.json',
          ),
          modelFilename: 'm__rev-abc123.tflite',
          tokenizerFilename: 'm__rev-abc123.json',
        );
        expect(
          await embedsAfterSwitch(restored, network(token: 'hf_secret')),
          1,
        );
      });

      test('a native restore of source-derived file names', () async {
        // No explicit file names: the installed names derive from the URLs,
        // and the restored FileSources at those names derive the same ones.
        final installed = EmbeddingModelSpec(
          name: 'm',
          modelSource: ModelSource.network(
            '$base/m.tflite',
            authToken: 'hf_secret',
          ),
          tokenizerSource: ModelSource.network(
            '$base/tokenizer.json',
            authToken: 'hf_secret',
          ),
        );
        final names = [for (final file in installed.files) file.filename];
        final restored = EmbeddingModelSpec(
          name: 'm',
          modelSource: ModelSource.file('/data/app/flutter_gemma/${names[0]}'),
          tokenizerSource: ModelSource.file(
            '/data/app/flutter_gemma/${names[1]}',
          ),
        );
        expect([for (final file in restored.files) file.filename], names);
        expect(await embedsAfterSwitch(restored, installed), 1);
      });

      test('a different model is still refused', () async {
        await expectLater(
          embedsAfterSwitch(network(), network(token: 't', model: 'other')),
          throwsStateError,
          reason: 'other file names',
        );
        final otherUrl = EmbeddingModelSpec(
          name: 'm',
          modelSource: ModelSource.network('$base/m-v2.tflite'),
          tokenizerSource: ModelSource.network('$base/tokenizer.json'),
          modelFilename: 'm__rev-abc123.tflite',
          tokenizerFilename: 'm__rev-abc123.json',
        );
        await expectLater(
          embedsAfterSwitch(network(), otherUrl),
          throwsStateError,
          reason: 'same file names, a different URL',
        );
        final restoredFiles = EmbeddingModelSpec(
          name: 'm',
          modelSource: ModelSource.file('/app/m__rev-abc123.tflite'),
          tokenizerSource: ModelSource.file('/app/m__rev-abc123.json'),
          modelFilename: 'm__rev-abc123.tflite',
          tokenizerFilename: 'm__rev-abc123.json',
        );
        await expectLater(
          embedsAfterSwitch(
            restoredFiles,
            network(token: 'hf_secret', model: 'other'),
          ),
          throwsStateError,
          reason: 'a restored model, then a different one installed',
        );
      });
    });

    test('a switch while the model resolves is refused', () async {
      var active = _embeddingSpec('a');
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => active,
        modelResolver: () async {
          active = _embeddingSpec('b');
          return _FakeEmbeddingModel(dimension: 2);
        },
      );

      await expectLater(
        adapter.resolveProfile(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('while the RAG embedder was being resolved'),
          ),
        ),
      );
    });

    test('no active model at construction fails every operation', () async {
      var resolutions = 0;
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => null,
        modelResolver: () async {
          resolutions++;
          return _FakeEmbeddingModel(dimension: 2);
        },
      );

      await expectLater(
        adapter.resolveProfile(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('No active embedding model'),
          ),
        ),
      );
      await expectLater(
        adapter.embedDocument(EmbeddingInput.text('d')),
        throwsStateError,
      );
      expect(resolutions, 0);
    });

    test('a failed resolution is not cached', () async {
      final model = _FakeEmbeddingModel(dimension: 2);
      var attempts = 0;
      final adapter = FlutterEdgeAiActiveEmbedder(
        profileId: 'eg-v1',
        specResolver: () => _spec,
        modelResolver: () async {
          attempts++;
          if (attempts == 1) throw StateError('transient');
          return model;
        },
      );

      await expectLater(adapter.resolveProfile(), throwsStateError);
      expect((await adapter.resolveProfile()).dimension, 2);
      expect(attempts, 2);
    });

    test('explicit ids distinguish replacements at the same source', () async {
      FlutterEdgeAiActiveEmbedder adapter(String profileId) =>
          FlutterEdgeAiActiveEmbedder(
            profileId: profileId,
            specResolver: () => _spec,
            modelResolver: () async => _FakeEmbeddingModel(dimension: 2),
          );

      final first = await adapter('weights-v1-contract-v1').resolveProfile();
      final replacement = await adapter(
        'weights-v2-contract-v1',
      ).resolveProfile();

      expect(first.dimension, replacement.dimension);
      expect(first.id, isNot(replacement.id));
    });

    test('an invalid profile id fails at construction', () {
      var resolutions = 0;
      Future<EmbeddingModel> resolver() async {
        resolutions++;
        return _FakeEmbeddingModel(dimension: 2);
      }

      for (final id in ['', '   ', 'eg\u001Fimage', 'tab\there']) {
        expect(
          () => FlutterEdgeAiActiveEmbedder(
            profileId: id,
            specResolver: () => _spec,
            modelResolver: resolver,
          ),
          throwsArgumentError,
          reason: 'profileId ${id.codeUnits}',
        );
      }
      expect(resolutions, 0);
    });
  });

  group('profile ids', () {
    test('EmbeddingProfile refuses every control character', () {
      for (var unit = 0; unit <= 0x1F; unit++) {
        expect(
          () => EmbeddingProfile(
            id: 'a${String.fromCharCode(unit)}b',
            dimension: 2,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('control characters'),
            ),
          ),
          reason: 'U+${unit.toRadixString(16)}',
        );
      }
      for (final id in ['a b', 'a\u007Fb', 'é-768', 'ns@a.tflite+b.json']) {
        expect(EmbeddingProfile(id: id, dimension: 2).id, id);
      }
      expect(() => EmbeddingProfile(id: '', dimension: 2), throwsArgumentError);
      expect(
        () => EmbeddingProfile(id: 'profile', dimension: 0),
        throwsArgumentError,
      );
    });

    test('forActiveModel derives <namespace>@<files joined by +>', () {
      final twoFile = EmbeddingModelSpec(
        name: 'eg1',
        modelSource: ModelSource.asset('models/embeddinggemma.tflite'),
        tokenizerSource: ModelSource.asset('models/sentencepiece.model'),
        modelFilename: 'eg1__rev-29888f.tflite',
        tokenizerFilename: 'eg1__rev-29888f.model',
      );
      final bundle = EmbeddingModelSpec(
        name: 'eg2',
        modelSource: ModelSource.asset('models/embeddinggemma-2.litertlm'),
      );

      expect(
        activeModelProfileId(namespace: 'kb', spec: twoFile),
        'kb@eg1__rev-29888f.tflite+eg1__rev-29888f.model',
      );
      expect(
        activeModelProfileId(namespace: 'kb', spec: bundle),
        'kb@embeddinggemma-2.litertlm',
      );
      final ids = {
        activeModelProfileId(namespace: 'kb', spec: twoFile),
        activeModelProfileId(namespace: 'kb', spec: bundle),
        activeModelProfileId(namespace: 'photos', spec: bundle),
      };
      expect(ids, hasLength(3));
      for (final id in ids) {
        expect(EmbeddingProfile(id: id, dimension: 768).id, id);
      }
    });

    test('forActiveModel ids are injective over delimiter-bearing names', () {
      EmbeddingModelSpec bundle(String file) => EmbeddingModelSpec(
        name: file,
        modelSource: ModelSource.asset('models/any.litertlm'),
        modelFilename: file,
      );
      EmbeddingModelSpec pair(String model, String tokenizer) =>
          EmbeddingModelSpec(
            name: model,
            modelSource: ModelSource.asset('models/any.tflite'),
            tokenizerSource: ModelSource.asset('models/any.json'),
            modelFilename: model,
            tokenizerFilename: tokenizer,
          );

      // Each pair spells the same id when nothing is escaped.
      final cases = {
        'kb@x | y': (namespace: 'kb@x', spec: bundle('y.litertlm')),
        'kb | x@y': (namespace: 'kb', spec: bundle('x@y.litertlm')),
        'm+x | t': (namespace: 'kb', spec: pair('m+x.tflite', 't.json')),
        'm | x+t': (namespace: 'kb', spec: pair('m', 'x.tflite+t.json')),
        'literal %2B': (namespace: 'kb', spec: bundle('a%2Bb.litertlm')),
        'plus': (namespace: 'kb', spec: bundle('a+b.litertlm')),
        'tab in namespace': (namespace: 'k\tb', spec: bundle('a.litertlm')),
      };
      final ids = {
        for (final MapEntry(key: name, value: c) in cases.entries)
          name: activeModelProfileId(namespace: c.namespace, spec: c.spec),
      };

      expect(ids.values.toSet(), hasLength(cases.length), reason: '$ids');
      expect(ids['kb@x | y'], 'kb%40x@y.litertlm');
      expect(ids['kb | x@y'], 'kb@x%40y.litertlm');
      expect(ids['m+x | t'], 'kb@m%2Bx.tflite+t.json');
      expect(ids['m | x+t'], 'kb@m+x.tflite%2Bt.json');
      expect(ids['literal %2B'], 'kb@a%252Bb.litertlm');
      expect(ids['plus'], 'kb@a%2Bb.litertlm');
      expect(ids['tab in namespace'], 'k%09b@a.litertlm');
      for (final id in ids.values) {
        expect(EmbeddingProfile(id: id, dimension: 768).id, id);
      }
    });
  });

  group('VectorStoreBinding', () {
    test('v1RecordId qualifies image and audio, never text', () {
      VectorStoreBinding binding(EmbeddingModality documents) =>
          VectorStoreBinding(profile: _profile2, documents: documents);

      expect(binding(EmbeddingModality.text).v1RecordId, 'test-profile');
      expect(
        binding(EmbeddingModality.image).v1RecordId,
        'test-profile\u001Fimage',
      );
      expect(
        binding(EmbeddingModality.audio).v1RecordId,
        'test-profile\u001Faudio',
      );
      expect(
        VectorStoreBinding(profile: _profile2).documents,
        EmbeddingModality.text,
      );
    });

    test('fromV1Record inverts v1RecordId for every modality', () {
      for (final documents in EmbeddingModality.values) {
        final binding = VectorStoreBinding(
          profile: _profile2,
          documents: documents,
        );
        expect(
          VectorStoreBinding.fromV1Record(id: binding.v1RecordId, dimension: 2),
          binding,
        );
      }
    });

    test('an unknown qualifier was written by a newer version', () {
      for (final qualifier in ['video', 'text', 'image\u001Fx', '']) {
        expect(
          () => VectorStoreBinding.fromV1Record(
            id: 'test-profile\u001F$qualifier',
            dimension: 2,
          ),
          throwsA(
            isA<VectorStoreException>().having(
              (error) => error.message,
              'message',
              allOf(contains('newer version'), contains(r'\u001F')),
            ),
          ),
          reason: 'qualifier "$qualifier"',
        );
      }
    });

    test('a record that is not a valid profile is a VectorStoreException', () {
      for (final (id, dimension) in [
        ('\u001Fimage', 2),
        ('ok', 0),
        ('bad\tid', 2),
      ]) {
        expect(
          () => VectorStoreBinding.fromV1Record(id: id, dimension: dimension),
          throwsA(
            isA<VectorStoreException>().having(
              (error) => error.message,
              'message',
              contains('not a valid embedding profile'),
            ),
          ),
          reason: 'record ($id, $dimension)',
        );
      }
      // A rag 1.0 id with a control character: the message says why.
      expect(
        () => VectorStoreBinding.fromV1Record(id: 'tab\tid', dimension: 2),
        throwsA(
          isA<VectorStoreException>().having(
            (error) => error.message,
            'message',
            allOf(contains(r'tab\u0009id'), contains('1.0 accepted control')),
          ),
        ),
      );
    });

    test('equality covers the profile and the documents', () {
      final text = VectorStoreBinding(profile: _profile2);
      final image = VectorStoreBinding(
        profile: _profile2,
        documents: EmbeddingModality.image,
      );

      expect(
        text,
        VectorStoreBinding(profile: _profileNamed('test-profile', 2)),
      );
      expect(text.hashCode, VectorStoreBinding(profile: _profile2).hashCode);
      expect(text, isNot(image));
      expect(
        text,
        isNot(VectorStoreBinding(profile: _profileNamed('test-profile', 3))),
      );
      expect(image.toString(), contains('documents: image'));
    });
  });

  group('operation lifecycle', () {
    test('normal operations overlap', () async {
      final store = _FakeStore(blockAdds: true);
      final index = await _openVectors(store);

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

    test('embedding operations overlap', () async {
      final store = _FakeStore(blockAdds: true);
      final index = await _openText(
        store,
        _FakeEmbedder(profileValue: _profile2),
      );

      final first = index.add(id: 'first', document: EmbeddingInput.text('1'));
      final second = index.add(
        id: 'second',
        document: EmbeddingInput.text('2'),
      );
      await _pump();

      expect(store.activeAdds, 2);
      store.releaseAdds();
      await Future.wait([first, second]);
      await index.dispose();
    });

    test('raw vector operations snapshot vectors before queueing', () async {
      final store = _FakeStore(blockFlush: true);
      final index = await _openVectors(store);

      final flush = index.flush();
      await _pump();
      final addVector = <double>[1, 0];
      final queryVector = <double>[0, 1];
      final add = index.addVector(
        id: 'doc',
        content: 'content',
        embedding: addVector,
      );
      final search = index.searchVector(embedding: queryVector);
      addVector[0] = 9;
      queryVector[0] = 9;

      store.releaseFlush();
      await Future.wait<void>([flush, add, search.then((_) {})]);

      expect(store.addedEmbeddings, [
        [1.0, 0.0],
      ]);
      expect(store.queryEmbeddings, [
        [0.0, 1.0],
      ]);
      await index.dispose();
    });

    test('flush is an exclusive barrier', () async {
      final store = _FakeStore(blockAdds: true, blockFlush: true);
      final index = await _openVectors(store);

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

    test('add stays ahead of a later clear while it embeds', () async {
      final documentGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        documentWait: documentGate.future,
      );
      final index = await _openText(store, embedder);
      store.events.clear();

      final add = index.add(id: 'text', document: EmbeddingInput.text('text'));
      final clear = index.clear();
      await _pump();

      expect(embedder.documentCalls, 1);
      expect(store.clearCalls, 0);
      documentGate.complete();
      await Future.wait([add, clear]);

      expect(store.events, ['add:text', 'clear']);
      await index.dispose();
    });

    test('search holds the shared gate until clear can run', () async {
      final queryGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        queryWait: queryGate.future,
      );
      final index = await _openText(store, embedder);

      final search = index.search(query: EmbeddingInput.text('blocked'));
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

    test('search keeps dispose from closing its store', () async {
      final queryGate = Completer<void>();
      final store = _FakeStore();
      final embedder = _FakeEmbedder(
        profileValue: _profile2,
        queryWait: queryGate.future,
      );
      final index = await _openText(store, embedder);

      final search = index.search(query: EmbeddingInput.text('blocked'));
      await _pump();
      final dispose = index.dispose();
      await _pump();
      expect(store.closeCalls, 0);

      queryGate.complete();
      await search;
      await dispose;
      expect(store.closeCalls, 1);
    });

    test('clear preserves the binding', () async {
      final store = _FakeStore();
      final index = await _openVectors(store);
      await index.addVector(id: 'raw', content: 'raw', embedding: [1, 0]);
      await index.clear();

      expect(store.cell.binding, _textBinding(_profile2));
      expect(index.embeddingProfile, _profile2);
      await index.dispose();
    });

    test(
      'dispose rejects new work, waits, closes once, and is idempotent',
      () async {
        final store = _FakeStore(blockAdds: true);
        final index = await _openVectors(store);
        final add = index.addVector(
          id: 'doc',
          content: 'content',
          embedding: [1, 0],
        );
        await _pump();

        final firstDispose = index.dispose();
        final secondDispose = index.dispose();
        expect(identical(firstDispose, secondDispose), isTrue);
        await _expectFailedFuture(() => index.stats(), throwsStateError);
        await _expectFailedFuture(
          () => index.add(id: 'late', document: EmbeddingInput.text('x')),
          throwsStateError,
        );
        expect(store.closeCalls, 0);

        store.releaseAdds();
        await add;
        await firstDispose;
        expect(store.closeCalls, 1);
        expect(identical(index.dispose(), firstDispose), isTrue);
      },
    );
  });

  group('errors arrive as failed futures', () {
    test('every Future-returning member of FlutterEdgeAiRag', () async {
      final rag = FlutterEdgeAiRag(
        providers: [_FakeProvider(id: 'memory', name: 'Memory')],
      );
      final missing = VectorStoreSpec(providerId: 'none', location: 'x');
      await _expectFailedFuture(
        () => rag.open(
          spec: missing,
          embedder: _FakeEmbedder(profileValue: _profile2),
        ),
        throwsStateError,
      );
      await _expectFailedFuture(
        () => rag.openVectors(spec: missing, profile: _profile2),
        throwsStateError,
      );
      await _expectFailedFuture(
        () => rag.open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'photos',
            documents: EmbeddingModality.image,
          ),
          embedder: _FakeEmbedder(profileValue: _profile2),
        ),
        throwsArgumentError,
      );
    });

    test('every Future-returning member of a disposed RagIndex', () async {
      final index = await _openText(
        _FakeStore(),
        _FakeEmbedder(profileValue: _profile2),
      );
      await index.dispose();

      final calls = <String, Future<Object?> Function()>{
        'add': () => index.add(id: 'a', document: EmbeddingInput.text('a')),
        'addVector': () =>
            index.addVector(id: 'a', content: 'a', embedding: [1, 0]),
        'search': () => index.search(query: EmbeddingInput.text('q')),
        'searchVector': () => index.searchVector(embedding: [1, 0]),
        'remove': () => index.remove(id: 'a'),
        'stats': index.stats,
        'flush': index.flush,
        'clear': index.clear,
      };
      for (final MapEntry(key: name, value: call) in calls.entries) {
        await _expectFailedFuture(
          call,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              '$name message',
              contains('disposing or already disposed'),
            ),
          ),
        );
      }
      expect(identical(index.dispose(), index.dispose()), isTrue);
    });

    test('a vector-only index fails add and search as futures', () async {
      final index = await _openVectors(_FakeStore());
      await _expectFailedFuture(
        () => index.add(id: 'a', document: EmbeddingInput.text('a')),
        throwsStateError,
      );
      await _expectFailedFuture(
        () => index.search(query: EmbeddingInput.text('q')),
        throwsStateError,
      );
      await index.dispose();
    });
  });

  group('argument validation', () {
    test('rejects invalid specs, searches, ids, and vectors', () async {
      expect(
        () => VectorStoreSpec(providerId: '', location: 'index'),
        throwsArgumentError,
      );
      expect(
        () => VectorStoreSpec(providerId: 'memory', location: '  '),
        throwsArgumentError,
      );

      final index = await _openText(
        _FakeStore(),
        _FakeEmbedder(profileValue: _profile2),
      );
      await _expectFailedFuture(
        () => index.addVector(id: '', content: '', embedding: [1, 0]),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.add(id: ' ', document: EmbeddingInput.text('x')),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.searchVector(embedding: [1, 0], topK: 0),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.search(query: EmbeddingInput.text('q'), topK: 0),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.searchVector(embedding: [1, 0], threshold: double.nan),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.searchVector(embedding: []),
        throwsArgumentError,
      );
      await _expectFailedFuture(
        () => index.searchVector(embedding: [double.infinity, 0]),
        throwsArgumentError,
      );
      await index.dispose();
    });
  });
}

/// The repo rule for asynchronous APIs: every error arrives as a FAILED
/// FUTURE, never as a synchronous throw. `expect(() => f(), throwsA(m))`
/// cannot tell the two apart (it awaits a returned future), so this checks
/// both halves: the call returns normally, then its future fails with
/// [matcher].
Future<void> _expectFailedFuture(
  Future<Object?> Function() call,
  Matcher matcher,
) async {
  late Future<Object?> future;
  expect(
    () {
      future = call();
    },
    returnsNormally,
    reason: 'an asynchronous API must not throw synchronously',
  );
  await expectLater(future, matcher);
}

final EmbeddingProfile _profile2 = EmbeddingProfile(
  id: 'test-profile',
  dimension: 2,
);

EmbeddingProfile _profileNamed(String id, int dimension) =>
    EmbeddingProfile(id: id, dimension: dimension);

VectorStoreBinding _textBinding(EmbeddingProfile profile) =>
    VectorStoreBinding(profile: profile);

final EmbeddingModelSpec _spec = _embeddingSpec('active');

final EmbeddingInput _image = EmbeddingInput.image(
  Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
);

final EmbeddingInput _audio = EmbeddingInput.audio(
  Uint8List.fromList('RIFF\u0000\u0000\u0000\u0000WAVE'.codeUnits),
);

FlutterEdgeAiRag _ragFor(_FakeStore store) => FlutterEdgeAiRag(
  providers: [
    _FakeProvider(id: 'memory', name: 'Memory', onCreate: (_) async => store),
  ],
);

/// Every opened store shares [cell]: one durable location, several handles.
FlutterEdgeAiRag _ragForCell(_BindingCell cell) => FlutterEdgeAiRag(
  providers: [
    _FakeProvider(
      id: 'memory',
      name: 'Memory',
      onCreate: (_) async => _FakeStore(cell: cell),
    ),
  ],
);

Future<RagIndex> _openText(_FakeStore store, _FakeEmbedder embedder) =>
    _ragFor(store).open(
      spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
      embedder: embedder,
    );

Future<RagIndex> _openImages(_FakeStore store, _FakeEmbedder embedder) =>
    _ragFor(store).open(
      spec: VectorStoreSpec(
        providerId: 'memory',
        location: 'photos',
        documents: EmbeddingModality.image,
      ),
      embedder: embedder,
    );

Future<RagIndex> _openVectors(_FakeStore store) => _ragFor(store).openVectors(
  spec: VectorStoreSpec(providerId: 'memory', location: 'index'),
  profile: _profile2,
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

/// The durable binding of one fake location; stores sharing it model several
/// handles (or processes) on one location.
class _BindingCell {
  _BindingCell({this.bindWait});

  final Completer<void>? bindWait;
  VectorStoreBinding? binding;
  int binds = 0;
}

final class _FakeStore extends VectorStoreRepository {
  _FakeStore({
    _BindingCell? cell,
    this.documentCount = 0,
    this.vectorDimension = 0,
    this.initializeError,
    this.configureError,
    this.closeError,
    this.blockAdds = false,
    this.blockFlush = false,
    this.dropBindings = false,
  }) : cell = cell ?? _BindingCell();

  final _BindingCell cell;
  int documentCount;
  int vectorDimension;
  final Object? initializeError;
  final Object? configureError;
  final Object? closeError;
  final bool blockAdds;
  final bool blockFlush;
  final bool dropBindings;

  @override
  bool isInitialized = false;
  @override
  FilterSchema filterSchema = FilterSchema.empty;
  int initializeCalls = 0;
  int closeCalls = 0;
  int flushCalls = 0;
  int clearCalls = 0;
  int bindCalls = 0;
  int activeAdds = 0;
  final List<String> events = [];
  final List<String> startedAddIds = [];
  final List<String> addedContents = [];
  final List<String?> addedMetadata = [];
  final List<List<double>> addedEmbeddings = [];
  final List<List<double>> queryEmbeddings = [];
  final List<Filter?> filters = [];
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
  Future<VectorStoreBinding?> readBinding() async => cell.binding;

  /// A durable compare-and-set over [cell], like the real stores.
  @override
  Future<void> bind(VectorStoreBinding binding) async {
    bindCalls++;
    events.add('bind');
    await cell.bindWait?.future;
    final existing = cell.binding;
    if (existing == null) {
      if (dropBindings) return;
      cell
        ..binding = binding
        ..binds += 1;
      return;
    }
    if (existing != binding) {
      throw VectorStoreException('already bound to $existing');
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
      addedEmbeddings.add(List<double>.of(embedding));
      addedContents.add(content);
      addedMetadata.add(metadata);
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
    queryEmbeddings.add(List<double>.of(queryEmbedding));
    filters.add(filter);
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
    this.modalities = const {EmbeddingModality.text},
    this.documentVector,
    this.documentError,
    this.profileError,
    this.documentWait,
    this.queryWait,
  });

  final EmbeddingProfile profileValue;
  @override
  final Set<EmbeddingModality> modalities;
  final List<double>? documentVector;
  final Object? documentError;
  final Object? profileError;
  final Future<void>? documentWait;
  final Future<void>? queryWait;
  int profileCalls = 0;
  final List<EmbeddingInput> documents = [];
  final List<EmbeddingInput> queries = [];
  final List<EmbeddingModality> queryDocumentModalities = [];

  int get documentCalls => documents.length;
  int get queryCalls => queries.length;

  @override
  Future<EmbeddingProfile> resolveProfile() async {
    profileCalls++;
    if (profileError case final error?) throw error;
    return profileValue;
  }

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) async {
    documents.add(document);
    await documentWait;
    if (documentError case final error?) throw error;
    return documentVector ?? List<double>.filled(profileValue.dimension, 1);
  }

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) async {
    queries.add(query);
    queryDocumentModalities.add(documentModality);
    await queryWait;
    return List<double>.filled(profileValue.dimension, 1);
  }
}

/// A fake in the shape core 2.3 requires: a `final class` extending
/// `EmbeddingModel` that implements `dimension`, `isClosed`, `embed`,
/// `addCloseListener` and `close`.
final class _FakeEmbeddingModel extends EmbeddingModel {
  _FakeEmbeddingModel({required this.dimension, this.failWith});

  @override
  final int dimension;
  final Object? failWith;

  final List<TaskType> taskTypes = [];
  int closeCalls = 0;

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  bool get isClosed => closeCalls != 0;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    taskTypes.add(taskType);
    if (failWith case final error?) throw error;
    return [1, 2];
  }

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _TestException implements Exception {
  const _TestException(this.message);

  final String message;

  @override
  String toString() => '_TestException: $message';
}
