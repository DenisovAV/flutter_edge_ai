// The VectorStoreRepository contract, modelled on flutter_edge_ai_sqlite's
// provider_profile_test and vector_store suites, plus text and hybrid
// search (rag 1.2.0).
import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late World w;
  late AnySyncAccount a;
  late AnySyncLocation loc;
  setUp(() async {
    w = World();
    a = await w.open('a');
    final s = await a.createSpace('s');
    loc = AnySyncLocation(spaceId: s.id, indexName: 'notes');
  });
  tearDown(() => w.dispose());

  group('provider', () {
    test(
      'selects only its id; the location is parsed in createStore',
      () async {
        final p = AnyVectorStoreProvider(a, priority: 3);
        expect(p.id, 'any');
        expect(p.priority, 3);
        expect(p.canHandle(specOf(loc)), isTrue);
        expect(
          p.canHandle(VectorStoreSpec(providerId: 'sqlite', location: 'x')),
          isFalse,
        );
        expect(
          p.canHandle(VectorStoreSpec(providerId: 'any', location: 'bogus')),
          isTrue,
        );
        await expectLater(
          p.createStore(VectorStoreSpec(providerId: 'any', location: 'bogus')),
          throwsArgumentError,
        );
        await expectLater(
          p.createStore(
            VectorStoreSpec(
              providerId: 'any',
              location: loc.value,
              allowLegacyProfileAdoption: true,
            ),
          ),
          throwsArgumentError,
        );
      },
    );

    test('a second store on an open location is busy in-process', () async {
      final first = await openVectors(a, loc);
      await expectLater(
        openVectors(a, loc),
        throwsA(
          isA<AnySyncBusyException>()
              .having(
                (e) => e.reason,
                'reason',
                AnySyncBusyReason.alreadyOpenInProcess,
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
      await first.dispose();
      await (await openVectors(a, loc)).dispose();
    });
  });

  group('binding', () {
    test('unbound until bind; persisted; another profile is refused', () async {
      final store = await AnyVectorStoreProvider(a).createStore(specOf(loc));
      store.configure(FilterSchema.empty);
      await store.initialize(loc.value);
      expect(store.isInitialized, isTrue);
      expect(await store.readBinding(), isNull);
      final b = VectorStoreBinding(profile: profile4);
      await store.bind(b);
      await store.bind(b); // idempotent
      expect(await store.readBinding(), b);
      await expectLater(
        store.bind(
          VectorStoreBinding(
            profile: EmbeddingProfile(id: 'other', dimension: 4),
          ),
        ),
        throwsA(isA<VectorStoreException>()),
      );
      await store.close();
      await store.close(); // idempotent
      expect(store.isInitialized, isFalse);

      final again = await openVectors(a, loc);
      expect(again.embeddingProfile, profile4);
      await again.dispose();
      await expectLater(
        openVectors(
          a,
          loc,
          profile: EmbeddingProfile(id: 'other', dimension: 4),
        ),
        throwsStateError,
      );
    });

    test('an image location keeps its modality', () async {
      final i = await openVectors(a, loc, documents: EmbeddingModality.image);
      expect(i.documents, EmbeddingModality.image);
      await i.addVector(id: 'p', embedding: [1, 0, 0, 0], content: 'file.jpg');
      await i.dispose();
      await expectLater(openVectors(a, loc), throwsStateError);
    });
  });

  group('documents and search', () {
    late RagIndex i;
    setUp(() async => i = await openVectors(a, loc));
    tearDown(() => i.dispose());

    test('cosine similarity, inclusive threshold, topK, metadata', () async {
      await i.addVector(
        id: 'a',
        embedding: [1, 0, 0, 0],
        content: 'A',
        metadata: '{"k":1}',
      );
      await i.addVector(id: 'b', embedding: [1, 1, 0, 0], content: 'B');
      await i.addVector(id: 'c', embedding: [0, 0, 1, 0], content: 'C');
      final hits = await i.searchVector(embedding: [1, 0, 0, 0], topK: 3);
      expect(hits.map((h) => h.id), ['a', 'b', 'c']);
      expect(hits[0].similarity, closeTo(1, 1e-6));
      expect(hits[0].metadata, '{"k":1}');
      expect(hits[1].similarity, closeTo(0.70710678, 1e-6));
      final thresholded = await i.searchVector(
        embedding: [1, 0, 0, 0],
        topK: 3,
        threshold: hits[1].similarity,
      );
      expect(thresholded.map((h) => h.id), ['a', 'b']);
      final negative = await i.searchVector(
        embedding: [1, 0, 0, 0],
        topK: 3,
        threshold: -1,
      );
      expect(negative, hasLength(3));
      expect(
        await i.searchVector(embedding: [1, 0, 0, 0], topK: 1),
        hasLength(1),
      );
    });

    test('an update replaces content and metadata', () async {
      await i.addVector(id: 'a', embedding: [1, 0, 0, 0], content: 'v1');
      await i.addVector(
        id: 'a',
        embedding: [0, 1, 0, 0],
        content: 'v2',
        metadata: '{"m":2}',
      );
      final hits = await i.searchVector(embedding: [0, 1, 0, 0], topK: 5);
      expect(hits.single.content, 'v2');
      expect(hits.single.metadata, '{"m":2}');
      expect((await i.stats()).documentCount, 1);
    });

    test('dimension mismatch, topK above 10 000', () async {
      await expectLater(
        i.addVector(id: 'a', embedding: [1, 0], content: 'x'),
        throwsArgumentError,
      );
      await expectLater(
        i.searchVector(embedding: [1, 0, 0, 0], topK: 10001),
        throwsArgumentError,
      );
    });

    test('stats count vector rows; clear keeps the binding', () async {
      await i.addVector(id: 'a', embedding: [1, 0, 0, 0], content: 'x');
      expect(
        await i.stats(),
        const VectorStoreStats(documentCount: 1, vectorDimension: 4),
      );
      await i.clear();
      expect((await i.stats()).documentCount, 0);
      await i.addVector(id: 'b', embedding: [1, 0, 0, 0], content: 'y');
      expect((await i.stats()).documentCount, 1);
      await i.flush();
    });

    test('removing an unknown id is fine', () async {
      await i.remove(id: 'nope');
    });
  });

  group('text search', () {
    test('BM25 over content, quoted terms, filters, hybrid', () async {
      final schema = FilterSchema(
        fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
      );
      final i = await openVectors(a, loc, schema: schema, text: true);
      await i.addVector(
        id: 'r',
        embedding: [1, 0, 0, 0],
        content: 'rocket engines burn kerosene',
        metadata: '{"lang":"en"}',
      );
      await i.addVector(
        id: 's',
        embedding: [0, 1, 0, 0],
        content: 'sourdough bread',
        metadata: '{"lang":"fr"}',
      );
      expect((await i.searchText(text: 'kerosene')).map((h) => h.id), ['r']);
      // Operators are text: OR is a word, `"` does not open a phrase and
      // `*` is no prefix.
      expect(
        (await i.searchText(text: 'bread OR "kerosene')).map((h) => h.id),
        ['r', 's'],
      );
      expect(await i.searchText(text: 'kero*'), isEmpty);
      expect(
        (await i.searchText(
          text: 'rocket sourdough',
          filter: Filter(
            must: [FieldEquals(key: 'lang', value: 'fr')],
          ),
        )).map((h) => h.id),
        ['s'],
      );
      await expectLater(i.searchText(text: '   '), throwsArgumentError);
      final hybrid = await i.searchHybridVector(
        text: 'sourdough',
        embedding: [1, 0, 0, 0],
      );
      expect(hybrid.map((h) => h.id).toSet(), {'r', 's'});
      await i.remove(id: 's');
      expect(await i.searchText(text: 'sourdough'), isEmpty);
      await i.dispose();

      // Without the flag the text index is kept, and still searched.
      final again = await openVectors(a, loc, schema: schema);
      expect((await again.searchText(text: 'rocket')).map((h) => h.id), ['r']);
      await again.dispose();
    });

    test('a location without a text index refuses searchText', () async {
      final store = await AnyVectorStoreProvider(a).createStore(specOf(loc));
      store.configure(FilterSchema.empty);
      await store.initialize(loc.value);
      await store.bind(VectorStoreBinding(profile: profile4));
      expect(store.supportsTextSearch, isTrue);
      await expectLater(store.searchText(text: 'x', topK: 1), throwsStateError);
      await store.close();
    });
  });
}
