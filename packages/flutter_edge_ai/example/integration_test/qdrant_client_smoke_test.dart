// Smoke test for QdrantEdgeClient — exercises the full FFI path end to
// end against the bundled native dylib on whatever device the test runs on.
//
// Run with:
//   cd example && flutter test integration_test/qdrant_client_smoke_test.dart -d macos

import 'dart:io';

import 'package:flutter_edge_ai_qdrant/src/filter_codec.dart';
import 'package:flutter_edge_ai_qdrant/src/point_id_hasher.dart';
import 'package:flutter_edge_ai_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory shardDir;

  setUp(() async {
    final base = await getApplicationSupportDirectory();
    shardDir = Directory(
      '${base.path}/qdrant_smoke_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    if (shardDir.existsSync()) {
      shardDir.deleteSync(recursive: true);
    }
  });

  test('open + empty count', () async {
    final client = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);
    addTearDown(client.close);

    expect(await client.count(), equals(0));
  });

  test('upsert + count + search exact match', () async {
    final client = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);
    addTearDown(client.close);

    await client.upsert(
      id: PointIdHasher.hash('doc_a'),
      vector: [0.95, 0.10, 0.10, 0.10],
      payload: {'tag': 'target', 'price': 999.0},
    );
    await client.upsert(
      id: PointIdHasher.hash('doc_b'),
      vector: [0.05, 0.95, 0.10, 0.10],
      payload: {'tag': 'other', 'price': 50.0},
    );
    expect(await client.count(), equals(2));

    final hits = await client.search(
      queryVector: [0.95, 0.10, 0.10, 0.10],
      topK: 5,
    );
    expect(hits, hasLength(2));
    expect(hits.first.id, equals(PointIdHasher.hash('doc_a')));
    expect(hits.first.score, greaterThan(0.9));
    expect(hits.first.payload?['tag'], equals('target'));
  });

  test('batch upsert + filtered search', () async {
    final client = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);
    addTearDown(client.close);

    await client.upsertBatch([
      (
        id: PointIdHasher.hash('a'),
        vector: [0.95, 0.10, 0.10, 0.10],
        payload: {'lang': 'en', 'price': 250.0},
      ),
      (
        id: PointIdHasher.hash('b'),
        vector: [0.90, 0.20, 0.10, 0.10],
        payload: {'lang': 'fr', 'price': 100.0},
      ),
      (
        id: PointIdHasher.hash('c'),
        vector: [0.85, 0.30, 0.10, 0.10],
        payload: {'lang': 'en', 'price': 500.0},
      ),
    ]);
    expect(await client.count(), equals(3));

    // Filter: english docs priced 200-1000.
    final filterJson = FilterCodec.encode(
      Filter(
        must: [
          FieldEquals(key: 'lang', value: 'en'),
          FieldRange(key: 'price', gte: 200.0, lte: 1000.0),
        ],
      ),
      FilterSchema(
        fields: [
          FilterField(name: 'lang', type: FilterFieldType.string),
          FilterField(name: 'price', type: FilterFieldType.number),
        ],
      ),
    );
    expect(filterJson, isNotNull);

    final hits = await client.search(
      queryVector: [0.95, 0.10, 0.10, 0.10],
      topK: 5,
      filterJson: filterJson,
    );
    final ids = hits.map((h) => h.id).toSet();
    expect(ids, contains(PointIdHasher.hash('a')));
    expect(ids, contains(PointIdHasher.hash('c')));
    expect(ids, isNot(contains(PointIdHasher.hash('b')))); // wrong lang
  });

  test('delete + persistence across close/reopen', () async {
    final c1 = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);
    await c1.upsertBatch([
      (id: PointIdHasher.hash('p1'), vector: [1, 0, 0, 0], payload: null),
      (id: PointIdHasher.hash('p2'), vector: [0, 1, 0, 0], payload: null),
      (id: PointIdHasher.hash('p3'), vector: [0, 0, 1, 0], payload: null),
    ]);
    expect(await c1.count(), equals(3));
    await c1.delete([PointIdHasher.hash('p2')]);
    expect(await c1.count(), equals(2));
    await c1.close();

    // Reopen — points should persist.
    final c2 = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);
    addTearDown(c2.close);
    expect(await c2.count(), equals(2));
  });

  // ---------------------------------------------------------------------
  // QdrantVectorStore — the layer the 1.3.0 migration actually rewrote, and
  // the one every fix in this release lives in. Until these were added, no
  // test touched it on a real device on any of the eight shipped platforms:
  // the cases above drive QdrantEdgeClient directly.
  // ---------------------------------------------------------------------

  List<double> vec(int dim, double seed) => List<double>.filled(dim, seed);
  final storeProfile = EmbeddingProfile(
    id: 'qdrant-device-smoke-4d-v1',
    dimension: 4,
  );

  test(
    'store: a reopened store reports its contents before any write',
    () async {
      final first = QdrantVectorStore();
      await first.initialize(shardDir.path);
      await first.bindEmbeddingProfile(storeProfile);
      for (var i = 0; i < 3; i++) {
        await first.addDocument(
          id: 'doc$i',
          content: 'content $i',
          embedding: vec(4, i + 1.0),
        );
      }
      await first.close();

      // A second store on the same path stands in for an app restart. Before
      // 2.0's fix the client opened lazily on the first write, so this reported
      // zero documents and no hits over a fully populated index.
      final reopened = QdrantVectorStore();
      await reopened.initialize(shardDir.path);
      addTearDown(reopened.close);

      expect((await reopened.getStats()).documentCount, equals(3));
      expect(
        await reopened.searchSimilar(queryEmbedding: vec(4, 1), topK: 5),
        isNotEmpty,
      );
    },
  );

  test('store: concurrent addDocument calls do not race the WAL lock', () async {
    // Indexing a corpus with Future.wait is the obvious thing to write. Before
    // the fix both callers opened the same shard, qdrant holds the WAL
    // exclusively, and the loser failed with Kind(WouldBlock) — losing a
    // document. Worth running on device: the failure is timing-dependent and
    // storage there is slower than a dev box.
    final store = QdrantVectorStore();
    await store.initialize(shardDir.path);
    await store.bindEmbeddingProfile(storeProfile);
    addTearDown(store.close);

    await Future.wait([
      for (var i = 0; i < 8; i++)
        store.addDocument(
          id: 'doc$i',
          content: 'content $i',
          embedding: vec(4, i + 1.0),
        ),
    ]);

    expect((await store.getStats()).documentCount, equals(8));
  });

  test('store: a 1.x layout is refused, and nothing of it is touched', () async {
    // A store written by 1.x sits directly at databasePath; 2.0 only opens its
    // owned subdir. Undetected it comes up empty with no error and the old
    // corpus keeps its disk. On device this is the case that would silently
    // cost a user their index on upgrade.
    shardDir.createSync(recursive: true);
    // The real 1.x shard config. `{}` used to be enough, and this fixture was
    // left behind when the unit one was corrected — which made this test, the
    // PR's on-device evidence, silently red. Keep it identical to
    // `writeLegacyStore` in test/qdrant_lifecycle_test.dart.
    File('${shardDir.path}/edge_config.json').writeAsStringSync(
      '{"on_disk_payload":false,"vectors":{"":{"size":4,"distance":"Cosine","on_disk":false}},"sparse_vectors":{}}',
    );
    Directory('${shardDir.path}/wal').createSync();
    Directory('${shardDir.path}/segments').createSync();
    File('${shardDir.path}/user_file.txt').writeAsStringSync('keep me');

    final store = QdrantVectorStore();
    addTearDown(store.close);

    // initialize() itself refuses — not the first write. A read-only session
    // never writes, so a write-path check let the app come up, answer without
    // its corpus, and never say why.
    await expectLater(
      store.initialize(shardDir.path),
      throwsA(isA<QdrantLegacyStoreException>()),
    );
    // And the refusal must not hide behind an empty answer either.
    await expectLater(store.getStats(), throwsA(isA<VectorStoreException>()));

    // clear() refuses too, and — the point of the whole redesign — removes
    // nothing. This release does not delete data it cannot read, on device
    // least of all, where the files belong to a real user.
    await expectLater(
      store.clear(),
      throwsA(isA<QdrantLegacyStoreException>()),
    );
    for (final name in ['edge_config.json', 'wal', 'segments']) {
      final at = '${shardDir.path}/$name';
      expect(
        File(at).existsSync() || Directory(at).existsSync(),
        isTrue,
        reason: 'clear() removed $name — it must only refuse',
      );
    }
    expect(File('${shardDir.path}/user_file.txt').existsSync(), isTrue);
  });

  test('store: clear() empties in place and the store keeps working', () async {
    // The other half of the redesign, and the reason a device run matters:
    // clear() erases documents through the SDK instead of deleting the shard
    // directory, so the directory must survive and the store must still write.
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(shardDir.path);
    await store.bindEmbeddingProfile(storeProfile);
    await store.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
    await store.addDocument(id: 'b', content: 'y', embedding: vec(4, 2));
    expect((await store.getStats()).documentCount, equals(2));

    await store.clear();

    expect((await store.getStats()).documentCount, equals(0));
    expect(
      Directory('${shardDir.path}/qdrant_edge_v1').existsSync(),
      isTrue,
      reason: 'clear() deleted the shard directory',
    );
    await store.addDocument(id: 'c', content: 'z', embedding: vec(4, 3));
    expect((await store.getStats()).documentCount, equals(1));
  });

  test('store: a shard whose config file is gone is still read', () async {
    // The case worth spending device time on. The engine reads a shard from
    // `wal/` + `segments/`; `edge_config.json` is not the data. A gate that
    // required the marker reported a full corpus as an empty store — and a
    // clear() interrupted after unlinking the marker, or a partial backup
    // restore that drops one small file, lands exactly there. Filesystem
    // ordering and atomicity are the whole subject, so a host VM is the wrong
    // place to trust it.
    final seed = QdrantVectorStore();
    await seed.initialize(shardDir.path);
    await seed.bindEmbeddingProfile(storeProfile);
    await seed.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
    await seed.addDocument(id: 'b', content: 'y', embedding: vec(4, 2));
    await seed.close();

    final marker = File('${shardDir.path}/qdrant_edge_v1/edge_config.json');
    expect(marker.existsSync(), isTrue, reason: 'fixture never wrote a marker');
    marker.deleteSync();

    final reopened = QdrantVectorStore();
    await reopened.initialize(shardDir.path);
    addTearDown(reopened.close);
    expect(
      (await reopened.getStats()).documentCount,
      equals(2),
      reason: 'a readable shard was reported as an empty store',
    );
  });

  test(
    'store: a shard it cannot open is reported, not answered as 0',
    () async {
      // qdrant holds the WAL exclusively, so a second store on the same path
      // cannot adopt it. On device that is a real shape — a background isolate,
      // or a store the app forgot to close across a route change. It used to
      // report an empty index and tell nobody: the only notification went to
      // edgeAiLog, which is debug-only, so a release build said nothing at all.
      final holder = QdrantVectorStore();
      await holder.initialize(shardDir.path);
      await holder.bindEmbeddingProfile(storeProfile);
      await holder.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      addTearDown(holder.close);

      final second = QdrantVectorStore();
      addTearDown(second.close);
      // initialize() reports the failure, per the VectorStoreRepository
      // contract, and the message says WHICH failure: "open elsewhere" is
      // recoverable by closing the other store and must not read like data
      // corruption. Those two were one generic error until the SDK gave the
      // lock its own type.
      await expectLater(
        second.initialize(shardDir.path),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => e.message,
            'message',
            contains('open elsewhere'),
          ),
        ),
      );

      await expectLater(
        second.getStats(),
        throwsA(isA<VectorStoreException>()),
        reason: 'a shard it could not open was reported as 0 documents',
      );
      await expectLater(
        second.addDocument(id: 'b', content: 'y', embedding: vec(4, 2)),
        throwsA(isA<VectorStoreException>()),
        reason:
            'a write merged into a shard the store had just refused to read',
      );
    },
  );
}
