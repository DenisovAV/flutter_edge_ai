import 'dart:async';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

final _profile = EmbeddingProfile(id: 'remove-where-test-v1', dimension: 2);

final _source = Filter(
  must: [FieldEquals(key: 'source', value: 'a.md')],
);

void main() {
  group('RagIndex.removeWhere', () {
    test('passes the filter to the store and returns its count', () async {
      final store = _Store(removed: 3);
      final index = await _open(store);
      expect(await index.removeWhere(_source), 3);
      expect(store.removeCalls, [_source]);
    });

    test('refuses an empty filter, pointing to clear()', () async {
      final store = _Store();
      final index = await _open(store);
      for (final empty in [
        Filter(),
        Filter(must: const [], should: const [], mustNot: const []),
      ]) {
        await expectLater(
          index.removeWhere(empty),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('clear()'),
            ),
          ),
        );
      }
      expect(store.removeCalls, isEmpty);
    });

    test('refuses a field the filter schema does not declare', () async {
      final store = _Store();
      final index = await _open(store);
      await expectLater(
        index.removeWhere(
          Filter(
            mustNot: [FieldEquals(key: 'path', value: 'a.md')],
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('declared: source'),
          ),
        ),
      );
      expect(store.removeCalls, isEmpty);
    });

    test('fails with UnsupportedError on a store without it', () async {
      final store = _Store(supported: false);
      final index = await _open(store);
      await expectLater(
        index.removeWhere(_source),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('_Store'),
          ),
        ),
      );
      expect(store.removeCalls, isEmpty);
    });

    test('the contract default is unsupported', () async {
      final store = _PlainStore();
      expect(store.supportsRemoveWhere, isFalse);
      await expectLater(
        store.removeDocumentsWhere(_source),
        throwsUnsupportedError,
      );
    });

    test('waits for running operations and holds back later ones', () async {
      final store = _Store(removed: 1);
      final index = await _open(store);
      store.events.clear(); // opening reads the stats

      store.blockSearch = Completer<void>();
      final search = index.searchVector(embedding: const [1, 0]);
      await pumpEventQueue();
      expect(store.events, ['search:start']);

      final remove = index.removeWhere(_source);
      await pumpEventQueue();
      expect(store.events, [
        'search:start',
      ], reason: 'removeWhere ran beside a search still in progress');

      final later = index.stats();
      store.blockSearch!.complete();
      await search;
      expect(await remove, 1);
      await later;
      expect(store.events, [
        'search:start',
        'search:end',
        'removeWhere',
        'stats',
      ]);
    });

    test('a disposed index refuses it', () async {
      final store = _Store();
      final index = await _open(store, tearDown: false);
      await index.dispose();
      await expectLater(index.removeWhere(_source), throwsStateError);
      expect(store.removeCalls, isEmpty);
    });
  });
}

Future<RagIndex> _open(_Store store, {bool tearDown = true}) async {
  final index = await FlutterEdgeAiRag(providers: [_Provider(store)])
      .openVectors(
        spec: VectorStoreSpec(
          providerId: 'fake',
          location: 'mem',
          filterSchema: FilterSchema(
            fields: [FilterField(name: 'source', type: FilterFieldType.string)],
          ),
        ),
        profile: _profile,
      );
  if (tearDown) addTearDown(index.dispose);
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

final class _Store extends VectorStoreRepository {
  _Store({this.supported = true, this.removed = 0});

  final bool supported;
  final int removed;
  final removeCalls = <Filter>[];
  final events = <String>[];
  Completer<void>? blockSearch;
  VectorStoreBinding? _binding;

  @override
  bool isInitialized = false;
  @override
  FilterSchema filterSchema = FilterSchema.empty;

  @override
  bool get supportsRemoveWhere => supported;

  @override
  Future<int> removeDocumentsWhere(Filter filter) async {
    events.add('removeWhere');
    removeCalls.add(filter);
    return removed;
  }

  @override
  void configure(FilterSchema schema) => filterSchema = schema;
  @override
  Future<void> initialize(String location) async => isInitialized = true;
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
  }) async {}
  @override
  Future<void> removeDocument({required String id}) async {}
  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    events.add('search:start');
    await blockSearch?.future;
    events.add('search:end');
    return const [];
  }

  @override
  Future<VectorStoreStats> getStats() async {
    events.add('stats');
    return const VectorStoreStats(documentCount: 0, vectorDimension: 2);
  }

  @override
  Future<void> clear() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async => isInitialized = false;
}

/// A store that overrides nothing about removeWhere.
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
