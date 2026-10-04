// Pure-Dart unit tests for the vec0 filter translator. No sqlite, no FFI —
// these assert the SQL fragment + bind list shapes only.
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_test/flutter_test.dart';

/// Schema with one column of each storage type, plus the columns the tests
/// reference. Any key NOT here is undeclared and must be skipped.
final _schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'price', type: FilterFieldType.number),
    FilterField(name: 'archived', type: FilterFieldType.bool),
    FilterField(name: 'year', type: FilterFieldType.number),
    FilterField(name: 'category', type: FilterFieldType.string),
  ],
);

void main() {
  group('empty / no-op', () {
    test('null filter → empty whereSql + empty binds', () {
      final out = FilterToVec0.translate(null, _schema);
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });

    test('Filter() with no buckets → empty', () {
      final out = FilterToVec0.translate(const Filter(), _schema);
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });

    test('empty bucket lists → empty', () {
      final out = FilterToVec0.translate(
        const Filter(must: [], should: [], mustNot: []),
        _schema,
      );
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });

    test('undeclared key only → empty (skipped, never throws)', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [FieldEquals(key: 'unknown', value: 'x')],
        ),
        _schema,
      );
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });

    test('empty schema skips every declared key', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [FieldEquals(key: 'lang', value: 'en')],
        ),
        const FilterSchema(),
      );
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });
  });

  group('FieldEquals', () {
    test('string', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [FieldEquals(key: 'lang', value: 'en')],
        ),
        _schema,
      );
      expect(out.whereSql, '"lang" = ?');
      expect(out.binds, ['en']);
    });

    test('number binds as double (vec0 FLOAT column rejects an int)', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldEquals(key: 'price', value: 42)]),
        _schema,
      );
      expect(out.whereSql, '"price" = ?');
      expect(out.binds, [42.0]);
    });

    test('bool true binds as 1', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldEquals(key: 'archived', value: true)]),
        _schema,
      );
      expect(out.whereSql, '"archived" = ?');
      expect(out.binds, [1]);
    });

    test('bool false binds as 0', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldEquals(key: 'archived', value: false)]),
        _schema,
      );
      expect(out.whereSql, '"archived" = ?');
      expect(out.binds, [0]);
    });
  });

  group('FieldRange', () {
    test('two-sided → BETWEEN', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldRange(key: 'price', gte: 10.0, lte: 100.0)]),
        _schema,
      );
      expect(out.whereSql, '"price" BETWEEN ? AND ?');
      expect(out.binds, [10.0, 100.0]);
    });

    test('lower bound only → >=', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldRange(key: 'price', gte: 10.0)]),
        _schema,
      );
      expect(out.whereSql, '"price" >= ?');
      expect(out.binds, [10.0]);
    });

    test('upper bound only → <=', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldRange(key: 'price', lte: 100.0)]),
        _schema,
      );
      // The second conjunct excludes the absent-number sentinel: -Infinity is
      // <= every bound, so without it a document MISSING `price` would satisfy
      // `price <= 100`. The sentinel is a LITERAL, not a bind: it cannot be
      // bound on dart2js, where -Infinity takes the int path. Both
      // comparisons still push — measured, same plan either way.
      expect(out.whereSql, '("price" <= ? AND "price" > -9e999)');
      expect(out.binds, [100.0]);
    });

    test('no bounds → skipped (empty)', () {
      final out = FilterToVec0.translate(
        const Filter(must: [FieldRange(key: 'price')]),
        _schema,
      );
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });

    test('range over a non-numeric (TEXT) field → skipped (no-op)', () {
      // `lang` is declared as a string column; a range over it would silently
      // mis-filter, so it is treated as unsupported and skipped.
      final out = FilterToVec0.translate(
        const Filter(must: [FieldRange(key: 'lang', gte: 1.0)]),
        _schema,
      );
      expect(out.whereSql, '');
      expect(out.binds, isEmpty);
    });
  });

  group('FieldMatchAny', () {
    test('multiple values → IN list', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldMatchAny(key: 'lang', values: ['en', 'fr', 'de']),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '"lang" IN (?, ?, ?)');
      expect(out.binds, ['en', 'fr', 'de']);
    });

    test('single value → IN with one placeholder', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldMatchAny(key: 'lang', values: ['en']),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '"lang" = ?');
      expect(out.binds, ['en']);
    });

    test('bool values bind as 0/1', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldMatchAny(key: 'archived', values: [true, false]),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '"archived" IN (?, ?)');
      expect(out.binds, [1, 0]);
    });

    test('empty values → match-nothing literal, no binds', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [FieldMatchAny(key: 'lang', values: [])],
        ),
        _schema,
      );
      expect(out.whereSql, '0');
      expect(out.binds, isEmpty);
    });
  });

  group('buckets', () {
    test('must → AND-joined', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'price', gte: 10.0, lte: 100.0),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '"lang" = ? AND "price" BETWEEN ? AND ?');
      expect(out.binds, ['en', 10.0, 100.0]);
    });

    test('should → OR-joined inside a parenthesised group', () {
      final out = FilterToVec0.translate(
        const Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldEquals(key: 'lang', value: 'fr'),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '("lang" IN (?, ?))');
      expect(out.binds, ['en', 'fr']);
    });

    test('mustNot → NOT (...)', () {
      final out = FilterToVec0.translate(
        const Filter(mustNot: [FieldEquals(key: 'archived', value: true)]),
        _schema,
      );
      expect(out.whereSql, '"archived" != ?');
      expect(out.binds, [1]);
    });

    test(
      'mustNot with multiple → OR-joined inside NOT (exclude if ANY match)',
      () {
        final out = FilterToVec0.translate(
          const Filter(
            mustNot: [
              FieldEquals(key: 'lang', value: 'en'),
              FieldEquals(key: 'archived', value: true),
            ],
          ),
          _schema,
        );
        // "no condition may match" → NOT (A OR B), so a row matching either is
        // excluded (De Morgan: NOT A AND NOT B).
        expect(out.whereSql, '"lang" != ? AND "archived" != ?');
        expect(out.binds, ['en', 1]);
      },
    );

    test('must + should + mustNot combine, AND-joined, binds in order', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [FieldEquals(key: 'lang', value: 'en')],
          should: [
            FieldEquals(key: 'category', value: 'news'),
            FieldEquals(key: 'category', value: 'blog'),
          ],
          mustNot: [FieldEquals(key: 'archived', value: true)],
        ),
        _schema,
      );
      expect(
        out.whereSql,
        '"lang" = ? AND ("category" IN (?, ?)) AND "archived" != ?',
      );
      expect(out.binds, ['en', 'news', 'blog', 1]);
    });

    test('undeclared keys skipped within a populated bucket', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldEquals(key: 'unknown', value: 'x'),
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'also_unknown', gte: 1.0),
          ],
        ),
        _schema,
      );
      expect(out.whereSql, '"lang" = ?');
      expect(out.binds, ['en']);
    });

    test('mixed condition types across buckets bind in SQL order', () {
      final out = FilterToVec0.translate(
        const Filter(
          must: [
            FieldMatchAny(key: 'lang', values: ['en', 'fr']),
            FieldRange(key: 'year', gte: 2000.0),
          ],
          mustNot: [FieldRange(key: 'price', lte: 5.0)],
        ),
        _schema,
      );
      expect(
        out.whereSql,
        '"lang" IN (?, ?) AND "year" >= ? AND "price" NOT BETWEEN -1.7976931348623157e308 AND ?',
      );
      expect(out.binds, ['en', 'fr', 2000.0, 5.0]);
    });
  });
}
