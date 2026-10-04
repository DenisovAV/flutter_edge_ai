import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Filter.isEmpty', () {
    test('default constructor is empty', () {
      expect(Filter().isEmpty, isTrue);
    });

    test('explicit empty lists are empty', () {
      expect(Filter(must: [], should: [], mustNot: []).isEmpty, isTrue);
    });

    test('any non-empty bucket flips isEmpty to false', () {
      expect(Filter(must: [FieldEquals(key: 'k', value: 1)]).isEmpty, isFalse);
      expect(
        Filter(should: [FieldEquals(key: 'k', value: 1)]).isEmpty,
        isFalse,
      );
      expect(
        Filter(mustNot: [FieldEquals(key: 'k', value: 1)]).isEmpty,
        isFalse,
      );
    });
  });

  group('FilterSchema backend-independent validation', () {
    test('an empty name is rejected at runtime', () {
      expect(
        () => FilterField(name: '', type: FilterFieldType.string),
        throwsArgumentError,
      );
    });

    test('rejects a whitespace-only field name', () {
      expect(
        () => FilterField.validateSchema(
          FilterSchema(
            fields: [FilterField(name: ' ', type: FilterFieldType.string)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a duplicate field name', () {
      expect(
        () => FilterField.validateSchema(
          FilterSchema(
            fields: [
              FilterField(name: 'lang', type: FilterFieldType.string),
              FilterField(name: 'lang', type: FilterFieldType.string),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('accepts a name whose legality depends on the backend', () {
      expect(
        () => FilterField.validateSchema(
          FilterSchema(
            fields: [
              FilterField(name: 'doc-type', type: FilterFieldType.string),
              FilterField(name: 'year', type: FilterFieldType.number),
            ],
          ),
        ),
        returnsNormally,
      );
    });
  });

  group('filter value validation', () {
    test('rejects empty keys and unsupported or non-finite values', () {
      expect(() => FieldEquals(key: ' ', value: 'value'), throwsArgumentError);
      expect(
        () => FieldEquals(key: 'key', value: Object()),
        throwsArgumentError,
      );
      expect(
        () => FieldEquals(key: 'key', value: double.nan),
        throwsArgumentError,
      );
      expect(
        () => FieldRange(key: 'key', gte: double.infinity),
        throwsArgumentError,
      );
      expect(
        () => FieldMatchAny(key: 'key', values: [Object()]),
        throwsArgumentError,
      );
    });

    test('snapshots caller-owned condition and schema lists', () {
      final conditions = <Condition>[FieldEquals(key: 'key', value: 'a')];
      final filter = Filter(must: conditions);
      conditions.add(FieldEquals(key: 'key', value: 'b'));

      final values = <Object>['a'];
      final matchAny = FieldMatchAny(key: 'key', values: values);
      values.add('b');

      final fields = <FilterField>[
        FilterField(name: 'key', type: FilterFieldType.string),
      ];
      final schema = FilterSchema(fields: fields);
      fields.add(FilterField(name: 'other', type: FilterFieldType.string));

      expect(filter.must, hasLength(1));
      expect(() => filter.must!.add(conditions.last), throwsUnsupportedError);
      expect(matchAny.values, ['a']);
      expect(() => matchAny.values.add('c'), throwsUnsupportedError);
      expect(schema.fields, hasLength(1));
      expect(() => schema.fields.clear(), throwsUnsupportedError);
    });
  });
}
