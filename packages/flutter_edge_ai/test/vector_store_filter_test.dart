import 'package:flutter_edge_ai/core/services/vector_store_filter.dart';
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

  // The name is interpolated bare into sqlite-vec's `vec0(...)` DDL, whose
  // grammar accepts an identifier as `[A-Za-z][A-Za-z0-9_]*` and offers no
  // quoted form to escape into. Measured against vec0 0.1.9:
  //   * `doc-type TEXT` -> `vec0 constructor error: Could not parse
  //     'doc-type TEXT'`, and `"doc-type"` / `[doc-type]` / backticks all fail
  //     the same way;
  //   * `a TEXT, b TEXT` (what `FilterField(name: 'a TEXT, b')` renders)
  //     succeeds and silently declares TWO columns.
  // So the name is validated where each store calls validateName from
  // configure() — NOT at the FilterField(…) declaration, which is a const
  // constructor and can only assert. These must be rejected in release builds
  // too, hence a real throw rather than an assert.
  group('FilterSchema validation that holds on every backend', () {
    // Only what is wrong regardless of storage lives here. The vec0 grammar
    // and its reserved words moved to rag_sqlite, and qdrant's dot rule to
    // rag_qdrant — core has no backends, and holding one backend's identifier
    // grammar here would grow it with every backend added.
    test('an empty name is caught by the constructor assert in debug', () {
      // It cannot be driven through validateSchema here: the assert is on a
      // const constructor, so `const FilterField(name: '')` fails at COMPILE
      // time and a non-const one throws before the schema is built. So this
      // pins the dev-time half; the validateSchema branch is the release half
      // and is not reachable under a runner that always enables asserts.
      expect(
        () => FilterField(name: '', type: FilterFieldType.string),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a duplicate field name', () {
      // Meaningless everywhere (fieldFor returns the first match) and not
      // harmless: the two sqlite arms built different column lists for one
      // document, native keeping duplicates and web collapsing them.
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

    test('accepts a name core has no business rejecting', () {
      // `doc-type` is illegal on vec0 and perfectly fine on qdrant. Core must
      // not decide that: the store that cannot take it says so, at configure().
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
