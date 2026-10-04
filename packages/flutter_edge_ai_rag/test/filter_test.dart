import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Filter.isEmpty', () {
    test('default constructor is empty', () {
      expect(const Filter().isEmpty, isTrue);
    });

    test('explicit empty lists are empty', () {
      expect(const Filter(must: [], should: [], mustNot: []).isEmpty, isTrue);
    });

    test('any non-empty bucket flips isEmpty to false', () {
      expect(
        const Filter(must: [FieldEquals(key: 'k', value: 1)]).isEmpty,
        isFalse,
      );
      expect(
        const Filter(should: [FieldEquals(key: 'k', value: 1)]).isEmpty,
        isFalse,
      );
      expect(
        const Filter(mustNot: [FieldEquals(key: 'k', value: 1)]).isEmpty,
        isFalse,
      );
    });
  });

  group('FilterSchema backend-independent validation', () {
    test('an empty name is caught by the constructor assert in debug', () {
      expect(
        () => FilterField(name: '', type: FilterFieldType.string),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a whitespace-only field name', () {
      expect(
        () => FilterField.validateSchema(
          const FilterSchema(
            fields: [FilterField(name: ' ', type: FilterFieldType.string)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a duplicate field name', () {
      expect(
        () => FilterField.validateSchema(
          const FilterSchema(
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
          const FilterSchema(
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
}
