import 'dart:async';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_rag/src/rag_index.dart'
    show hybridCandidateCount;
import 'package:flutter_edge_ai_rag/src/text_search.dart'
    show fuseHybridResults;
import 'package:flutter_test/flutter_test.dart';

final _profile = EmbeddingProfile(id: 'text-test-v1', dimension: 2);

RetrievalResult _v(String id, double similarity, {String? content}) =>
    RetrievalResult(
      id: id,
      content: content ?? 'v:$id',
      similarity: similarity,
      metadata: 'vm:$id',
    );

TextSearchResult _t(String id, double score, {String? content}) =>
    TextSearchResult(
      id: id,
      content: content ?? 't:$id',
      relevanceScore: score,
      metadata: 'tm:$id',
    );

void main() {
  group('fuseHybridResults', () {
    test('sums 1/(k + rank) over the legs that returned the id', () {
      final fused = fuseHybridResults(
        vector: [_v('a', 0.9), _v('b', 0.8)],
        text: [_t('b', 7), _t('c', 3)],
        fusion: const RrfFusion(),
        topK: 10,
      );
      expect([for (final r in fused) r.id], ['b', 'a', 'c']);
      final b = fused.first;
      expect(b.rrfScore, 1 / 62 + 1 / 61);
      expect(b.vectorRank, 2);
      expect(b.vectorSimilarity, 0.8);
      expect(b.textRank, 1);
      expect(b.relevanceScore, 7);
      expect(b.content, 'v:b', reason: 'content comes from the vector leg');
      expect(b.metadata, 'vm:b');

      final a = fused[1];
      expect(a.rrfScore, 1 / 61);
      expect(a.textRank, isNull);
      expect(a.relevanceScore, isNull);

      final c = fused[2];
      expect(c.rrfScore, 1 / 62);
      expect(c.vectorRank, isNull);
      expect(c.vectorSimilarity, isNull);
      expect(c.content, 't:c');
      expect(c.metadata, 'tm:c');
    });

    test('k changes the scores', () {
      final fused = fuseHybridResults(
        vector: [_v('a', 0.9)],
        text: const [],
        fusion: const RrfFusion(k: 1),
        topK: 10,
      );
      expect(fused.single.rrfScore, 1 / 2);
    });

    test('equal scores are ordered by id', () {
      final fused = fuseHybridResults(
        vector: [_v('z', 0.9)],
        text: [_t('m', 1)],
        fusion: const RrfFusion(),
        topK: 10,
      );
      expect([for (final r in fused) r.id], ['m', 'z']);
    });

    test('keeps topK and one entry per id', () {
      final fused = fuseHybridResults(
        vector: [_v('a', 0.9), _v('a', 0.5), _v('b', 0.4)],
        text: [_t('a', 2), _t('a', 1), _t('c', 1)],
        fusion: const RrfFusion(),
        topK: 2,
      );
      expect([for (final r in fused) r.id], ['a', 'b']);
      expect(fused.first.vectorRank, 1);
      expect(fused.first.textRank, 1);
      expect(fused[1].vectorRank, 3, reason: 'a rank is the list position');
    });

    test('a topK above the union returns the union', () {
      final fused = fuseHybridResults(
        vector: [_v('a', 0.9)],
        text: [_t('b', 1)],
        fusion: const RrfFusion(),
        topK: 50,
      );
      expect(fused, hasLength(2));
    });

    test('result types compare by value', () {
      expect(_t('a', 1), _t('a', 1));
      expect(_t('a', 1), isNot(_t('a', 2)));
      expect(_t('a', 1).hashCode, _t('a', 1).hashCode);
      const h = HybridSearchResult(id: 'a', content: 'c', rrfScore: 1);
      expect(h, const HybridSearchResult(id: 'a', content: 'c', rrfScore: 1));
      expect(
        h,
        isNot(
          const HybridSearchResult(
            id: 'a',
            content: 'c',
            rrfScore: 1,
            textRank: 1,
          ),
        ),
      );
      expect(const RrfFusion(k: 3), const RrfFusion(k: 3));
    });
  });

  test('hybridCandidateCount is max(4 × topK, 20)', () {
    expect(hybridCandidateCount(1), 20);
    expect(hybridCandidateCount(5), 20);
    expect(hybridCandidateCount(6), 24);
    expect(hybridCandidateCount(50), 200);
  });

  group('opening', () {
    test('a store without text search is refused before initialize', () async {
      final store = _TextStore(supportsText: false);
      final rag = _rag(store);
      await expectLater(
        rag.openVectors(
          spec: VectorStoreSpec(
            providerId: 'fake',
            location: 'loc',
            enableTextSearch: true,
          ),
          profile: _profile,
        ),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => e.message,
            'message',
            contains('"fake" has no text search'),
          ),
        ),
      );
      expect(store.events, ['close'], reason: 'nothing touched the location');
    });

    test('the same store opens without the flag', () async {
      final store = _TextStore(supportsText: false);
      final index = await _rag(
        store,
      ).openVectors(spec: _spec(enableTextSearch: false), profile: _profile);
      addTearDown(index.dispose);
      expect(store.events, contains('initialize'));
      await expectLater(
        index.searchText(text: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('enableTextSearch is for text documents only', () {
      expect(
        () => VectorStoreSpec(
          providerId: 'fake',
          location: 'loc',
          documents: EmbeddingModality.image,
          enableTextSearch: true,
        ),
        throwsArgumentError,
      );
    });

    test('the store contract defaults to no text search', () async {
      final store = _PlainStore();
      expect(store.supportsTextSearch, isFalse);
      await expectLater(
        store.searchText(text: 'x', topK: 1),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('searchText', () {
    test('passes text, topK and filter to the store', () async {
      final store = _TextStore(text: [_t('a', 2)]);
      final index = await _open(store);
      final filter = Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
      );
      final hits = await index.searchText(
        text: 'hello',
        topK: 3,
        filter: filter,
      );
      expect(hits, [_t('a', 2)]);
      expect(store.textCalls.single, ('hello', 3, filter));
    });

    test('refuses blank text, bad topK and undeclared filter fields', () async {
      final index = await _open(_TextStore());
      await expectLater(index.searchText(text: ' \n'), throwsArgumentError);
      await expectLater(
        index.searchText(text: 'x', topK: 0),
        throwsArgumentError,
      );
      await expectLater(
        index.searchText(
          text: 'x',
          filter: Filter(must: [FieldEquals(key: 'nope', value: 1)]),
        ),
        throwsArgumentError,
      );
    });
  });

  group('searchHybrid', () {
    test('embeds the text and runs both legs with the same filter', () async {
      final store = _TextStore(
        vector: [_v('a', 0.5), _v('b', -0.2)],
        text: [_t('b', 4)],
      );
      final embedder = _Embedder();
      final index = await _open(store, embedder: embedder);
      final filter = Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
      );

      final hits = await index.searchHybrid(
        text: 'query',
        topK: 6,
        filter: filter,
      );

      expect(embedder.queries.single.text, 'query');
      expect(store.vectorCalls.single, (24, -double.maxFinite, filter));
      expect(store.textCalls.single, ('query', 24, filter));
      expect([for (final h in hits) h.id], ['b', 'a']);
      expect(hits.first.vectorSimilarity, -0.2);
    });

    test('searchHybridVector uses the given vector', () async {
      final store = _TextStore(vector: [_v('a', 1)]);
      final index = await _open(store);
      final hits = await index.searchHybridVector(
        text: 'q',
        embedding: const [0.5, 0.5],
      );
      expect(store.queryVectors.single, [0.5, 0.5]);
      expect(hits.single.id, 'a');
      await expectLater(
        index.searchHybridVector(text: 'q', embedding: const [1]),
        throwsArgumentError,
      );
    });

    test('is refused on an image index', () async {
      final store = _TextStore();
      final index = await _rag(store).openVectors(
        spec: VectorStoreSpec(
          providerId: 'fake',
          location: 'loc',
          documents: EmbeddingModality.image,
        ),
        profile: _profile,
      );
      addTearDown(index.dispose);
      await expectLater(
        index.searchText(text: 'q'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('text indexes only'),
          ),
        ),
      );
      await expectLater(
        index.searchHybridVector(text: 'q', embedding: const [1, 0]),
        throwsA(isA<StateError>()),
      );
      expect(store.events, isNot(contains('vector')));
    });

    test('a failing leg releases the gate', () async {
      final store = _TextStore(textError: StateError('no text index'));
      final index = await _open(store);
      await expectLater(
        index.searchHybridVector(text: 'q', embedding: const [1, 0]),
        throwsA(isA<StateError>()),
      );
      await index.addVector(id: 'after', content: 'c', embedding: const [1, 0]);
      expect(store.events.last, 'add:after');
    });

    test('a disposed index refuses every new method', () async {
      final index = await _open(_TextStore());
      await index.dispose();
      await expectLater(index.searchText(text: 'q'), throwsStateError);
      await expectLater(index.searchHybrid(text: 'q'), throwsStateError);
      await expectLater(
        index.searchHybridVector(text: 'q', embedding: const [1, 0]),
        throwsStateError,
      );
    });

    test('needs an embedder', () async {
      final index = await _open(_TextStore());
      await expectLater(
        index.searchHybrid(text: 'q'),
        throwsA(isA<StateError>()),
      );
    });

    test('refuses k <= 0', () async {
      final index = await _open(_TextStore());
      await expectLater(
        index.searchHybridVector(
          text: 'q',
          embedding: const [1, 0],
          fusion: const RrfFusion(k: 0),
        ),
        throwsArgumentError,
      );
    });

    test('no write of the index lands between the two legs', () async {
      final store = _TextStore(blockVector: true);
      final index = await _open(store);
      final hybrid = index.searchHybridVector(
        text: 'q',
        embedding: const [1, 0],
      );
      await pumpEventQueue();
      expect(store.events.last, 'vector');
      final add = index.addVector(
        id: 'new',
        content: 'c',
        embedding: const [1, 0],
      );
      await pumpEventQueue();
      store.releaseVector();
      await hybrid;
      await add;
      final tail = store.events.sublist(store.events.indexOf('vector'));
      expect(tail, ['vector', 'text', 'add:new']);
    });
  });
}

VectorStoreSpec _spec({bool enableTextSearch = true}) => VectorStoreSpec(
  providerId: 'fake',
  location: 'loc',
  enableTextSearch: enableTextSearch,
  filterSchema: FilterSchema(
    fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
  ),
);

FlutterEdgeAiRag _rag(VectorStoreRepository store) =>
    FlutterEdgeAiRag(providers: [_Provider(store)]);

Future<RagIndex> _open(_TextStore store, {_Embedder? embedder}) async {
  final rag = _rag(store);
  final index = embedder == null
      ? await rag.openVectors(spec: _spec(), profile: _profile)
      : await rag.open(spec: _spec(), embedder: embedder);
  addTearDown(index.dispose);
  return index;
}

class _Provider implements VectorStoreProvider {
  _Provider(this.store);

  final VectorStoreRepository store;

  @override
  String get id => 'fake';
  @override
  String get name => 'fake';
  @override
  int get priority => 0;
  @override
  bool canHandle(VectorStoreSpec spec) => true;
  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async =>
      store;
}

final class _TextStore extends VectorStoreRepository {
  _TextStore({
    this.supportsText = true,
    this.vector = const [],
    this.text = const [],
    this.blockVector = false,
    this.textError,
  });

  final Object? textError;

  final bool supportsText;
  final List<RetrievalResult> vector;
  final List<TextSearchResult> text;
  final bool blockVector;
  final events = <String>[];
  final vectorCalls = <(int, double, Filter?)>[];
  final queryVectors = <List<double>>[];
  final textCalls = <(String, int, Filter?)>[];
  VectorStoreBinding? _binding;
  Completer<void>? _vectorGate;

  @override
  bool isInitialized = false;
  @override
  FilterSchema filterSchema = FilterSchema.empty;

  @override
  bool get supportsTextSearch => supportsText;

  void releaseVector() => _vectorGate?.complete();

  @override
  void configure(FilterSchema schema) {
    events.add('configure');
    filterSchema = schema;
  }

  @override
  Future<void> initialize(String location) async {
    events.add('initialize');
    isInitialized = true;
  }

  @override
  Future<VectorStoreBinding?> readBinding() async => _binding;

  @override
  Future<void> bind(VectorStoreBinding binding) async => _binding = binding;

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => events.add('add:$id');

  @override
  Future<void> removeDocument({required String id}) async {}

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    events.add('vector');
    vectorCalls.add((topK, threshold, filter));
    queryVectors.add(queryEmbedding);
    if (blockVector) {
      _vectorGate = Completer<void>();
      await _vectorGate!.future;
    }
    return vector;
  }

  @override
  Future<List<TextSearchResult>> searchText({
    required String text,
    required int topK,
    Filter? filter,
  }) async {
    events.add('text');
    textCalls.add((text, topK, filter));
    if (textError case final error?) throw error;
    return this.text;
  }

  @override
  Future<VectorStoreStats> getStats() async =>
      const VectorStoreStats(documentCount: 0, vectorDimension: 0);

  @override
  Future<void> clear() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    events.add('close');
    isInitialized = false;
  }
}

/// A store that overrides nothing about text search.
final class _PlainStore extends VectorStoreRepository {
  @override
  bool get isInitialized => false;
  @override
  FilterSchema get filterSchema => FilterSchema.empty;
  @override
  void configure(FilterSchema schema) {}
  @override
  Future<void> initialize(String location) async {}
  @override
  Future<VectorStoreBinding?> readBinding() async => null;
  @override
  Future<void> bind(VectorStoreBinding binding) async {}
  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {}
  @override
  Future<void> removeDocument({required String id}) async {}
  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async => const [];
  @override
  Future<VectorStoreStats> getStats() async =>
      const VectorStoreStats(documentCount: 0, vectorDimension: 0);
  @override
  Future<void> clear() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
}

class _Embedder implements RagEmbedder {
  final queries = <EmbeddingInput>[];

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<EmbeddingProfile> resolveProfile() async => _profile;

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) async => const [
    1,
    0,
  ];

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) async {
    queries.add(query);
    return const [1, 0];
  }
}
