// RagIndex.removeWhere on the real qdrant-edge engine. The filter semantics
// are held to the sqlite store by the shared parity table
// (flutter_edge_ai_sqlite/test/cross_backend_parity_test.dart); this file
// covers what only a whole index shows: the BM25 text index, reopen, an
// empty shard, and the store's own refusal.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

final _profile = EmbeddingProfile(id: 'qdrant-remove-where-v1', dimension: 4);

final _schema = FilterSchema(
  fields: [FilterField(name: 'source', type: FilterFieldType.string)],
);

String _tempLocation(String name) {
  final dir = Directory.systemTemp.createTempSync(name);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir.path;
}

Future<RagIndex> _open(String path) async {
  final index =
      await FlutterEdgeAiRag(
        providers: const [QdrantVectorStoreProvider()],
      ).openVectors(
        spec: VectorStoreSpec(
          providerId: 'qdrant',
          location: path,
          filterSchema: _schema,
          enableTextSearch: true,
        ),
        profile: _profile,
      );
  addTearDown(index.dispose);
  return index;
}

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
  test(
    'removes one file\'s chunks, returns the count, text search follows',
    () async {
      final index = await _open(_tempLocation('qrw_file'));
      await _addChunks(index);
      expect(await index.removeWhere(_aMd), 3);
      expect(await _vectorIds(index), ['b1', 'b2']);
      expect(await _textIds(index), ['b1', 'b2']);
      expect((await index.stats()).documentCount, 2);
      expect(await index.removeWhere(_aMd), 0);
    },
  );

  test('the removal persists through close and reopen', () async {
    final path = _tempLocation('qrw_reopen');
    final first = await _open(path);
    await _addChunks(first);
    expect(await first.removeWhere(_aMd), 3);
    await first.dispose();

    final second = await _open(path);
    expect(await _vectorIds(second), ['b1', 'b2']);
    expect(await _textIds(second), ['b1', 'b2']);
  });

  test('before any document is added it removes nothing', () async {
    final index = await _open(_tempLocation('qrw_empty'));
    expect(await index.removeWhere(_aMd), 0);
  });

  test('the store refuses an empty filter on its own', () async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    store.configure(_schema);
    await store.initialize(_tempLocation('qrw_store_empty'));
    expect(store.supportsRemoveWhere, isTrue);
    await expectLater(
      store.removeDocumentsWhere(Filter()),
      throwsArgumentError,
    );
  });
}
