// Text and hybrid search through the public RagIndex API, on the real
// qdrant-edge engine (delivered by the qdrant_edge SDK's Native Assets hook).
// The scenarios mirror flutter_edge_ai_sqlite's text_search_test, so both
// stores are held to the same contract.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

final _profile = EmbeddingProfile(
  id: 'qdrant-text-search-test-v1',
  dimension: 4,
);

final _schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'year', type: FilterFieldType.number),
    FilterField(name: 'draft', type: FilterFieldType.bool),
  ],
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

Future<RagIndex> _open(String path, {bool enableTextSearch = true}) async {
  final rag = FlutterEdgeAiRag(providers: const [QdrantVectorStoreProvider()]);
  final index = await rag.openVectors(
    spec: VectorStoreSpec(
      providerId: 'qdrant',
      location: path,
      filterSchema: _schema,
      enableTextSearch: enableTextSearch,
    ),
    profile: _profile,
  );
  addTearDown(index.dispose);
  return index;
}

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
  group('searchText', () {
    test('ranks by BM25, best first, with any query term', () async {
      final index = await _open(_tempLocation('qt_rank'));
      await _add(index, 'a', 'the cat sat on the mat');
      await _add(index, 'b', 'cat cat cat: a story about a cat');
      await _add(index, 'c', 'a dog in the fog');
      for (var i = 0; i < 6; i++) {
        await _add(index, 'filler$i', 'nothing to see here $i');
      }

      final cat = await index.searchText(text: 'cat');
      expect([for (final h in cat) h.id], ['b', 'a']);
      expect(cat.first.relevanceScore, greaterThan(cat[1].relevanceScore));
      expect(cat.first.relevanceScore, greaterThan(0));
      expect(cat.first.content, 'cat cat cat: a story about a cat');

      expect(await _ids(index, 'cat dog'), unorderedEquals(['a', 'b', 'c']));
    });

    test('punctuation splits words', () async {
      final index = await _open(_tempLocation('qt_punct'));
      await _add(index, 'a', 'hello, world');
      expect(await _ids(index, 'hello'), ['a']);
      expect(await _ids(index, 'world'), ['a']);
    });

    test('equal scores are ordered by id', () async {
      final index = await _open(_tempLocation('qt_ties'));
      final ids = ['d3', 'a1', 'f6', 'b2', 'e5', 'c4'];
      for (final id in ids) {
        await _add(index, id, 'same words');
      }
      expect(await _ids(index, 'same'), [...ids]..sort());
      // Tied at the topK cut: the members are picked by id too, as in sqlite.
      expect(await _ids(index, 'same', topK: 3), ([...ids]..sort()).take(3));
    });

    test('topK caps the result', () async {
      final index = await _open(_tempLocation('qt_topk'));
      for (var i = 0; i < 5; i++) {
        await _add(index, 'd$i', 'apple number $i');
      }
      expect(await _ids(index, 'apple', topK: 2), hasLength(2));
    });

    test('ignores case and diacritics', () async {
      final index = await _open(_tempLocation('qt_diacritics'));
      await _add(index, 'a', 'Un Café à Paris');
      await _add(index, 'b', 'Привет, Мир');
      expect(await _ids(index, 'cafe'), ['a']);
      expect(await _ids(index, 'CAFÉ'), ['a']);
      expect(await _ids(index, 'мир'), ['b']);
    });

    test('text is plain words, never a query syntax', () async {
      final index = await _open(_tempLocation('qt_syntax'));
      await _add(index, 'a', 'alpha NEAR beta');
      await _add(index, 'b', 'say "hello"');
      for (final text in [
        '"',
        '"a""b"',
        '...',
        '*',
        'alpha*',
        'NEAR(alpha beta)',
        '-alpha',
        'content:alpha',
        'alpha OR',
        '(',
      ]) {
        await expectLater(
          index.searchText(text: text),
          completes,
          reason: 'query "$text" must not fail',
        );
      }
      expect(await _ids(index, '...'), isEmpty);
      expect(await _ids(index, '"hello"'), ['b']);
      expect(await _ids(index, 'NEAR'), ['a']);
    });

    test('content and metadata match searchSimilar', () async {
      final index = await _open(_tempLocation('qt_payload'));
      await _add(index, 'a', 'kept as written', metadata: {'lang': 'en'});
      final text = (await index.searchText(text: 'written')).single;
      final vector = (await index.searchVector(embedding: _axis(0))).single;
      expect(text.id, vector.id);
      expect(text.content, vector.content);
      expect(text.metadata, vector.metadata);
    });
  });

  group('filters on the text leg', () {
    Future<RagIndex> seeded(String name) async {
      final index = await _open(_tempLocation(name));
      await _add(
        index,
        'en20',
        'report',
        metadata: {'lang': 'en', 'year': 2020},
      );
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
        metadata: {'lang': 'de', 'year': 2024, 'draft': false},
      );
      await _add(index, 'none', 'report');
      return index;
    }

    test('string, number, bool and absent fields', () async {
      final index = await seeded('qt_filter');
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
          filter: Filter(must: [FieldEquals(key: 'draft', value: false)]),
        ),
        ['de24'],
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
    });

    test('the same filter selects the same documents in both legs', () async {
      final index = await seeded('qt_filter_legs');
      final filter = Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
      );
      final vector = await index.searchVector(
        embedding: _axis(0),
        topK: 10,
        filter: filter,
      );
      expect(
        await _ids(index, 'report', filter: filter),
        unorderedEquals([for (final h in vector) h.id]),
      );
    });
  });

  test('writes keep the text index in step', () async {
    final index = await _open(_tempLocation('qt_writes'));
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
  });

  group('lifecycle', () {
    test('a location without a text index refuses searchText', () async {
      final index = await _open(
        _tempLocation('qt_none'),
        enableTextSearch: false,
      );
      await _add(index, 'a', 'words');
      await expectLater(
        index.searchText(text: 'words'),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty location opened without the flag refuses it too', () async {
      final index = await _open(
        _tempLocation('qt_none_empty'),
        enableTextSearch: false,
      );
      await expectLater(
        index.searchText(text: 'words'),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty location opened with the flag has no hits yet', () async {
      final index = await _open(_tempLocation('qt_empty'));
      expect(await _ids(index, 'words'), isEmpty);
      await _add(index, 'a', 'first words');
      expect(await _ids(index, 'words'), ['a']);
    });

    test('enabling text search on an existing store backfills it', () async {
      final path = _tempLocation('qt_backfill');
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
    });

    test('an open without the flag keeps an existing index in step', () async {
      final path = _tempLocation('qt_noflag');
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
    });

    test('concurrent first writes all land in the text index', () async {
      final index = await _open(_tempLocation('qt_concurrent'));
      await Future.wait([
        for (var i = 0; i < 8; i++) _add(index, 'd$i', 'parallel doc $i'),
      ]);
      expect(await _ids(index, 'parallel'), hasLength(8));
    });
  });

  group('hybrid', () {
    test('fuses both legs with RRF', () async {
      final index = await _open(_tempLocation('qt_hybrid'));
      await _add(index, 'both', 'solar panel efficiency', axis: 0);
      await _add(index, 'vector', 'unrelated words', axis: 1);
      await _add(index, 'text', 'solar storms', axis: 3);
      await _add(index, 'neither', 'gardening tips', axis: 2);

      final hits = await index.searchHybridVector(
        text: 'solar',
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
      expect(hits, hasLength(3));
    });

    test('needs a text index', () async {
      final index = await _open(
        _tempLocation('qt_hybrid_none'),
        enableTextSearch: false,
      );
      await _add(index, 'a', 'x');
      await expectLater(
        index.searchHybridVector(text: 'x', embedding: _axis(0)),
        throwsA(isA<StateError>()),
      );
    });
  });
}
