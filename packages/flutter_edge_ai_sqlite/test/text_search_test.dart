// Text and hybrid search on the native SQLite store, against the real
// package:sqlite3 binary (FTS5) and the real vec0 loadable.
//
//   flutter test test/text_search_test.dart
//
// The reconcile benchmark at 10k and 50k documents is opt-in:
//   RAG_TEXT_BENCH=1 flutter test test/text_search_test.dart --name bench
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart' as parity;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

final _profile = EmbeddingProfile(id: 'text-search-test-v1', dimension: 4);

final _schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'year', type: FilterFieldType.number),
    FilterField(name: 'draft', type: FilterFieldType.bool),
  ],
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

Future<RagIndex> _open(
  String path, {
  bool enableTextSearch = true,
  SqliteTextTokenizer? tokenizer,
  FilterSchema? schema,
}) async {
  final rag = FlutterEdgeAiRag(
    providers: [SqliteVectorStoreProvider(textTokenizer: tokenizer)],
  );
  final index = await rag.openVectors(
    spec: VectorStoreSpec(
      providerId: SqliteVectorStoreProvider.providerId,
      location: path,
      filterSchema: schema ?? _schema,
      enableTextSearch: enableTextSearch,
    ),
    profile: _profile,
  );
  addTearDown(index.dispose);
  return index;
}

/// A unit vector along [axis], so cosine order is easy to read.
List<double> _axis(int axis) => [for (var i = 0; i < 4; i++) i == axis ? 1 : 0];

Future<void> _add(
  RagIndex index,
  String id,
  String content, {
  int axis = 0,
  Map<String, Object?>? metadata,
}) => index.addVector(
  id: id,
  content: content,
  embedding: _axis(axis),
  metadata: metadata == null ? null : jsonEncode(metadata),
);

Future<List<String>> _ids(
  RagIndex index,
  String text, {
  int topK = 10,
  Filter? filter,
}) async => [
  for (final hit in await index.searchText(
    text: text,
    topK: topK,
    filter: filter,
  ))
    hit.id,
];

