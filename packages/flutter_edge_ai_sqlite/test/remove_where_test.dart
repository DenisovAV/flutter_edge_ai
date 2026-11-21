// RagIndex.removeWhere on the native SQLite store, against the real
// package:sqlite3 binary (FTS5) and the real vec0 loadable. The web arm runs
// the same parity table in Chrome (flutter_edge_ai/example/integration_test/
// rag_sqlite_web_parity_test.dart).
//
//   flutter test test/remove_where_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart' as parity;
import 'package:flutter_test/flutter_test.dart';

import 'vec0_locator.dart';

final _profile = EmbeddingProfile(id: 'remove-where-test-v1', dimension: 4);

final _schema = FilterSchema(
  fields: [FilterField(name: 'source', type: FilterFieldType.string)],
);

String _tempDb(String name) {
  final dir = Directory.systemTemp.createTempSync(name);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return '${dir.path}/rag.db';
}

Future<RagIndex> _open(String path) async {
  final index =
      await FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      ).openVectors(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: path,
          filterSchema: _schema,
          enableTextSearch: true,
        ),
        profile: _profile,
      );
  addTearDown(index.dispose);
  return index;
}

/// Two files of chunks: what re-indexing one file has to remove.
Future<void> _addChunks(RagIndex index) async {
  for (final (id, source) in [
    ('a1', 'a.md'),
    ('a2', 'a.md'),
    ('a3', 'a.md'),
    ('b1', 'b.md'),
    ('b2', 'b.md'),
  ]) {
    await index.addVector(
      id: id,
      content: 'chunk $id about rivers',
      embedding: [1, 0, 0, 0],
      metadata: jsonEncode({'source': source}),
    );
  }
}

Future<List<String>> _vectorIds(RagIndex index) async => [
  for (final r in await index.searchVector(embedding: [1, 0, 0, 0], topK: 20))
    r.id,
]..sort();

Future<List<String>> _textIds(RagIndex index) async =>
    [for (final r in await index.searchText(text: 'rivers', topK: 20)) r.id]
      ..sort();

final _aMd = Filter(
  must: [FieldEquals(key: 'source', value: 'a.md')],
);

void main() {
  final skip = vec0SkipReason;
  setUpAll(useHostNativeLibraries);

  test(
    'removes one file\'s chunks, returns the count, text search follows',
    () async {
      final index = await _open(_tempDb('rw_file'));
      await _addChunks(index);
      expect(await index.removeWhere(_aMd), 3);
      expect(await _vectorIds(index), ['b1', 'b2']);
      expect(await _textIds(index), ['b1', 'b2']);
      expect((await index.stats()).documentCount, 2);
      expect(await index.removeWhere(_aMd), 0, reason: 'nothing left to match');
    },
    skip: skip,
  );

  test('the removal persists through close and reopen', () async {
    final path = _tempDb('rw_reopen');
    final first = await _open(path);
    await _addChunks(first);
    expect(await first.removeWhere(_aMd), 3);
    await first.dispose();

    final second = await _open(path);
    expect(await _vectorIds(second), ['b1', 'b2']);
    expect(await _textIds(second), ['b1', 'b2']);
  }, skip: skip);

  test('before any document is added it removes nothing', () async {
    final index = await _open(_tempDb('rw_empty'));
    expect(await index.removeWhere(_aMd), 0);
  }, skip: skip);

  test('the store refuses an empty filter on its own', () async {
    final store = SqliteVectorStore(enableTextSearch: true);
    addTearDown(store.close);
    store.configure(_schema);
    await store.initialize(_tempDb('rw_store_empty'));
    expect(store.supportsRemoveWhere, isTrue);
    await expectLater(
      store.removeDocumentsWhere(Filter()),
      throwsArgumentError,
    );
  }, skip: skip);

  test('a filter that can match nothing removes nothing', () async {
    // The store's translation reports these as matching nothing with an
    // empty WHERE; run as a scan, that WHERE would remove every document.
    final store = SqliteVectorStore(enableTextSearch: true);
    addTearDown(store.close);
    store.configure(parity.schema);
    await store.initialize(_tempDb('rw_nothing'));
    await store.bind(
      VectorStoreBinding(
        profile: EmbeddingProfile(
          id: 'remove-where-parity-v1',
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
    for (final filter in [
      Filter(mustNot: [FieldRange(key: 'price')]),
      Filter(
        should: [FieldMatchAny(key: 'lang', values: [])],
      ),
    ]) {
      expect(await store.removeDocumentsWhere(filter), 0);
      expect((await store.getStats()).documentCount, parity.docs.length);
    }
  }, skip: skip);

  test('the shared parity table holds for removeWhere', () async {
    // Each case on a fresh copy of the corpus: the filter removes exactly the
    // documents search returns for it, and leaves the rest on both legs.
    expect(parity.cases, isNotEmpty);
    var run = 0;
    for (final c in parity.cases) {
      final store = SqliteVectorStore(enableTextSearch: true);
      store.configure(parity.schema);
      await store.initialize(_tempDb('rw_parity_${run++}'));
      await store.bind(
        VectorStoreBinding(
          profile: EmbeddingProfile(
            id: 'remove-where-parity-v1',
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
      final kept = [
        for (final d in parity.docs)
          if (!c.expected.contains(d.id)) d.id,
      ]..sort();

      expect(
        await store.removeDocumentsWhere(c.filter),
        c.expected.length,
        reason: c.name,
      );
      final vector = await store.searchSimilar(
        queryEmbedding: parity.embedding,
        topK: parity.docs.length,
        threshold: -1,
      );
      expect([for (final r in vector) r.id]..sort(), kept, reason: c.name);
      final text = await store.searchText(
        text: 'shared',
        topK: parity.docs.length,
      );
      expect([for (final r in text) r.id]..sort(), kept, reason: c.name);
      await store.close();
    }
    expect(run, parity.cases.length);
  }, skip: skip);
}
