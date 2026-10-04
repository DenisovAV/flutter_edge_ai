// Set membership over a NUMBER-typed field must run, and must reach the KNN
// scan — it used to do neither.
//
// `FieldMatchAny` on a `FilterFieldType.number` field renders onto a vec0
// FLOAT column, and vec0 refuses `IN` on FLOAT/BOOLEAN kinds outright:
// `'xxx in (...)' is only available on INTEGER or TEXT metadata columns.`,
// raised out of sqlite3_prepare. So the filter did not narrow the search, it
// THREW — against a core contract that says an unmatched filter "simply
// matches nothing" and never errors.
//
// The trap underneath it is worse: SQLite folds `year = ? OR year = ?` into
// `year IN (?, ?)` on its own, for bound parameters as well as literals. A
// `should` bucket of plain `FieldEquals` on one number field therefore hit the
// same refusal without anyone writing `FieldMatchAny` at all.
//
// Both are asserted here on ROWS from a real vec0 table. The corpus is built so
// that the nearest rows do NOT match: a filter that vec0 never sees returns
// them and lets SQLite discard them afterwards, which yields fewer than k rows
// (usually zero) while reading as a filtered search. Only a filter pushed into
// the scan can reach past them.
import 'dart:ffi';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  final skip = vec0SkipReason;

  group('set membership on a number column', () {
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
          year FLOAT,
          lang TEXT,
          archived INTEGER
        )
      ''');
      // n1/n2 are the two NEAREST to [1,0,0,0] and match none of the sets the
      // tests ask for, so a post-filter over a global top-k cannot reach the
      // rows that do match.
      db.execute('''
        INSERT INTO v(id, embedding, year, lang, archived) VALUES
          ('n1', '[1,0,0,0]',      1998.0, 'de', 0),
          ('n2', '[0.9,0.1,0,0]',  1999.0, 'de', 0),
          -- Distances must be DISTINCT, or a k=2 assertion is not determined
          -- by the data: with d1/d2/d3 all at first-component 0 they were
          -- equidistant from the [1,0,0,0] probe, three rows matched
          -- lang IN ('en','fr'), and any two could come back. Give each a
          -- different first component so the ordering d1 > d2 > d3 is real.
          ('d1', '[0.5,0.86,0,0]', 2022.0, 'en', 1),
          ('d2', '[0.4,0.92,0,0]', 2021.0, 'fr', 1),
          ('d3', '[0.3,0.95,0,0]', 2020.0, 'en', 0)
      ''');
    });

    tearDown(() => db.close());

    final schema = FilterSchema(
      fields: [
        FilterField(name: 'year', type: FilterFieldType.number),
        FilterField(name: 'lang', type: FilterFieldType.string),
        FilterField(name: 'archived', type: FilterFieldType.bool),
      ],
    );

    List<String> search(Filter filter, {int k = 2}) {
      final t = FilterToVec0.translate(filter, schema);
      final sql =
          'SELECT id FROM v WHERE embedding MATCH ? AND k = ?'
          '${t.whereSql.isEmpty ? '' : ' AND ${t.whereSql}'}';
      final rows = db.select(sql, ['[1,0,0,0]', k, ...t.binds]);
      return rows.map((r) => r['id'] as String).toList();
    }

    test('FieldMatchAny on a number field runs at all', () {
      // The regression: this threw out of prepare with
      // `'xxx in (...)' is only available on INTEGER or TEXT metadata columns.`
      final got = search(
        Filter(
          must: [
            FieldMatchAny(key: 'year', values: [2021, 2022]),
          ],
        ),
      );
      // …and it is pushed: the two nearest rows are 1998/1999, so a filter
      // evaluated after the scan would have returned nothing.
      expect(got, unorderedEquals(['d1', 'd2']));
    });

    test('int and double members mean the same set', () {
      // `2021` and `2021.0` are the same FLOAT column value; the codec doubles
      // both, so the caller's Dart literal type cannot change the result.
      final ints = search(
        Filter(
          must: [
            FieldMatchAny(key: 'year', values: [2021, 2022]),
          ],
        ),
      );
      final doubles = search(
        Filter(
          must: [
            FieldMatchAny(key: 'year', values: [2021.0, 2022.0]),
          ],
        ),
      );
      expect(ints, unorderedEquals(doubles));
    });

    test('a should bucket of FieldEquals on one number field runs', () {
      // Nobody wrote `IN` here. SQLite's OR-to-IN rewrite did, and vec0 threw.
      final got = search(
        Filter(
          should: [
            FieldEquals(key: 'year', value: 2021),
            FieldEquals(key: 'year', value: 2022),
          ],
        ),
      );
      expect(got, unorderedEquals(['d1', 'd2']));
    });

    test('a should bucket mixing FieldEquals and FieldMatchAny runs', () {
      // Fusing has to cover this too: a one-member FieldMatchAny renders as
      // `=`, so `year = ? OR year = ?` would re-form and fold to IN again.
      final got = search(
        Filter(
          should: [
            FieldEquals(key: 'year', value: 2021),
            FieldMatchAny(key: 'year', values: [2022]),
          ],
        ),
      );
      expect(got, unorderedEquals(['d1', 'd2']));
    });

    test('a should bucket across two different fields still runs', () {
      // Mixed columns are not folded, so this never hit the FLOAT `IN` refusal
      // — assert it stays that way, and that the SQL selects the right rows.
      //
      // k=5, not the default 2, and that is the whole point of the number:
      // a cross-column OR is not pushable into vec0's KNN, so SQLite evaluates
      // it AFTER vec0 has picked k rows. At k=2 the two nearest (n1, n2) match
      // neither condition and the answer is empty — correct SQL, unreachable
      // rows. Reaching past them is the STORE's job (SqliteVectorStore
      // over-fetches up to 16x for exactly this shape); this file tests the
      // translator, so it asks for a window wide enough that the post-filter
      // can see the matches.
      final got = search(
        Filter(
          should: [
            FieldEquals(key: 'year', value: 2020),
            FieldEquals(key: 'lang', value: 'fr'),
          ],
        ),
        k: 5,
      );
      expect(got, unorderedEquals(['d2', 'd3']));
    });

    test('a single-member set is pushed, not post-filtered', () {
      final got = search(
        Filter(
          must: [
            FieldMatchAny(key: 'year', values: [2020]),
          ],
        ),
        k: 1,
      );
      expect(got, ['d3']);
    });

    test('a non-contiguous set never returns a non-member', () {
      // {2020, 2022} spans 2021, which the pushed envelope cannot exclude — the
      // `CASE` drops d2 afterwards. Recall suffers (this is the documented
      // cost: fewer than k rows), but a wrong row must never come back.
      final got = search(
        Filter(
          must: [
            FieldMatchAny(key: 'year', values: [2020, 2022]),
          ],
        ),
        k: 3,
      );
      expect(got, isNotEmpty);
      expect(got, everyElement(isIn(['d1', 'd3'])));
    });

    test('an empty set matches nothing instead of throwing', () {
      expect(
        search(
          Filter(
            must: [FieldMatchAny(key: 'year', values: [])],
          ),
        ),
        isEmpty,
      );
    });

    test('a set of values no row could hold matches nothing', () {
      // A String is unstorable in a FLOAT column, so it can equal no stored
      // value. That is "matches nothing", not an error and not a NULL bind.
      expect(
        search(
          Filter(
            must: [
              FieldMatchAny(key: 'year', values: ['not a year']),
            ],
          ),
        ),
        isEmpty,
      );
    });

    test('mustNot over a number set is pushed', () {
      // The negated side needs no rewrite — a conjunction of `!=` is exactly
      // what vec0 pushes. Excluding the two nearest must still yield k rows.
      final got = search(
        Filter(
          mustNot: [
            FieldMatchAny(key: 'year', values: [1998, 1999]),
          ],
        ),
      );
      expect(got, unorderedEquals(['d1', 'd2']));
    });

    test('mustNot ignores a value no row could hold', () {
      // Excluding something unstorable excludes nothing, so the nearest rows
      // come back. Binding NULL into the pushed `!=` would have excluded
      // everything instead.
      final got = search(
        Filter(
          mustNot: [
            FieldMatchAny(key: 'year', values: ['not a year']),
          ],
        ),
      );
      expect(got, unorderedEquals(['n1', 'n2']));
    });

    test('string and bool columns still take IN, and it is pushed', () {
      // TEXT and INTEGER kinds do accept `IN` — the FLOAT rewrite must not have
      // cost them their pushdown.
      expect(
        search(
          Filter(
            must: [
              FieldMatchAny(key: 'lang', values: ['en', 'fr']),
            ],
          ),
        ),
        unorderedEquals(['d1', 'd2']),
      );
      expect(
        search(
          Filter(
            must: [
              FieldMatchAny(key: 'archived', values: [true]),
            ],
          ),
        ),
        unorderedEquals(['d1', 'd2']),
      );
    });

    test('a should bucket of FieldEquals on a string field is pushed', () {
      final got = search(
        Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldEquals(key: 'lang', value: 'fr'),
          ],
        ),
      );
      expect(got, unorderedEquals(['d1', 'd2']));
    });
  }, skip: skip);
}
