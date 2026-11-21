/// Text and hybrid search on the web arm of `flutter_edge_ai_sqlite`: FTS5
/// inside the package's own `web/rag/sqlite3.wasm`, run in Chrome.
///
/// Run with:
///   chromedriver --port=4444 &          # must match your Chrome major version
///   cd packages/flutter_edge_ai/example
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/rag_sqlite_web_text_search_test.dart \
///     -d web-server --browser-name=chrome --headless
///
/// What only this suite shows: that the shipped wasm has FTS5 at run time
/// (create, insert, `bm25()` ranking), that the text index persists through
/// the IndexedDB VFS (close, then a fresh wasm instance reads it back), and
/// that the shared filter table holds on the text leg in the browser.
@TestOn('chrome')
library;

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: implementation_imports — shares the sqlite package's parity cases
import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart' as parity;

final _profile = EmbeddingProfile(id: 'web-text-search-v1', dimension: 4);

List<double> _axis(int axis) => [for (var i = 0; i < 4; i++) i == axis ? 1 : 0];

String _location(String name) =>
    'text_${name}_${DateTime.now().microsecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // NO setUp (Rule 6b): a setUp that throws under `flutter drive` on web is
  // reported as "All tests passed". Every store is built inside its test.
  Future<RagIndex> open(String location) =>
      FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      ).openVectors(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: location,
          enableTextSearch: true,
        ),
        profile: _profile,
      );

  testWidgets('FTS5 runs in the shipped wasm and ranks by BM25', (
    tester,
  ) async {
    final index = await open(_location('bm25'));
    addTearDown(index.dispose);
    await index.addVector(
      id: 'a',
      content: 'the cat sat on the mat',
      embedding: _axis(0),
    );
    await index.addVector(
      id: 'b',
      content: 'cat cat cat: a story about a cat',
      embedding: _axis(1),
    );
    for (var i = 0; i < 6; i++) {
      await index.addVector(
        id: 'filler$i',
        content: 'nothing to see here $i',
        embedding: _axis(2),
      );
    }
    final hits = await index.searchText(text: 'cat');
    expect([for (final h in hits) h.id], ['b', 'a']);
    expect(hits.first.relevanceScore, greaterThan(hits[1].relevanceScore));
    expect(await index.searchText(text: '"..."'), isEmpty);
    await index.addVector(id: 'fr', content: 'Un Café', embedding: _axis(3));
    expect(
      [for (final h in await index.searchText(text: 'CAFE')) h.id],
      ['fr'],
    );
  });

  testWidgets('removeWhere drops both legs and persists through reopen', (
    tester,
  ) async {
    final location = _location('remove_where');
    Future<RagIndex> openWithSource() =>
        FlutterEdgeAiRag(
          providers: const [SqliteVectorStoreProvider()],
        ).openVectors(
          spec: VectorStoreSpec(
            providerId: SqliteVectorStoreProvider.providerId,
            location: location,
            enableTextSearch: true,
            filterSchema: FilterSchema(
              fields: [
                FilterField(name: 'source', type: FilterFieldType.string),
              ],
            ),
          ),
          profile: _profile,
        );
    Future<List<String>> textIds(RagIndex index) async =>
        [for (final h in await index.searchText(text: 'rivers', topK: 20)) h.id]
          ..sort();

    final first = await openWithSource();
    for (final (id, source) in [
      ('a1', 'a.md'),
      ('a2', 'a.md'),
      ('b1', 'b.md'),
    ]) {
      await first.addVector(
        id: id,
        content: 'chunk $id about rivers',
        embedding: _axis(0),
        metadata: '{"source":"$source"}',
      );
    }
    final aMd = Filter(
      must: [FieldEquals(key: 'source', value: 'a.md')],
    );
    expect(await first.removeWhere(aMd), 2);
    expect(await textIds(first), ['b1']);
    expect((await first.stats()).documentCount, 1);
    await first.flush();
    await first.dispose();

    final second = await openWithSource();
    addTearDown(second.dispose);
    expect(await textIds(second), ['b1']);
    expect((await second.stats()).documentCount, 1);
  });

  testWidgets('the text index persists through close and reopen', (
    tester,
  ) async {
    final location = _location('persist');
    final first = await open(location);
    await first.addVector(
      id: 'kept',
      content: 'persistent words',
      embedding: _axis(0),
    );
    await first.addVector(
      id: 'gone',
      content: 'transient',
      embedding: _axis(1),
    );
    await first.remove(id: 'gone');
    await first.flush();
    await first.dispose();

    // A new provider, a new wasm instance, the same IndexedDB location.
    final second = await open(location);
    addTearDown(second.dispose);
    expect(
      [for (final h in await second.searchText(text: 'persistent')) h.id],
      ['kept'],
    );
    expect(await second.searchText(text: 'transient'), isEmpty);
  });

  testWidgets('hybrid search fuses both legs', (tester) async {
    final index = await open(_location('hybrid'));
    addTearDown(index.dispose);
    await index.addVector(
      id: 'both',
      content: 'solar panel efficiency',
      embedding: _axis(0),
    );
    await index.addVector(
      id: 'text',
      content: 'solar storms',
      embedding: _axis(3),
    );
    await index.addVector(
      id: 'vector',
      content: 'unrelated words',
      embedding: _axis(1),
    );
    final hits = await index.searchHybridVector(
      text: 'solar',
      // Vector ranks: both 1, vector 2, text 3. 'solar' is in two of three
      // documents, so the text ranks are close to a tie either way; 'both'
      // must win on the vector rank, not on BM25.
      embedding: const [0.9, 0.4, 0, 0],
      topK: 3,
    );
    expect(hits.first.id, 'both');
    expect(hits.first.vectorRank, isNotNull);
    expect(hits.first.textRank, isNotNull);
    expect({for (final h in hits) h.id}, {'both', 'text', 'vector'});
  });

  testWidgets('the shared filter table holds on the text leg', (tester) async {
    final store = WebSqliteVectorStore(enableTextSearch: true);
    store.configure(parity.schema);
    await store.initialize(_location('parity'));
    addTearDown(store.close);
    await store.bind(
      VectorStoreBinding(
        profile: EmbeddingProfile(
          id: 'web-text-parity-v1',
          dimension: parity.embedding.length,
        ),
      ),
    );
    for (final d in parity.docs) {
      await store.addDocument(
        id: d.id,
        content: 'shared ${d.id}',
        embedding: parity.embedding,
        metadata: d.metadata,
      );
    }
    // An empty table would make the loop below vacuous.
    expect(parity.cases, hasLength(20));
    for (final c in parity.cases) {
      final hits = await store.searchText(
        text: 'shared',
        topK: parity.docs.length,
        filter: c.filter,
      );
      expect(
        [for (final h in hits) h.id]..sort(),
        [...c.expected]..sort(),
        reason: c.name,
      );
    }
  });
}
