// Filters: sqlite's cross-backend parity table through the store, the
// degenerate conditions, and the translation's shape.
import 'dart:io';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/filter_mongo.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/parity_cases.dart' as parity;

void main() {
  test('the parity table is the sqlite one', () {
    final original = File(
      '../flutter_edge_ai_sqlite/lib/src/testing/parity_cases.dart',
    );
    if (!original.existsSync()) return;
    String body(String s) => s.substring(s.indexOf('library;'));
    expect(
      body(File('test/support/parity_cases.dart').readAsStringSync()),
      body(original.readAsStringSync()),
    );
    expect(parity.cases, hasLength(20));
  });

  test('every refused parity case names a case in the table', () {
    final names = {for (final c in parity.cases) c.name};
    expect(parity.removeWhereRefused, isNotEmpty);
    for (final name in parity.removeWhereRefused) {
      expect(names, contains(name));
    }
  });

  group('parity table through the store', () {
    late World w;
    // The store itself, as sqlite's suite does: RagIndex refuses an
    // undeclared field before the store could ignore it.
    late VectorStoreRepository store;
    setUpAll(() async {
      w = World();
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'parity');
      store = await AnyVectorStoreProvider(a).createStore(specOf(loc));
      store.configure(parity.schema);
      await store.initialize(loc.value);
      await store.bind(
        VectorStoreBinding(
          profile: EmbeddingProfile(id: 'parity-v1', dimension: 4),
        ),
      );
      for (final d in parity.docs) {
        await store.addDocument(
          id: d.id,
          embedding: parity.embedding,
          content: d.id,
          metadata: d.metadata,
        );
      }
    });
    tearDownAll(() async {
      await store.close();
      await w.dispose();
    });

    for (final c in parity.cases) {
      test(c.name, () async {
        final hits = await store.searchSimilar(
          queryEmbedding: parity.embedding,
          topK: parity.docs.length,
          filter: c.filter,
        );
        expect(hits.map((h) => h.id).toList()..sort(), [...c.expected]..sort());
      });
    }
  });

  group('translation', () {
    final schema = FilterSchema(
      fields: [
        FilterField(name: 'lang', type: FilterFieldType.string),
        FilterField(name: 'year', type: FilterFieldType.number),
        FilterField(name: 'ok', type: FilterFieldType.bool),
      ],
    );
    String key(String n, String t) =>
        'f.${fieldKeyOf(FilterField(name: n, type: FilterFieldType.values.byName(t)))}';

    test('no filter, and only ignored conditions, constrain nothing', () {
      expect(translateFilter(null, schema), (
        query: null,
        matchesNothing: false,
      ));
      final t = translateFilter(
        Filter(
          must: [FieldEquals(key: 'nope', value: 1)],
          should: [FieldRange(key: 'lang', gte: 1)],
        ),
        schema,
      );
      expect(t.query, isNull);
      expect(t.matchesNothing, isFalse);
    });

    test('field paths are hashed: a dotted name stays one path segment', () {
      final s = FilterSchema(
        fields: [FilterField(name: 'a.b', type: FilterFieldType.string)],
      );
      final t = translateFilter(
        Filter(
          must: [FieldEquals(key: 'a.b', value: 'x')],
        ),
        s,
      );
      final path = t.query!.keys.single;
      expect(path.split('.'), hasLength(2));
      expect(path.split('.')[1], matches(RegExp(r'^[0-9a-f]{64}-string$')));
    });

    test('mustNot is \$nor, should is \$or, buckets are \$and', () {
      final t = translateFilter(
        Filter(
          must: [FieldEquals(key: 'ok', value: 1)],
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'year', lte: 2000),
          ],
          mustNot: [
            FieldMatchAny(key: 'lang', values: ['de']),
          ],
        ),
        schema,
      );
      expect(t.query, {
        r'$and': [
          {
            key('ok', 'bool'): {r'$eq': true},
          },
          {
            r'$or': [
              {
                key('lang', 'string'): {r'$eq': 'en'},
              },
              {
                key('year', 'number'): {r'$lte': 2000.0},
              },
            ],
          },
          {
            r'$nor': [
              {
                key('lang', 'string'): {
                  r'$in': ['de'],
                },
              },
            ],
          },
        ],
      });
    });

    test('degenerate: an always-true mustNot or an all-false should match '
        'nothing', () {
      expect(
        translateFilter(
          Filter(mustNot: [FieldRange(key: 'year')]),
          schema,
        ).matchesNothing,
        isTrue,
      );
      expect(
        translateFilter(
          Filter(
            should: [FieldMatchAny(key: 'lang', values: [])],
          ),
          schema,
        ).matchesNothing,
        isTrue,
      );
    });

    test('normalised fields: present, coercible values only', () {
      final f = normaliseFields('{"lang":"en","year":"x","ok":0}', schema);
      expect(f, {
        fieldKeyOf(schema.fields[0]): 'en',
        fieldKeyOf(schema.fields[2]): false,
      });
      expect(normaliseFields('not json', schema), isEmpty);
    });
  });
}