void main() {
  final skip = vec0SkipReason;
  setUpAll(useHostNativeLibraries);

  test('FTS5 is compiled into the package:sqlite3 binary', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final version = db.select('SELECT sqlite_version() AS v').first['v'];
    final fts5 = db
        .select("SELECT sqlite_compileoption_used('ENABLE_FTS5') AS f")
        .first['f'];
    db.execute("CREATE VIRTUAL TABLE t USING fts5(c, tokenize='trigram')");
    db.execute("INSERT INTO t VALUES ('hello world')");
    final rows = db.select(
      "SELECT bm25(t) AS s FROM t WHERE t MATCH '\"world\"'",
    );
    // ignore: avoid_print
    print(
      'FTS5 on ${Platform.operatingSystem}: SQLite $version, '
      'ENABLE_FTS5=$fts5, bm25=${rows.first['s']}',
    );
    expect(fts5, 1);
    expect(rows, hasLength(1));
  });

  group('searchText', () {
    test('ranks by BM25, best first, with any query term', () async {
      final index = await _open(_tempDb('fts_rank'));
      await _add(index, 'a', 'the cat sat on the mat');
      await _add(index, 'b', 'cat cat cat: a story about a cat');
      await _add(index, 'c', 'a dog in the fog');
      // BM25 gives a term found in half the corpus or more an IDF of ~0, so
      // the corpus needs documents with neither term.
      for (var i = 0; i < 6; i++) {
        await _add(index, 'filler$i', 'nothing to see here $i');
      }

      final cat = await index.searchText(text: 'cat');
      expect([for (final h in cat) h.id], ['b', 'a']);
      expect(cat.first.relevanceScore, greaterThan(cat[1].relevanceScore));
      expect(cat.first.relevanceScore, greaterThan(0));
      expect(cat.first.content, 'cat cat cat: a story about a cat');

      expect(await _ids(index, 'cat dog'), unorderedEquals(['a', 'b', 'c']));
    }, skip: skip);

    test('topK caps the result', () async {
      final index = await _open(_tempDb('fts_topk'));
      for (var i = 0; i < 5; i++) {
        await _add(index, 'd$i', 'apple number $i');
      }
      expect(await _ids(index, 'apple', topK: 2), hasLength(2));
    }, skip: skip);

    test('unicode61 ignores case and diacritics', () async {
      final index = await _open(_tempDb('fts_diacritics'));
      await _add(index, 'a', 'Un Café à Paris');
      await _add(index, 'b', 'Привет, Мир');
      expect(await _ids(index, 'cafe'), ['a']);
      expect(await _ids(index, 'CAFÉ'), ['a']);
      expect(await _ids(index, 'мир'), ['b']);
    }, skip: skip);

    test('query syntax never reaches FTS5', () async {
      final index = await _open(_tempDb('fts_quote'));
      await _add(index, 'a', 'alpha NEAR beta');
      await _add(index, 'b', 'say "hello"');
      for (final text in [
        '"',
        '""',
        '"a""b"',
        '...',
        '*',
        'alpha*',
        'NEAR(alpha beta)',
        '-alpha',
        'content:alpha',
        '^alpha',
        'alpha OR',
        'AND',
        '(',
      ]) {
        await expectLater(
          index.searchText(text: text),
          completes,
          reason: 'query "$text" must not be an FTS5 syntax error',
        );
      }
      expect(await _ids(index, '...'), isEmpty);
      expect(await _ids(index, '"hello"'), ['b']);
      expect(await _ids(index, 'NEAR'), ['a']);
    }, skip: skip);

    test('a blank text is an ArgumentError', () async {
      final index = await _open(_tempDb('fts_blank'));
      await expectLater(
        index.searchText(text: '  '),
        throwsA(isA<ArgumentError>()),
      );
    }, skip: skip);

    test('porter stems English words', () async {
      final index = await _open(
        _tempDb('fts_porter'),
        tokenizer: SqliteTextTokenizer.porter,
      );
      await _add(index, 'a', 'she was running fast');
      expect(await _ids(index, 'runs'), ['a']);
    }, skip: skip);

    test(
      'trigram matches substrings; terms under 3 chars match nothing',
      () async {
        final index = await _open(
          _tempDb('fts_trigram'),
          tokenizer: SqliteTextTokenizer.trigram,
        );
        await _add(index, 'a', '東京都の天気');
        await _add(index, 'b', 'unbelievable');
        expect(await _ids(index, '東京都'), ['a']);
        expect(await _ids(index, 'liev'), ['b']);
        expect(await _ids(index, 'li'), isEmpty);
      },
      skip: skip,
    );
  });

  group('filters on the text leg', () {
    Future<RagIndex> seeded(String name) async {
      final index = await _open(_tempDb(name));
      await _add(
        index,
        'en20',
        'report',
        metadata: {'lang': 'en', 'year': 2020},
      );
      // An int in JSON: stored REAL, compared against a double bound.
      await _add(
        index,
        'en24',
        'report',
        metadata: {'lang': 'en', 'year': 2024, 'draft': true},
      );
      await _add(
        index,
        'de24',
        'report',
        metadata: {'lang': 'de', 'year': 2024.0, 'draft': false},
      );
      await _add(index, 'none', 'report');
      return index;
    }

    test('string, number, bool and absent fields', () async {
      final index = await seeded('fts_filter');
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(
            must: [FieldEquals(key: 'lang', value: 'en')],
          ),
        ),
        unorderedEquals(['en20', 'en24']),
      );
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(must: [FieldRange(key: 'year', gte: 2024)]),
        ),
        unorderedEquals(['en24', 'de24']),
      );
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(must: [FieldEquals(key: 'year', value: 2024)]),
        ),
        unorderedEquals(['en24', 'de24']),
      );
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(must: [FieldEquals(key: 'draft', value: true)]),
        ),
        ['en24'],
      );
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(
            mustNot: [FieldEquals(key: 'lang', value: 'en')],
          ),
        ),
        unorderedEquals(['de24', 'none']),
      );
      expect(
        await _ids(
          index,
          'report',
          filter: Filter(
            should: [
              FieldEquals(key: 'lang', value: 'de'),
              FieldEquals(key: 'draft', value: true),
            ],
          ),
        ),
        unorderedEquals(['de24', 'en24']),
      );
    }, skip: skip);

    test('the same filter selects the same documents in both legs', () async {
      final index = await seeded('fts_filter_parity');
      final filters = [
        Filter(
          must: [FieldEquals(key: 'lang', value: 'en')],
        ),
        Filter(must: [FieldRange(key: 'year', gte: 2021, lte: 2030)]),
        Filter(mustNot: [FieldEquals(key: 'draft', value: true)]),
        Filter(
          must: [
            FieldMatchAny(key: 'lang', values: ['de', 'fr']),
          ],
        ),
        Filter(
          should: [
            FieldEquals(key: 'lang', value: 'de'),
            FieldRange(key: 'year', lte: 2020),
          ],
        ),
      ];
      for (final filter in filters) {
        final vector = await index.searchVector(
          embedding: _axis(0),
          topK: 10,
          threshold: -1,
          filter: filter,
        );
        expect(
          await _ids(index, 'report', filter: filter),
          unorderedEquals([for (final h in vector) h.id]),
        );
      }
    }, skip: skip);
  });

  test('the shared parity table holds on the text leg', () async {
    // The table the vec0 parity suites (native and web) run, applied to
    // text search: every document carries the query term, so the filter
    // alone decides the result.
    final path = _tempDb('fts_parity_table');
    final store = SqliteVectorStore(enableTextSearch: true);
    addTearDown(store.close);
    store.configure(parity.schema);
    await store.initialize(path);
    await store.bind(
      VectorStoreBinding(
        profile: EmbeddingProfile(
          id: 'text-parity-v1',
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
    expect(parity.cases, isNotEmpty);
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
  }, skip: skip);

  group('writes keep the text index in step', () {
    test('upsert replaces the old text, remove and clear drop it', () async {
      final index = await _open(_tempDb('fts_writes'));
      await _add(index, 'a', 'old words');
      await _add(index, 'a', 'new words');
      expect(await _ids(index, 'old'), isEmpty);
      expect(await _ids(index, 'new'), ['a']);
      expect(await _ids(index, 'words'), ['a']);

      await _add(index, 'b', 'more words');
      await index.remove(id: 'a');
      expect(await _ids(index, 'words'), ['b']);

      await index.clear();
      expect(await _ids(index, 'words'), isEmpty);
      await _add(index, 'c', 'words after clear');
      expect(await _ids(index, 'words'), ['c']);
    }, skip: skip);

    test('a failed text write rolls the vec0 write back', () async {
      final path = _tempDb('fts_rollback');
      final index = await _open(path);
      await _add(index, 'keep', 'original text', axis: 1);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      raw.execute(
        'CREATE TRIGGER boom BEFORE INSERT ON rag_text_documents '
        "WHEN NEW.content LIKE '%boom%' "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );

      await expectLater(
        _add(index, 'fresh', 'boom', axis: 0),
        throwsA(anything),
      );
      await expectLater(
        _add(index, 'keep', 'boom replacement', axis: 0),
        throwsA(anything),
      );

      expect((await index.stats()).documentCount, 1);
      final knn = await index.searchVector(embedding: _axis(1), topK: 5);
      expect([for (final h in knn) h.id], ['keep']);
      expect(knn.single.similarity, closeTo(1.0, 1e-6));
      expect(knn.single.content, 'original text');
      expect(await _ids(index, 'original'), ['keep']);
      expect(await _ids(index, 'boom'), isEmpty);
    }, skip: skip);
  });

  test('a failed COMMIT leaves no transaction open', () async {
    final path = _tempDb('fts_commit_busy');
    final index = await _open(path);
    await _add(index, 'first', 'one');

    // Another connection holding a read transaction makes COMMIT fail with
    // SQLITE_BUSY (rollback journal, no busy timeout).
    final reader = sqlite3.open(path);
    addTearDown(reader.close);
    reader.execute('BEGIN');
    reader.select('SELECT COUNT(*) FROM rag_text_documents');
    await expectLater(_add(index, 'busy', 'two'), throwsA(anything));
    reader.execute('COMMIT');

    // The next write must run in its own transaction and be committed.
    await _add(index, 'later', 'three');
    final check = sqlite3.open(path);
    addTearDown(check.close);
    expect(
      check
          .select('SELECT id FROM rag_text_documents ORDER BY id')
          .map((r) => r['id'])
          .toList(),
      ['first', 'later'],
    );
    expect(
      check.select('SELECT COUNT(*) AS c FROM vec_documents').first['c'],
      2,
    );
  }, skip: skip);

  group('lifecycle', () {
    test('a location without a text index refuses searchText', () async {
      final index = await _open(_tempDb('fts_none'), enableTextSearch: false);
      await _add(index, 'a', 'words');
      await expectLater(
        index.searchText(text: 'words'),
        throwsA(isA<StateError>()),
      );
    }, skip: skip);

    test('enabling text search on an existing store backfills it', () async {
      final path = _tempDb('fts_backfill');
      final plain = await _open(path, enableTextSearch: false);
      await _add(plain, 'a', 'first document', metadata: {'lang': 'en'});
      await _add(plain, 'b', 'second document', metadata: {'lang': 'de'});
      await plain.dispose();

      final index = await _open(path);
      expect(await _ids(index, 'document'), unorderedEquals(['a', 'b']));
      expect(
        await _ids(
          index,
          'document',
          filter: Filter(
            must: [FieldEquals(key: 'lang', value: 'de')],
          ),
        ),
        ['b'],
      );
    }, skip: skip);

    test('an open without the flag keeps an existing index in step', () async {
      final path = _tempDb('fts_noflag');
      final first = await _open(path);
      await _add(first, 'a', 'alpha');
      await first.dispose();

      final second = await _open(path, enableTextSearch: false);
      await _add(second, 'b', 'alpha beta');
      await second.remove(id: 'a');
      expect(await _ids(second, 'alpha'), ['b']);
      await second.dispose();

      final third = await _open(path);
      expect(await _ids(third, 'alpha'), ['b']);
    }, skip: skip);

    test('writes made without the text index are reconciled on open', () async {
      final path = _tempDb('fts_drift');
      final index = await _open(path);
      await _add(index, 'a', 'apple');
      await _add(index, 'b', 'banana');
      await _add(index, 'c', 'cherry');
      await index.dispose();

      // What a release without text search does: vec0 writes only. vec0 is
      // registered process-wide by the store, so a raw connection has it.
      final raw = sqlite3.open(path);
      raw.execute("DELETE FROM vec_documents WHERE id = 'a'");
      _rawInsert(raw, 'a', 'apricot', lang: 'x', metadata: '{"lang":"x"}');
      raw.execute("DELETE FROM vec_documents WHERE id = 'b'");
      _rawInsert(raw, 'd', 'date');
      raw.close();

      final reopened = await _open(path, enableTextSearch: false);
      expect(await _ids(reopened, 'apple'), isEmpty);
      expect(await _ids(reopened, 'apricot'), ['a']);
      expect(await _ids(reopened, 'banana'), isEmpty);
      expect(await _ids(reopened, 'cherry'), ['c']);
      expect(await _ids(reopened, 'date'), ['d']);
      expect(
        await _ids(
          reopened,
          'apricot date',
          filter: Filter(
            must: [FieldEquals(key: 'lang', value: 'x')],
          ),
        ),
        ['a'],
      );
    }, skip: skip);

    test(
      'a clear and re-add of the same count without the index is caught',
      () async {
        final path = _tempDb('fts_clear_readd');
        final index = await _open(path);
        await _add(index, 'a', 'one');
        await _add(index, 'b', 'two');
        await index.dispose();

        final plain = sqlite3.open(path);
        plain.execute('DROP TABLE vec_documents');
        plain.close();
        final old = await _open(path, enableTextSearch: false, schema: _schema);
        // The text index still holds 'one' and 'two'; this open reconciled it
        // against a missing vec_documents and emptied it.
        expect(await _ids(old, 'one'), isEmpty);
        await _add(old, 'a', 'three');
        await _add(old, 'b', 'four');
        expect(await _ids(old, 'three'), ['a']);
      },
      skip: skip,
    );

    test('a tokenizer differing from the stored one fails the open', () async {
      final path = _tempDb('fts_tokenizer');
      final first = await _open(path, tokenizer: SqliteTextTokenizer.trigram);
      await _add(first, 'a', 'substring');
      await first.dispose();

      await expectLater(
        _open(path, tokenizer: SqliteTextTokenizer.porter),
        throwsA(isA<VectorStoreException>()),
      );
      final reopened = await _open(path);
      expect(await _ids(reopened, 'bstr'), ['a'], reason: 'kept trigram');
    }, skip: skip);

    test('a schema change rebuilds the index', () async {
      final path = _tempDb('fts_schema');
      final first = await _open(
        path,
        schema: FilterSchema(
          fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
        ),
      );
      await _add(first, 'a', 'words', metadata: {'lang': 'en', 'year': 2024});
      await first.dispose();

      final raw = sqlite3.open(path);
      final before =
          raw
                  .select(
                    "SELECT sql FROM sqlite_master WHERE name = 'rag_text_documents'",
                  )
                  .first['sql']
              as String;
      raw.close();
      expect(before, isNot(contains('"year"')));

      final second = await _open(
        path,
        schema: FilterSchema(
          fields: [
            FilterField(name: 'lang', type: FilterFieldType.string),
            FilterField(name: 'year', type: FilterFieldType.number),
          ],
        ),
      );
      expect(
        await _ids(
          second,
          'words',
          filter: Filter(must: [FieldRange(key: 'year', gte: 2024)]),
        ),
        ['a'],
      );
    }, skip: skip);

    test('a failed build leaves no partial index behind', () async {
      final path = _tempDb('fts_backfill_fail');
      final plain = await _open(path, enableTextSearch: false);
      for (var i = 0; i < 5; i++) {
        await _add(plain, 'd$i', 'doc $i');
      }
      await plain.dispose();

      // A table already holding the name of one of FTS5's shadow tables makes
      // the FTS5 CREATE fail after the text table was created in the same
      // transaction.
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      raw.execute('CREATE TABLE rag_text_fts_data(x)');

      final failing = SqliteVectorStore(enableTextSearch: true);
      addTearDown(failing.close);
      await expectLater(
        failing.initialize(path),
        throwsA(isA<VectorStoreException>()),
      );
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE name LIKE 'rag_text%'",
        ),
        [
          {'name': 'rag_text_fts_data'},
        ],
        reason: 'the build is one transaction',
      );

      raw.execute('DROP TABLE rag_text_fts_data');
      final index = await _open(path);
      expect(await _ids(index, 'doc', topK: 10), hasLength(5));
    }, skip: skip);
  });

  group('hybrid', () {
    test('fuses both legs with RRF', () async {
      final index = await _open(_tempDb('fts_hybrid'));
      await _add(index, 'both', 'solar panel efficiency', axis: 0);
      await _add(index, 'vector', 'unrelated words', axis: 1);
      await _add(index, 'text', 'solar storms', axis: 3);
      await _add(index, 'neither', 'gardening tips', axis: 2);

      final hits = await index.searchHybridVector(
        text: 'solar',
        // Vector ranks: both 1, vector 2, then the others; 'both' wins on
        // the vector rank, not on how BM25 breaks a near tie.
        embedding: [0.9, 0.4, 0, 0],
        topK: 3,
      );
      expect(hits.first.id, 'both');
      expect(hits.first.vectorRank, isNotNull);
      expect(hits.first.textRank, isNotNull);
      expect(
        hits.first.rrfScore,
        closeTo(
          1 / (60 + hits.first.vectorRank!) + 1 / (60 + hits.first.textRank!),
          1e-12,
        ),
      );
      final text = hits.firstWhere((h) => h.id == 'text');
      expect(text.relevanceScore, isNotNull);
      expect(text.textRank, isNotNull);
      // The vector leg keeps every candidate, also an orthogonal one.
      expect(text.vectorSimilarity, closeTo(0.0, 1e-6));
      expect(hits, hasLength(3));
    }, skip: skip);

    test('needs a text index', () async {
      final index = await _open(
        _tempDb('fts_hybrid_none'),
        enableTextSearch: false,
      );
      await expectLater(
        index.searchHybridVector(text: 'x', embedding: _axis(0)),
        throwsA(isA<StateError>()),
      );
    }, skip: skip);
  });

  test(
    'bench: reconcile on open at 10k and 50k documents',
    () async {
      final random = Random(7);
      for (final count in [10000, 50000]) {
        final path = _tempDb('fts_bench_$count');
        final store = SqliteVectorStore();
        await store.initialize(path);
        await store.bind(
          VectorStoreBinding(
            profile: EmbeddingProfile(id: 'bench', dimension: 768),
          ),
        );
        final words = [for (var i = 0; i < 2000; i++) 'w$i'];
        String text() => [
          for (var j = 0; j < 60; j++) words[random.nextInt(words.length)],
        ].join(' ');
        List<double> vector() => [
          for (var j = 0; j < 768; j++) random.nextDouble() - 0.5,
        ];
        // The first add creates the vec0 table; the rest go in through one
        // raw transaction, which is how a corpus this size gets loaded fast.
        await store.addDocument(
          id: 'doc0',
          content: text(),
          embedding: vector(),
          metadata: '{"n":0}',
        );
        await store.close();
        final db = sqlite3.open(path);
        db.execute('BEGIN');
        final insert = db.prepare(
          'INSERT INTO vec_documents (id, embedding, content, metadata) '
          'VALUES (?, ?, ?, ?)',
        );
        for (var i = 1; i < count; i++) {
          insert.execute([
            'doc$i',
            SqliteTextIndexTestBlob.of(vector()),
            text(),
            '{"n":$i}',
          ]);
        }
        insert.close();
        db.execute('COMMIT');
        db.close();

        var watch = Stopwatch()..start();
        final building = SqliteVectorStore(enableTextSearch: true);
        await building.initialize(path);
        final backfillMs = watch.elapsedMilliseconds;
        await building.close();

        final timings = <int>[];
        for (var run = 0; run < 5; run++) {
          watch = Stopwatch()..start();
          final reopened = SqliteVectorStore();
          await reopened.initialize(path);
          timings.add(watch.elapsedMilliseconds);
          await reopened.close();
        }
        final plainTimings = <int>[];
        final noText = sqlite3.open(path);
        noText.execute('DROP TABLE rag_text_fts');
        noText.execute('DROP TABLE rag_text_documents');
        noText.execute('VACUUM');
        noText.close();
        final plainSize = File(path).lengthSync();
        for (var run = 0; run < 5; run++) {
          watch = Stopwatch()..start();
          final reopened = SqliteVectorStore();
          await reopened.initialize(path);
          plainTimings.add(watch.elapsedMilliseconds);
          await reopened.close();
        }
        final withText = SqliteVectorStore(enableTextSearch: true);
        await withText.initialize(path);
        await withText.close();
        final textSize = File(path).lengthSync();
        timings.sort();
        plainTimings.sort();
        // ignore: avoid_print
        print(
          'bench $count docs: backfill ${backfillMs}ms, open with text index '
          'median ${timings[2]}ms (min ${timings.first}, max ${timings.last}), '
          'open without median ${plainTimings[2]}ms, file '
          '${(plainSize / 1048576).toStringAsFixed(1)} MiB -> '
          '${(textSize / 1048576).toStringAsFixed(1)} MiB',
        );
      }
    },
    skip: Platform.environment['RAG_TEXT_BENCH'] == null
        ? 'opt-in: RAG_TEXT_BENCH=1'
        : skip,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// A vec0 write as a release without text search makes it: vec0 only.
void _rawInsert(
  Database raw,
  String id,
  String? content, {
  String? lang,
  String? metadata,
}) {
  raw.execute(
    'INSERT INTO vec_documents '
    '(id, embedding, lang, year, draft, content, metadata) '
    'VALUES (?, ?, ?, -9e999, -9223372036854775808, ?, ?)',
    [
      id,
      SqliteTextIndexTestBlob.of(_axis(2)),
      lang ?? '\u0000__absent__',
      content,
      metadata,
    ],
  );
}

/// float32 little-endian, as the stores write it.
abstract final class SqliteTextIndexTestBlob {
  static List<int> of(List<double> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
