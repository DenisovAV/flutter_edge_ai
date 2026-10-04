// Native vec0 store test — runs against the real sqlite-vec loadable extension
// resolved by test/vec0_locator.dart (this repo's
// native/sqlite_vec/prebuilt/<platform>/, or $VEC0_DYLIB).
//
//   flutter test test/sqlite_vector_store_test.dart
//
// This group used to require $VEC0_DYLIB and skipped itself when it was unset —
// which was always, so its 23 tests had never run.
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  // The store loads vec0 itself (Native Assets / the bundled sqlite3), so the
  // locator is only a gate: it answers "is the loadable present on this host",
  // not "here is the handle to use".
  final skip = vec0SkipReason;

  group('a failed initialize() must not report itself ready', () {
    test('isInitialized is false after initialize() throws', () async {
      // `_isInitialized = true` used to sit BEFORE the dimension detection,
      // inside the same try. A schema this release cannot read made detection
      // throw, the catch reported failure to the caller — and the flag stayed
      // true. A caller doing `try { await initialize(p); } catch (_) {}` and
      // then gating on `isInitialized` got a green light out of a failure.
      //
      // The contract says "true if [initialize] was called successfully"
      // (VectorStoreRepository), and the qdrant sibling answers false here.
      useHostNativeLibraries();
      final tmp = Directory.systemTemp.createTempSync('sqlite_init_fail');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final path = '${tmp.path}/rag.db';

      // A `vec_documents` that is not the shape this release expects.
      final raw = sqlite3.open(path);
      raw.execute('CREATE TABLE vec_documents (id TEXT, nonsense INTEGER)');
      raw.dispose();

      final store = SqliteVectorStore();
      addTearDown(() => store.close().catchError((Object _) {}));
      await expectLater(
        store.initialize(path),
        throwsA(isA<VectorStoreException>()),
      );
      expect(
        store.isInitialized,
        isFalse,
        reason: 'an initialize() that threw reported the store as ready',
      );

      // NOT asserted here: that the handle was released. Clearing the flag
      // alone leaked it — close() returned early on `!_isInitialized`, so a
      // failed store kept the database open — and the catch now closes it.
      // But sqlite allows concurrent connections, so a leaked handle is not
      // observable from a second open on the same path: a test written that
      // way passes with the leak still present. Measured by mutation, then
      // left out rather than kept as decoration.
    }, skip: vec0SkipReason);

    test(
      're-initializing onto another database forgets the old dimension',
      () async {
        // `_detectDimensionFromExistingTable` returned early without resetting,
        // so a store moved from a populated database to an empty one kept the
        // first one's dimension — and then rejected the first vector it was
        // given against a shape the new database never had.
        useHostNativeLibraries();
        final tmp = Directory.systemTemp.createTempSync('sqlite_redim');
        addTearDown(() {
          try {
            tmp.deleteSync(recursive: true);
          } catch (_) {}
        });

        final store = SqliteVectorStore();
        addTearDown(() => store.close().catchError((Object _) {}));
        await store.initialize('${tmp.path}/a.db');
        await store.addDocument(
          id: 'a',
          content: 'x',
          embedding: List<double>.filled(4, 1),
        );

        await store.initialize('${tmp.path}/b.db');
        await store.addDocument(
          id: 'b',
          content: 'y',
          embedding: List<double>.filled(8, 1),
        );
        expect((await store.getStats()).documentCount, 1);
      },
      skip: vec0SkipReason,
    );
  });

  group('SqliteVectorStore (vec0)', () {
    late SqliteVectorStore repo;
    late String dbPath;

    setUp(() {
      useHostNativeLibraries();
      repo = SqliteVectorStore();
      dbPath =
          '${Directory.systemTemp.path}/test_vec0_store_'
          '${DateTime.now().microsecondsSinceEpoch}.db';
    });

    tearDown(() async {
      await repo.close();
      final file = File(dbPath);
      if (file.existsSync()) file.deleteSync();
    });

    test('initialize creates a database file', () async {
      await repo.initialize(dbPath);
      expect(repo.isInitialized, true);
      expect(File(dbPath).existsSync(), true);
    });

    test('addDocument + getStats reports count and dimension', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Hello world',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      final stats = await repo.getStats();
      expect(stats.documentCount, 1);
      expect(stats.vectorDimension, 4);
    });

    test('getStats before any add reports zero / zero', () async {
      await repo.initialize(dbPath);
      final stats = await repo.getStats();
      expect(stats.documentCount, 0);
      expect(stats.vectorDimension, 0);
    });

    test('addDocument with same id replaces (INSERT OR REPLACE)', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Version 1',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      await repo.addDocument(
        id: 'doc1',
        content: 'Version 2',
        embedding: [0.0, 1.0, 0.0, 0.0],
      );
      final stats = await repo.getStats();
      expect(stats.documentCount, 1);

      final results = await repo.searchSimilar(
        queryEmbedding: [0.0, 1.0, 0.0, 0.0],
        topK: 1,
      );
      expect(results.single.content, 'Version 2');
    });

    test('addDocument validates dimension', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Hello',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      expect(
        () => repo.addDocument(
          id: 'doc2',
          content: 'World',
          embedding: [1.0, 0.0], // wrong dimension
        ),
        throwsArgumentError,
      );
    });

    test('searchSimilar returns cosine similarity (1 = identical), top-K '
        'ordered descending', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Similar',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      await repo.addDocument(
        id: 'doc2',
        content: 'Near',
        embedding: [0.9, 0.1, 0.0, 0.0],
      );
      await repo.addDocument(
        id: 'doc3',
        content: 'Orthogonal',
        embedding: [0.0, 1.0, 0.0, 0.0],
      );
      final results = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0, 0.0, 0.0],
        topK: 3,
      );
      expect(results.length, 3);
      expect(results.first.id, 'doc1');
      expect(results.first.similarity, closeTo(1.0, 0.01));
      // Descending similarity order.
      for (var i = 1; i < results.length; i++) {
        expect(
          results[i].similarity,
          lessThanOrEqualTo(results[i - 1].similarity),
        );
      }
      expect(results.last.id, 'doc3');
    });

    test('searchSimilar respects topK', () async {
      await repo.initialize(dbPath);
      for (var i = 0; i < 5; i++) {
        await repo.addDocument(
          id: 'doc$i',
          content: 'Document $i',
          embedding: [1.0 - i * 0.1, i * 0.1, 0.0, 0.0],
        );
      }
      final results = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0, 0.0, 0.0],
        topK: 2,
      );
      expect(results.length, 2);
    });

    test('searchSimilar respects threshold', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Identical',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      await repo.addDocument(
        id: 'doc2',
        content: 'Orthogonal',
        embedding: [0.0, 1.0, 0.0, 0.0],
      );
      final results = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0, 0.0, 0.0],
        topK: 2,
        threshold: 0.5,
      );
      expect(results.length, 1);
      expect(results.first.id, 'doc1');
    });

    test('searchSimilar before any add returns empty', () async {
      await repo.initialize(dbPath);
      final results = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0, 0.0, 0.0],
        topK: 5,
      );
      expect(results, isEmpty);
    });

    test(
      'removeDocument removes the row (and is a no-op for missing id)',
      () async {
        await repo.initialize(dbPath);
        await repo.addDocument(
          id: 'doc1',
          content: 'Hello',
          embedding: [1.0, 0.0, 0.0, 0.0],
        );
        await repo.removeDocument(id: 'missing'); // no-op, no throw
        await repo.removeDocument(id: 'doc1');
        final stats = await repo.getStats();
        expect(stats.documentCount, 0);
      },
    );

    test('clear removes all documents and resets dimension', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Hello',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      await repo.clear();
      final stats = await repo.getStats();
      expect(stats.documentCount, 0);
      expect(stats.vectorDimension, 0);
      // Re-detect a NEW dimension after clear.
      await repo.addDocument(
        id: 'doc2',
        content: 'New dims',
        embedding: [1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      );
      final stats2 = await repo.getStats();
      expect(stats2.vectorDimension, 6);
    });

    test('close then reinitialize — data persists on disk', () async {
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'doc1',
        content: 'Persistent',
        embedding: [1.0, 0.0, 0.0, 0.0],
      );
      await repo.close();

      repo = SqliteVectorStore();
      await repo.initialize(dbPath);
      final stats = await repo.getStats();
      expect(stats.documentCount, 1);
      expect(stats.vectorDimension, 4);
    });

    test('uninitialized operations throw StateError', () async {
      final fresh = SqliteVectorStore();
      expect(
        () => fresh.addDocument(id: 'x', content: 'x', embedding: [1.0]),
        throwsStateError,
      );
      expect(
        () => fresh.searchSimilar(queryEmbedding: [1.0], topK: 1),
        throwsStateError,
      );
      expect(fresh.getStats, throwsStateError);
      expect(fresh.clear, throwsStateError);
      expect(() => fresh.removeDocument(id: 'x'), throwsStateError);
    });

    group('declared-column Filter', () {
      final schema = FilterSchema(
        fields: [
          FilterField(name: 'lang', type: FilterFieldType.string),
          FilterField(name: 'year', type: FilterFieldType.number),
          FilterField(name: 'archived', type: FilterFieldType.bool),
        ],
      );

      setUp(() {
        repo.configure(schema);
      });

      test(
        'over-fetches past the top-k when the filter is not pushable',
        () async {
          // A cross-column OR cannot be pushed into vec0's KNN, so SQLite applies
          // it AFTER vec0 has already chosen k rows. Without over-fetching this
          // returns nothing: the nearest rows match neither condition, and a
          // post-filter cannot reach past them.
          //
          // Seed so the two nearest are non-matching and the matches sit behind
          // them — the exact shape that used to come back empty.
          await repo.initialize(dbPath);
          for (var i = 0; i < 6; i++) {
            await repo.addDocument(
              id: 'near$i',
              content: 'near $i',
              embedding: [1.0 - i * 0.01, i * 0.01, 0.0, 0.0],
              metadata: '{"lang":"de","year":1990,"archived":false}',
            );
          }
          await repo.addDocument(
            id: 'far-fr',
            content: 'far fr',
            embedding: [0.0, 1.0, 0.0, 0.0],
            metadata: '{"lang":"fr","year":1990,"archived":false}',
          );
          await repo.addDocument(
            id: 'far-2020',
            content: 'far 2020',
            embedding: [0.0, 0.9, 0.1, 0.0],
            metadata: '{"lang":"de","year":2020,"archived":false}',
          );

          final got = await repo.searchSimilar(
            queryEmbedding: [1.0, 0.0, 0.0, 0.0],
            topK: 2,
            filter: const Filter(
              should: [
                FieldEquals(key: 'lang', value: 'fr'),
                FieldEquals(key: 'year', value: 2020),
              ],
            ),
          );

          expect(
            got.map((r) => r.id),
            unorderedEquals(['far-fr', 'far-2020']),
            reason:
                'without over-fetch the post-filter sees only the 2 nearest, '
                'which match neither condition, and returns nothing',
          );
        },
      );

      Future<void> seed() async {
        await repo.addDocument(
          id: 'en2020',
          content: 'English 2020',
          embedding: [1.0, 0.0, 0.0, 0.0],
          metadata: '{"lang":"en","year":2020,"archived":false}',
        );
        await repo.addDocument(
          id: 'fr2020',
          content: 'French 2020',
          embedding: [0.95, 0.05, 0.0, 0.0],
          metadata: '{"lang":"fr","year":2020,"archived":false}',
        );
        await repo.addDocument(
          id: 'en1999',
          content: 'English 1999 archived',
          embedding: [0.9, 0.1, 0.0, 0.0],
          metadata: '{"lang":"en","year":1999,"archived":true}',
        );
      }

      test('filterSchema is exposed after configure', () {
        expect(repo.filterSchema.fields, hasLength(3));
      });

      test('FieldEquals on a declared string column', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            must: [FieldEquals(key: 'lang', value: 'en')],
          ),
        );
        expect(results.map((r) => r.id).toSet(), {'en2020', 'en1999'});
      });

      test('FieldRange on a declared number column', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(must: [FieldRange(key: 'year', gte: 2000.0)]),
        );
        expect(results.map((r) => r.id).toSet(), {'en2020', 'fr2020'});
      });

      test('FieldMatchAny on a declared string column', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            must: [
              FieldMatchAny(key: 'lang', values: ['fr', 'de']),
            ],
          ),
        );
        expect(results.map((r) => r.id).toSet(), {'fr2020'});
      });

      test('bool column filters via mustNot', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            mustNot: [FieldEquals(key: 'archived', value: true)],
          ),
        );
        expect(results.map((r) => r.id).toSet(), {'en2020', 'fr2020'});
      });

      test('mustNot with TWO conditions excludes if EITHER matches', () async {
        // Regression test for the AND/OR mustNot bug: a row must be excluded if
        // it matches ANY mustNot condition (NOT (A OR B)), not only if it
        // matches ALL of them (the old buggy NOT (A AND B)).
        //   en2020: lang=en, year=2020 → matches neither → KEPT
        //   fr2020: lang=fr          → matches first    → excluded
        //   en1999: year=1999        → matches second   → excluded
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            mustNot: [
              FieldEquals(key: 'lang', value: 'fr'),
              FieldRange(key: 'year', lte: 1999.0),
            ],
          ),
        );
        // With the bug this would return all three rows.
        expect(results.map((r) => r.id).toSet(), {'en2020'});
      });

      test('must + should + mustNot combine', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            must: [FieldRange(key: 'year', gte: 2000.0)],
            should: [
              FieldEquals(key: 'lang', value: 'en'),
              FieldEquals(key: 'lang', value: 'fr'),
            ],
            mustNot: [FieldEquals(key: 'archived', value: true)],
          ),
        );
        expect(results.map((r) => r.id).toSet(), {'en2020', 'fr2020'});
      });

      test('undeclared-key filter is a no-op (never throws)', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 10,
          filter: const Filter(
            must: [FieldEquals(key: 'not_declared', value: 'x')],
          ),
        );
        // No declared column → filter contributes nothing → all rows returned.
        expect(results, hasLength(3));
      });

      test('metadata round-trips on the result', () async {
        await repo.initialize(dbPath);
        await seed();
        final results = await repo.searchSimilar(
          queryEmbedding: [1.0, 0.0, 0.0, 0.0],
          topK: 1,
        );
        expect(results.single.metadata, contains('"lang":"en"'));
      });
    });

    // FilterField.namePattern accepts SQL keywords, because a keyword is a
    // perfectly good qdrant payload key and banning it would have no
    // cross-backend justification. vec0's DDL tokenizer has no keyword table,
    // so `order TEXT` declares fine — but the INSERT and the KNN WHERE are
    // parsed by SQLite, where a bare `order` is a syntax error. The stores
    // therefore quote in those two statements only (never in the DDL, which
    // vec0 parses and where quoting is rejected outright). This exercises the
    // whole round-trip against the real extension.

    test('a SQL-keyword column name round-trips end to end', () async {
      repo.configure(
        FilterSchema(
          fields: [
            FilterField(name: 'order', type: FilterFieldType.string),
            FilterField(name: 'select', type: FilterFieldType.number),
          ],
        ),
      );
      await repo.initialize(dbPath);
      await repo.addDocument(
        id: 'a',
        content: 'first',
        embedding: [1.0, 0.0],
        metadata: '{"order":"asc","select":1}',
      );
      await repo.addDocument(
        id: 'b',
        content: 'second',
        embedding: [0.9, 0.1],
        metadata: '{"order":"desc","select":2}',
      );

      final equals = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0],
        topK: 10,
        filter: const Filter(
          must: [FieldEquals(key: 'order', value: 'desc')],
        ),
      );
      expect(equals.map((r) => r.id), ['b']);

      final range = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0],
        topK: 10,
        filter: const Filter(must: [FieldRange(key: 'select', lte: 1.0)]),
      );
      expect(range.map((r) => r.id), ['a']);

      // mustNot goes through the separate negated-encode path.
      final negated = await repo.searchSimilar(
        queryEmbedding: [1.0, 0.0],
        topK: 10,
        filter: const Filter(
          mustNot: [FieldEquals(key: 'order', value: 'asc')],
        ),
      );
      expect(negated.map((r) => r.id), ['b']);
    });
  }, skip: skip);
}
