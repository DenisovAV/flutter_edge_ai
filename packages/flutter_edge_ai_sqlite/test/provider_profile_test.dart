import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_profile_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  group('SqliteVectorStoreProvider', () {
    const provider = SqliteVectorStoreProvider();

    test(
      'selects only the sqlite provider id and creates a native store',
      () async {
        final sqlite = VectorStoreSpec(providerId: 'sqlite', location: 'index');
        final other = VectorStoreSpec(providerId: 'other', location: 'index');

        expect(provider.id, SqliteVectorStoreProvider.providerId);
        expect(provider.canHandle(sqlite), isTrue);
        expect(provider.canHandle(other), isFalse);
        expect(await provider.createStore(sqlite), isA<SqliteVectorStore>());
        await expectLater(provider.createStore(other), throwsUnsupportedError);
      },
    );
  });

  group('SQLite embedding profile record', () {
    late Directory temp;
    late Database db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sqlite_profile_record');
      db = sqlite3.open('${temp.path}/profile.db');
      ensureSqliteEmbeddingProfileTable(db);
    });

    tearDown(() {
      db.close();
      temp.deleteSync(recursive: true);
    });

    test('compare-and-set is exact and idempotent', () async {
      final profile = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
      expect(readSqliteEmbeddingProfile(db), isNull);

      await bindSqliteEmbeddingProfile(db, profile);
      await bindSqliteEmbeddingProfile(db, profile);
      expect(readSqliteEmbeddingProfile(db), profile);

      await expectLater(
        bindSqliteEmbeddingProfile(
          db,
          EmbeddingProfile(id: 'embedder-b-v1', dimension: 4),
        ),
        throwsA(isA<VectorStoreException>()),
      );
      await expectLater(
        bindSqliteEmbeddingProfile(
          db,
          EmbeddingProfile(id: 'embedder-a-v1', dimension: 8),
        ),
        throwsA(isA<VectorStoreException>()),
      );
      expect(readSqliteEmbeddingProfile(db), profile);
      expect(db.autocommit, isTrue, reason: 'a rejected CAS must roll back');
    });

    test('the record persists across database handles', () async {
      final profile = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
      await bindSqliteEmbeddingProfile(db, profile);
      db.close();

      db = sqlite3.open('${temp.path}/profile.db');
      ensureSqliteEmbeddingProfileTable(db);
      expect(readSqliteEmbeddingProfile(db), profile);
    });
  });

  group('SqliteVectorStore profile integration', () {
    final skip = vec0SkipReason;
    late Directory temp;
    late String path;

    setUp(() {
      useHostNativeLibraries();
      temp = Directory.systemTemp.createTempSync('sqlite_profile_store');
      path = '${temp.path}/rag.db';
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('requires a profile, persists it, and clear preserves it', () async {
      final profile = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
      var store = SqliteVectorStore();
      addTearDown(() => store.close());
      await store.initialize(path);

      expect(await store.readEmbeddingProfile(), isNull);
      await expectLater(
        store.addDocument(
          id: 'unbound',
          content: 'unsafe',
          embedding: const [1, 0, 0, 0],
        ),
        throwsStateError,
      );

      await store.bindEmbeddingProfile(profile);
      await store.addDocument(
        id: 'doc',
        content: 'safe',
        embedding: const [1, 0, 0, 0],
      );
      await store.clear();
      expect(await store.readEmbeddingProfile(), profile);
      await expectLater(
        store.addDocument(
          id: 'wrong',
          content: 'wrong dimension',
          embedding: const [1, 0],
        ),
        throwsArgumentError,
      );
      await store.close();

      store = SqliteVectorStore();
      await store.initialize(path);
      expect(await store.readEmbeddingProfile(), profile);
      expect((await store.getStats()).documentCount, 0);
    }, skip: skip);

    test('a legacy shard is profile-null until explicitly adopted', () async {
      final bootstrap = SqliteVectorStore();
      await bootstrap.initialize(path);
      await bootstrap.close();

      final raw = sqlite3.open(path);
      raw.execute('''
CREATE VIRTUAL TABLE vec_documents USING vec0(
  id TEXT PRIMARY KEY,
  embedding float[4] distance_metric=cosine,
  +content TEXT,
  +metadata TEXT
)
''');
      raw.execute(
        'INSERT INTO vec_documents(id, embedding, content, metadata) '
        "VALUES ('legacy', '[1,0,0,0]', 'legacy', NULL)",
      );
      raw.close();

      final store = SqliteVectorStore();
      addTearDown(store.close);
      await store.initialize(path);
      expect(await store.readEmbeddingProfile(), isNull);
      expect((await store.getStats()).documentCount, 1);

      await expectLater(
        store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'wrong-dimension-v1', dimension: 8),
        ),
        throwsA(isA<VectorStoreException>()),
      );
      expect(await store.readEmbeddingProfile(), isNull);

      final profile = EmbeddingProfile(id: 'known-legacy-v1', dimension: 4);
      await store.bindEmbeddingProfile(profile);
      expect(await store.readEmbeddingProfile(), profile);
      await expectLater(
        store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'wrong-legacy-v1', dimension: 4),
        ),
        throwsA(isA<VectorStoreException>()),
      );
    }, skip: skip);

    test(
      'a suspended bind cannot authorize the next database location',
      () async {
        final pathA = '${temp.path}/a.db';
        final pathB = '${temp.path}/b.db';
        final fenceEntered = Completer<void>();
        final releaseFence = Completer<void>();
        final profileA = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
        final store = SqliteVectorStore(
          durabilityFenceForTesting: () async {
            fenceEntered.complete();
            await releaseFence.future;
          },
        );
        addTearDown(store.close);
        await store.initialize(pathA);

        final bindingA = store.bindEmbeddingProfile(profileA);
        await fenceEntered.future;
        final switchingToB = store.initialize(pathB);

        expect(store.isInitialized, isFalse);
        await expectLater(store.readEmbeddingProfile(), throwsStateError);
        await expectLater(
          store.addDocument(
            id: 'blocked-during-switch',
            content: 'blocked',
            embedding: const [1, 0, 0, 0],
          ),
          throwsStateError,
        );

        releaseFence.complete();
        await bindingA;
        await switchingToB;

        expect(await store.readEmbeddingProfile(), isNull);
        await expectLater(
          store.addDocument(
            id: 'must-not-use-a',
            content: 'unbound B',
            embedding: const [1, 0, 0, 0],
          ),
          throwsStateError,
        );

        final reopenedA = SqliteVectorStore();
        addTearDown(reopenedA.close);
        await reopenedA.initialize(pathA);
        expect(await reopenedA.readEmbeddingProfile(), profileA);

        final reopenedB = SqliteVectorStore();
        addTearDown(reopenedB.close);
        await reopenedB.initialize(pathB);
        expect(await reopenedB.readEmbeddingProfile(), isNull);
      },
      skip: skip,
    );

    test('close waits for a suspended bind and clears its cache', () async {
      final fenceEntered = Completer<void>();
      final releaseFence = Completer<void>();
      final profile = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
      final store = SqliteVectorStore(
        durabilityFenceForTesting: () async {
          fenceEntered.complete();
          await releaseFence.future;
        },
      );
      addTearDown(store.close);
      await store.initialize(path);

      final binding = store.bindEmbeddingProfile(profile);
      await fenceEntered.future;
      final closing = store.close();

      expect(store.isInitialized, isFalse);
      await expectLater(store.readEmbeddingProfile(), throwsStateError);
      releaseFence.complete();
      await binding;
      await closing;

      expect(store.isInitialized, isFalse);
      await expectLater(store.readEmbeddingProfile(), throwsStateError);

      final reopened = SqliteVectorStore();
      addTearDown(reopened.close);
      await reopened.initialize(path);
      expect(await reopened.readEmbeddingProfile(), profile);
    }, skip: skip);
  });
}
