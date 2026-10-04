// vec0's identifier rules, tested where they live.
//
// These moved out of core: `k` and `distance` are hidden columns of ONE
// backend, and `^[A-Za-z][A-Za-z0-9_]*$` is that backend's DDL grammar. A
// package with no backends should not carry either, and would have carried one
// set per backend as they were added.
//
// The trade-off is deliberate and visible here: qdrant accepts every name this
// file rejects. The portable set is vec0's, and core's FilterField dartdoc says
// so; the sqlite store enforces it at configure(), naming itself.
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FilterToVec0.validateFieldName', () {
    test('accepts a bare vec0 identifier', () {
      for (final name in ['lang', 'docType', 'doc_type', 'a1', 'x', 'order']) {
        expect(
          () => FilterToVec0.validateFieldName(name),
          returnsNormally,
          reason: '$name is a legal bare vec0 identifier',
        );
      }
    });

    test('rejects what cannot lead an identifier', () {
      for (final name in ['1lang', '_lang', '', ' lang', 'länge']) {
        expect(() => FilterToVec0.validateFieldName(name), throwsArgumentError);
      }
    });

    test('rejects a hyphen — the measured vec0 DDL parse failure', () {
      expect(
        () => FilterToVec0.validateFieldName('doc-type'),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.invalidValue, 'invalidValue', 'doc-type')
              .having((e) => e.name, 'name', 'FilterField.name'),
        ),
      );
    });

    test('rejects a comma — the measured silent two-column declaration', () {
      // Worse than an error: the DDL renders '$name $type', so this used to
      // declare TWO columns and the schema stopped describing the table.
      expect(
        () => FilterToVec0.validateFieldName('a TEXT, b'),
        throwsArgumentError,
      );
    });

    test('rejects the names vec0 declares for itself', () {
      // Five are visible in the store's CREATE statement; `distance` and `k`
      // are HIDDEN columns vec0 appends to every table, so reading that
      // statement does not find them — which is how `k` was missed at first.
      for (final name in FilterToVec0.reservedNames) {
        expect(
          () => FilterToVec0.validateFieldName(name),
          throwsArgumentError,
          reason: '"$name" collides with a vec0 column',
        );
      }
      expect(FilterToVec0.reservedNames, containsAll(['distance', 'k']));
      // Measured at the same time and ACCEPTED, so deliberately not listed —
      // a reserved list that over-reaches costs users names for no reason.
      expect(FilterToVec0.reservedNames, isNot(contains('rowid')));
      expect(() => FilterToVec0.validateFieldName('rowid'), returnsNormally);
    });

    test('the store rejects such a schema at configure(), not at insert', () {
      // The whole point of validating early: the vec0 table is created lazily
      // on the first addDocument, so without this the failure surfaced much
      // later and pointed at an insert.
      final store = SqliteVectorStore();
      expect(
        () => store.configure(
          const FilterSchema(
            fields: [
              FilterField(name: 'content', type: FilterFieldType.string),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
