// qdrant's own name rule, tested where it lives.
//
// It has exactly one, and it is not vec0's: payload keys are free-form UTF-8,
// but `.` is a nested-path separator, so `doc.type` would mean "field `type`
// inside `doc`" here and a flat column elsewhere — one declaration denoting two
// different things.
//
// The asymmetry is deliberate and shown below: this store ACCEPTS names vec0
// refuses. Core does not enforce the intersection, because core has no backends.
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_rag_qdrant/src/filter_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FilterCodec.validateFieldName', () {
    test('rejects a dot — qdrant reads it as a nested payload path', () {
      expect(
        () => FilterCodec.validateFieldName('doc.type'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.invalidValue,
            'invalidValue',
            'doc.type',
          ),
        ),
      );
    });

    test('accepts names vec0 could not represent', () {
      // The point of moving these rules out of core. A hyphen, a space, a
      // leading underscore and non-ASCII are all fine as qdrant payload keys;
      // FilterToVec0.validateFieldName rejects every one of them.
      for (final name in ['doc-type', 'doc type', '_lang', 'länge', 'k']) {
        expect(
          () => FilterCodec.validateFieldName(name),
          returnsNormally,
          reason: '$name is a legal qdrant payload key',
        );
      }
    });

    test('core still catches what is wrong on every backend', () {
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
  });
}
