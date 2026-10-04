// mustNot must reach the KNN scan, not filter after it.
//
// The existing filter_to_vec0_test.dart is 25 string comparisons on the SQL
// this translator emits. It correctly asserted that `NOT (...)` was produced —
// and vec0 then refused to push it, returning the k nearest rows UNFILTERED
// for SQLite to discard afterwards. A post-filter over a global top-k silently
// returns fewer than k rows, or none, while reading as a filtered search.
//
// So this file asserts on ROWS, from a real vec0 table. Asserting on generated
// SQL cannot distinguish a filter that runs from one that is thrown away.
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ffi';

import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  final skip = vec0SkipReason;

  group('mustNot is pushed into the KNN scan', () {
    late Database db;

    setUp(() {
      useHostNativeLibraries();
      sqlite3.ensureExtensionLoaded(
        SqliteExtension.inLibrary(
          DynamicLibrary.open(vec0Path!),
          'sqlite3_vec_init',
        ),
      );
      db = sqlite3.openInMemory();
      db.execute('''
        CREATE VIRTUAL TABLE v USING vec0(
          id TEXT PRIMARY KEY,
          embedding float[4] distance_metric=cosine,
          category TEXT
        )
      ''');
      // d1/d2 are the two NEAREST to [1,0,0,0] and both are category 'a'.
      // So any query excluding 'a' with k=2 must reach past them — which is
      // exactly what a post-filter cannot do.
      db.execute('''
        INSERT INTO v(id, embedding, category) VALUES
          ('d1', '[1,0,0,0]',     'a'),
          ('d2', '[0.9,0.1,0,0]', 'a'),
          ('d3', '[0,1,0,0]',     'b'),
          ('d4', '[0,0.9,0.1,0]', 'c')
      ''');
    });

    tearDown(() => db.close());

    List<String> search(Filter filter, FilterSchema schema, {int k = 2}) {
      final t = FilterToVec0.translate(filter, schema);
      final sql =
          'SELECT id FROM v WHERE embedding MATCH ? AND k = ?'
          '${t.whereSql.isEmpty ? '' : ' AND ${t.whereSql}'}';
      final rows = db.select(sql, ['[1,0,0,0]', k, ...t.binds]);
      return rows.map((r) => r['id'] as String).toList();
    }

    final schema = FilterSchema(
      fields: [FilterField(name: 'category', type: FilterFieldType.string)],
    );

    test('a document missing the field is RETURNED by mustNot', () {
      // The rule this PR wrote into core: a missing key never satisfies a
      // condition, so must excludes such a document and mustNot keeps it —
      // matching qdrant's check_must_not, which is all(|c| !check(c)).
      //
      // Absent fields are stored as a sentinel, so `col != ?` is true of them
      // and this works. The one-sided `lte` negation did NOT: `col > lte` is
      // false of -Infinity, so it silently dropped every document lacking the
      // field. That is why these assert on ROWS.
      db.execute(
        "INSERT INTO v(id, embedding, category) VALUES "
        "('absent', '[0,0.7,0.3,0]', char(0) || '__absent__')",
      );

      final got = search(
        Filter(
          mustNot: [FieldEquals(key: 'category', value: 'a')],
        ),
        schema,
        k: 4,
      );
      expect(got, contains('absent'));
    });

    test('a document missing the field is EXCLUDED by must', () {
      db.execute(
        "INSERT INTO v(id, embedding, category) VALUES "
        "('absent', '[0,0.7,0.3,0]', char(0) || '__absent__')",
      );

      final got = search(
        Filter(
          must: [FieldEquals(key: 'category', value: 'a')],
        ),
        schema,
        k: 4,
      );
      expect(got, isNot(contains('absent')));
    });

    test('excluding the two nearest still returns k rows', () {
      // The regression: `NOT (category = 'a')` returned ZERO rows here, because
      // vec0 handed SQLite d1 and d2 and both were then discarded.
      final got = search(
        Filter(
          mustNot: [FieldEquals(key: 'category', value: 'a')],
        ),
        schema,
      );
      expect(got.length, 2, reason: 'a post-filter would return 0 or 1 here');
      expect(got, isNot(contains('d1')));
      expect(got, isNot(contains('d2')));
    });

    test('excluding several values still returns k rows', () {
      // FieldMatchAny negates to a chain of `!=`, not `NOT IN` — measured,
      // vec0 pushes the former and not the latter.
      final got = search(
        Filter(
          mustNot: [
            FieldMatchAny(key: 'category', values: ['a', 'b']),
          ],
        ),
        schema,
        k: 1,
      );
      expect(got, ['d4']);
    });

    test('two mustNot conditions compose', () {
      final got = search(
        Filter(
          mustNot: [
            FieldEquals(key: 'category', value: 'a'),
            FieldEquals(key: 'category', value: 'b'),
          ],
        ),
        schema,
        k: 1,
      );
      expect(got, ['d4']);
    });

    test('an empty match-any excludes nothing', () {
      // "match none of []" is no constraint, so the nearest rows come back.
      final got = search(
        Filter(
          mustNot: [FieldMatchAny(key: 'category', values: [])],
        ),
        schema,
      );
      expect(got, ['d1', 'd2']);
    });
  }, skip: skip);
}
