// Text search on a store that could not be opened, and the text index on the
// paths that adopt an existing shard (initialize, clear) — store-level, on the
// real qdrant-edge engine.
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
// Internal (src/) imports, valid within the same package: the test-only
// checkpoint and the wrapper's exception type it throws.
import 'package:flutter_edge_ai_qdrant/src/profile_operation_test_hook.dart';
import 'package:flutter_edge_ai_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _binding = VectorStoreBinding(
  profile: EmbeddingProfile(id: 'qdrant-text-lifecycle-v1', dimension: 4),
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

/// An initialized, bound store; closed on teardown.
Future<QdrantVectorStore> _open(
  String path, {
  bool enableTextSearch = true,
}) async {
  final store = QdrantVectorStore(enableTextSearch: enableTextSearch);
  addTearDown(store.close);
  await store.initialize(path);
  await store.bind(_binding);
  return store;
}

Future<void> _add(QdrantVectorStore store, String id, String content) =>
    store.addDocument(id: id, content: content, embedding: const [1, 0, 0, 0]);

/// A store whose initialize() failed because [holder] has the shard open.
Future<QdrantVectorStore> _lockedOut(String path) async {
  final store = QdrantVectorStore(enableTextSearch: true);
  addTearDown(store.close);
  await expectLater(
    store.initialize(path),
    throwsA(isA<VectorStoreException>()),
  );
  expect(store.isInitialized, isFalse);
  return store;
}

void main() {
  tearDown(() => qdrantProfileOperationCheckpointForTesting = null);

  test('searchText on a store that could not open refuses, never []', () async {
    final path = _tempLocation('qtl_latched');
    final holder = await _open(path);
    await _add(holder, 'a', 'alpha');

    final store = await _lockedOut(path);
    // Reporting no hits here would hide the corpus the holder has open.
    await expectLater(
      store.searchText(text: 'alpha', topK: 5),
      throwsA(isA<VectorStoreException>()),
    );
  });

  test(
    'clear() on a store that could not open gives it the text index',
    () async {
      final path = _tempLocation('qtl_clear_index');
      final holder = await _open(path, enableTextSearch: false);
      await _add(holder, 'a', 'alpha');

      final store = await _lockedOut(path);
      await holder.close();
      await store.clear();

      expect(await store.searchText(text: 'alpha', topK: 5), isEmpty);
      await _add(store, 'b', 'alpha again');
      expect(
        [
          for (final hit in await store.searchText(text: 'alpha', topK: 5))
            hit.id,
        ],
        ['b'],
      );
    },
  );

  test(
    'clear() that cannot create the index latches the store and frees the shard',
    () async {
      final path = _tempLocation('qtl_clear_fail');
      final holder = await _open(path, enableTextSearch: false);
      await _add(holder, 'a', 'alpha');

      final store = await _lockedOut(path);
      await holder.close();
      qdrantProfileOperationCheckpointForTesting = (operation) async {
        if (operation == 'ensureTextIndex') {
          throw const QdrantException('injected index failure');
        }
      };
      await expectLater(store.clear(), throwsA(isA<VectorStoreException>()));
      qdrantProfileOperationCheckpointForTesting = null;

      // Latched with the reason, not serving everything but text search.
      expect(store.isInitialized, isFalse);
      await expectLater(
        store.searchText(text: 'alpha', topK: 5),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => e.message,
            'message',
            contains('text index'),
          ),
        ),
      );
      // The shard was closed, not left holding its lock.
      final other = await _open(path, enableTextSearch: false);
      expect((await other.getStats()).documentCount, 0);
      await other.close();

      // initialize() again recovers it, index included.
      await store.initialize(path);
      expect(store.isInitialized, isTrue);
      expect(await store.searchText(text: 'alpha', topK: 5), isEmpty);
    },
  );

  test('an open without the flag does not give a shard the index', () async {
    final path = _tempLocation('qtl_noflag_adopt');
    final first = await _open(path, enableTextSearch: false);
    await _add(first, 'a', 'alpha');
    await first.close();

    final second = await _open(path, enableTextSearch: false);
    await second.clear();
    await expectLater(
      second.searchText(text: 'alpha', topK: 5),
      throwsA(isA<StateError>()),
    );
  });

  test('a shard whose config is corrupt is unreadable, not empty', () async {
    final path = _tempLocation('qtl_corrupt');
    final writer = await _open(path, enableTextSearch: false);
    await _add(writer, 'a', 'alpha');
    await writer.close();

    File(
      p.join(path, 'qdrant_edge_v1', 'edge_config.json'),
    ).writeAsStringSync('{ not json');

    final store = QdrantVectorStore(enableTextSearch: true);
    addTearDown(store.close);
    await expectLater(
      store.initialize(path),
      throwsA(
        isA<VectorStoreException>().having(
          (e) => e.message,
          'message',
          contains('cannot be read'),
        ),
      ),
    );
    expect(store.isInitialized, isFalse);
  });
}
