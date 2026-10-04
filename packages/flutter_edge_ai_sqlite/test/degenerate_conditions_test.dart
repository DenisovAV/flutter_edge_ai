// A condition that "does nothing" still has to do the right nothing.
//
// The translator used to answer a single `null` for two opposite situations:
// "this constrains nothing" and "this can never match". In a `must` bucket
// both can be dropped, which is why the collapse survived. In a `should` (OR)
// they are opposites — dropping a condition that matches everything removes
// the very thing that made the disjunction true — and in `mustNot` they swap
// places again.
//
// Asserted on ROWS from a real vec0 table: the SQL for "ignored" and for
// "always true" is the same empty string, so a string assertion cannot tell
// these cases apart at all.
import 'dart:ffi';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  final skip = vec0SkipReason;

  group('degenerate conditions keep their bucket\'s meaning', () {
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
          lang TEXT,
          year FLOAT
        )
      ''');
      db.execute('''
        INSERT INTO v(id, embedding, lang, year) VALUES
          ('d1', '[1,0,0,0]',     'en', 2020.0),
          ('d2', '[0.9,0.1,0,0]', 'fr', 2021.0),
          ('d3', '[0,1,0,0]',     'de', 2019.0),
          ('d4', '[0,0.9,0.1,0]', 'es', 2018.0)
      ''');
    });

    tearDown(() => db.dispose());

    final schema = FilterSchema(
      fields: [
        FilterField(name: 'lang', type: FilterFieldType.string),
        FilterField(name: 'year', type: FilterFieldType.number),
      ],
    );

    List<String> search(Filter filter, {int k = 4}) {
      final t = FilterToVec0.translate(filter, schema);
      if (t.matchesNothing) return const [];
      final sql =
          'SELECT id FROM v WHERE embedding MATCH ? AND k = ?'
          '${t.whereSql.isEmpty ? '' : ' AND ${t.whereSql}'}';
      return db
          .select(sql, ['[1,0,0,0]', k, ...t.binds])
          .map((r) => r['id'] as String)
          .toList();
    }

    test('an always-true arm makes the whole should bucket true', () {
      // `lang = 'en' OR <every document>` is true of every document. Dropping
      // just the unbounded range left `lang = 'en'`, so a condition meant to
      // constrain nothing narrowed the result from four rows to one.
      final got = search(
        const Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'year'),
          ],
        ),
      );
      expect(got, hasLength(4), reason: 'the disjunction is true of all');
    });

    test('an always-true condition in mustNot excludes everything', () {
      // "no condition may match" over a condition every document satisfies.
      expect(search(const Filter(mustNot: [FieldRange(key: 'year')])), isEmpty);
    });

    test('a should bucket whose every arm matches nothing returns nothing', () {
      expect(
        search(
          const Filter(
            should: [FieldMatchAny(key: 'lang', values: [])],
          ),
        ),
        isEmpty,
      );
    });

    test('a should bucket of ONLY ignored arms constrains nothing', () {
      // The sibling of the qdrant bug, and the same root: the code asked
      // whether any arm was DECLARED, and an ignored arm is declared. With no
      // surviving arm to mask it, the bucket read as an empty disjunction and
      // returned nothing. The existing test above has a surviving arm, which
      // is exactly why it never caught this.
      expect(
        search(const Filter(should: [FieldRange(key: 'lang', gte: 1)])),
        hasLength(4),
      );
      // And the identical condition in `must` must agree.
      expect(
        search(const Filter(must: [FieldRange(key: 'lang', gte: 1)])),
        hasLength(4),
      );
    });

    test('an ignored condition is skipped in should, not treated as true', () {
      // An undeclared key is ignored as if never written — a contract choice,
      // not a truth value — so the remaining arm still constrains.
      final got = search(
        const Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldEquals(key: 'undeclared', value: 'x'),
          ],
        ),
      );
      expect(got, ['d1']);
    });

    test('a range on a TEXT field is ignored, in should too', () {
      final got = search(
        const Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'lang', gte: 1),
          ],
        ),
      );
      expect(got, ['d1']);
    });

    test('FieldRange rejects a non-finite bound at construction', () {
      // The first version of this test tried to push `gte: -double.infinity`
      // through translate() to exercise the release-mode guard. It cannot:
      // FieldRange asserts finite bounds in its constructor, and `flutter
      // test` always runs with asserts on, so the value never reaches the
      // translator. The comment claiming otherwise was simply wrong.
      //
      // So this pins the dev-time half. The release half — _isFiniteBound in
      // filter_to_vec0.dart, which stops -Infinity (the absent-value
      // sentinel) from being bound as a range bound once the assert is gone —
      // is NOT covered by a test, and cannot be under this runner. Saying so
      // is better than a test that looks like it covers it.
      expect(
        () => FieldRange(key: 'year', gte: double.negativeInfinity),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a non-finite equality matches nothing, not the absent sentinel', () {
      // -Infinity IS the absent-number sentinel, so this used to return every
      // document that has no `year` — the opposite of a filter on year. Here
      // every row HAS a year, so the correct answer is no rows either way;
      // the row inserted below is the one that made the old behaviour visible.
      // -9e999 is how SQLite spells -Infinity as a literal; Dart's
      // "-Infinity" is not valid SQL. This row stands in for a document that
      // was inserted WITHOUT a year — the store writes the same sentinel.
      db.execute(
        "INSERT INTO v(id, embedding, lang, year) VALUES "
        "('absent', '[0.8,0.2,0,0]', 'en', -9e999)",
      );
      expect(
        search(
          Filter(
            must: [FieldEquals(key: 'year', value: double.negativeInfinity)],
          ),
        ),
        isEmpty,
      );
    });
  }, skip: skip);
}
