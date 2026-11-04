import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/structured/reply_validation.dart';
import 'package:flutter_test/flutter_test.dart';

JsonSchemaResponseFormat _schema(Map<String, Object?> schema) =>
    ResponseFormat.jsonSchema(schema) as JsonSchemaResponseFormat;

Map<String, Object?> _nested(int levels) {
  var schema = <String, Object?>{'type': 'string'};
  for (var i = 1; i < levels; i++) {
    schema = {'type': 'array', 'items': schema};
  }
  return schema;
}

void main() {
  group('ResponseFormat.jsonSchema', () {
    test('jsonObject is jsonSchema({type: object}): one kind, one value', () {
      final object = ResponseFormat.jsonObject();
      expect(object, isA<JsonSchemaResponseFormat>());
      expect(object, ResponseFormat.jsonSchema({'type': 'object'}));
      expect(
        object.hashCode,
        ResponseFormat.jsonSchema({'type': 'object'}).hashCode,
      );
    });

    test('== ignores key order and compares the name', () {
      final a = ResponseFormat.jsonSchema({
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'integer'},
        },
      });
      final b = ResponseFormat.jsonSchema({
        'properties': {
          'b': {'type': 'integer'},
          'a': {'type': 'string'},
        },
        'type': 'object',
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        ResponseFormat.jsonSchema({'type': 'object'}, name: 'x'),
        isNot(ResponseFormat.jsonSchema({'type': 'object'})),
      );
    });

    test('schemaJson keeps the caller\'s key order', () {
      final format = _schema({
        'type': 'object',
        'properties': {
          'zeta': {'type': 'string'},
          'alpha': {'type': 'string'},
        },
      });
      expect(
        format.schemaJson,
        '{"type":"object","properties":{"zeta":{"type":"string"},'
        '"alpha":{"type":"string"}}}',
      );
    });

    test('the schema is an unmodifiable deep copy', () {
      final properties = <String, Object?>{
        'a': {'type': 'string'},
      };
      final source = <String, Object?>{
        'type': 'object',
        'properties': properties,
      };
      final format = _schema(source);
      properties['b'] = {'type': 'integer'};
      expect((format.schema['properties']! as Map).keys, ['a']);
      expect(() => format.schema['type'] = 'array', throwsUnsupportedError);
      expect(
        () => (format.schema['properties']! as Map)['c'] = 1,
        throwsUnsupportedError,
      );
    });

    test('a keyword outside the dialect is accepted here (the model refuses '
        'it at open)', () {
      expect(
        () => ResponseFormat.jsonSchema({
          'type': 'object',
          'properties': {
            'code': {'type': 'string', 'pattern': '^[A-Z]+\$'},
          },
          r'$defs': {'x': true},
          'anyOf': [true],
        }),
        returnsNormally,
      );
    });

    test('nesting of 32 levels is accepted, 33 refused', () {
      expect(() => ResponseFormat.jsonSchema(_nested(32)), returnsNormally);
      expect(
        () => ResponseFormat.jsonSchema(_nested(33)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('deeper than 32'),
          ),
        ),
      );
    });

    final malformed = <String, Map<String, Object?>>{
      'not JSON-encodable': {'type': 'object', 'x': Object()},
      'a root without a type': {'properties': <String, Object?>{}},
      'a type array': {
        'type': ['string', 'null'],
      },
      'an unknown type': {'type': 'date'},
      'a boolean subschema': {
        'type': 'object',
        'properties': {'a': true},
      },
      'properties that are not a map': {
        'type': 'object',
        'properties': ['a'],
      },
      'a required name not in properties': {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['b'],
      },
      'a required name twice': {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['a', 'a'],
      },
      'required that is not a list': {'type': 'object', 'required': 'a'},
      'additionalProperties true': {
        'type': 'object',
        'additionalProperties': true,
      },
      'additionalProperties as a schema': {
        'type': 'object',
        'additionalProperties': {'type': 'string'},
      },
      'items that are a list': {
        'type': 'array',
        'items': [
          {'type': 'string'},
        ],
      },
      'minItems above maxItems': {
        'type': 'array',
        'minItems': 3,
        'maxItems': 2,
      },
      'a negative minLength': {'type': 'string', 'minLength': -1},
      'a fractional maxLength': {'type': 'string', 'maxLength': 2.5},
      'minimum above maximum': {'type': 'number', 'minimum': 2, 'maximum': 1},
      'a minimum that is not a number': {'type': 'number', 'minimum': '1'},
      'an empty enum': {'type': 'string', 'enum': <Object?>[]},
      'an enum with equal values (1 and 1.0)': {
        'type': 'number',
        'enum': [1, 1.0],
      },
      'a fractional minItems': {'type': 'array', 'minItems': 2.5},
      'an explicit type: null in a subschema': {
        'type': 'object',
        'properties': {
          'a': {'type': null},
        },
      },
      'properties: null': {'type': 'object', 'properties': null},
      'items: null': {'type': 'array', 'items': null},
      'an infinite number': {'type': 'number', 'maximum': double.infinity},
      'NaN anywhere': {
        'type': 'string',
        'examples': [double.nan],
      },
      'a map key that is not a string': {
        'type': 'object',
        'properties': {1: <String, Object?>{}},
      },
      'an enum with equal objects in another key order': {
        'type': 'object',
        'enum': [
          {'a': 1, 'b': 2},
          {'b': 2, 'a': 1},
        ],
      },
    };
    for (final MapEntry(key: problem, value: schema) in malformed.entries) {
      test('refuses $problem with ArgumentError', () {
        expect(
          () => ResponseFormat.jsonSchema(schema),
          throwsA(isA<ArgumentError>()),
        );
      });
    }

    test('accepts integer bounds written as 2.0 and every dialect keyword', () {
      expect(
        () => ResponseFormat.jsonSchema({
          'type': 'object',
          'title': 'Order',
          'description': 'An order',
          'examples': [
            {'id': 'A'},
          ],
          'properties': {
            'id': {'type': 'string', 'minLength': 1.0, 'maxLength': 8},
            'n': {'type': 'integer', 'minimum': 0, 'maximum': 9.5},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 0,
              'maxItems': 3,
            },
            'kind': {
              'enum': ['a', 'b'],
            },
            'v': {'const': null},
          },
          'required': ['id'],
          'additionalProperties': false,
        }),
        returnsNormally,
      );
    });
  });

  group('the reply check', () {
    StructuredOutputException? check(
      Map<String, Object?> schema,
      String text, [
      TurnEnd end = TurnEnd.endOfSequence,
    ]) => structuredReplyFailure(_schema(schema), text, end);

    void expectViolation(
      Map<String, Object?> schema,
      String text,
      String schemaPath,
    ) {
      final failure = check(schema, text);
      expect(
        failure,
        isA<NonConformingStructuredOutputException>()
            .having((e) => e.schemaPath, 'schemaPath', schemaPath)
            .having((e) => e.text, 'text', text),
        reason: text,
      );
    }

    test('every end but endOfSequence is incomplete, even when the text '
        'parses', () {
      for (final end in TurnEnd.values) {
        final failure = check({'type': 'object'}, '{}', end);
        if (end == TurnEnd.endOfSequence) {
          expect(failure, isNull);
        } else {
          expect(
            failure,
            isA<IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', end)
                .having((e) => e.partialText, 'partialText', '{}'),
          );
        }
      }
    });

    test('whitespace is trimmed; nothing else is unwrapped', () {
      expect(check({'type': 'object'}, '  \n{"a": 1}\n '), isNull);
      for (final text in [
        '```json\n{}\n```',
        'Here: {}',
        '{} trailing',
        '{"a": 1',
        '',
      ]) {
        expect(
          check({'type': 'object'}, text),
          isA<NonConformingStructuredOutputException>().having(
            (e) => e.schemaPath,
            'schemaPath',
            isNull,
          ),
          reason: text,
        );
      }
    });

    test('type: integer takes 1.0, not 1.5', () {
      expect(check({'type': 'integer'}, '1.0'), isNull);
      expectViolation({'type': 'integer'}, '1.5', '/type');
      expectViolation({'type': 'number'}, '"1"', '/type');
      expectViolation({'type': 'null'}, 'false', '/type');
      expectViolation({'type': 'boolean'}, 'null', '/type');
    });

    final order = <String, Object?>{
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'minLength': 2, 'maxLength': 3},
        'n': {'type': 'integer', 'minimum': 1, 'maximum': 5},
        'tags': {
          'type': 'array',
          'items': {
            'enum': ['x', 'y'],
          },
          'minItems': 1,
          'maxItems': 2,
        },
        'a/b': {'const': 'k'},
      },
      'required': ['id'],
      'additionalProperties': false,
    };

    test('a conforming value passes', () {
      expect(
        check(order, '{"id": "ab", "n": 5, "tags": ["y"], "a/b": "k"}'),
        isNull,
      );
    });

    test('each keyword names its path', () {
      expectViolation(order, '{"n": 1}', '/required');
      expectViolation(order, '{"id": "ab", "z": 1}', '/additionalProperties');
      expectViolation(order, '{"id": "a"}', '/properties/id/minLength');
      expectViolation(order, '{"id": "abcd"}', '/properties/id/maxLength');
      expectViolation(order, '{"id": "ab", "n": 0}', '/properties/n/minimum');
      expectViolation(order, '{"id": "ab", "n": 6}', '/properties/n/maximum');
      expectViolation(
        order,
        '{"id": "ab", "tags": []}',
        '/properties/tags/minItems',
      );
      expectViolation(
        order,
        '{"id": "ab", "tags": ["x", "y", "x"]}',
        '/properties/tags/maxItems',
      );
      expectViolation(
        order,
        '{"id": "ab", "tags": ["z"]}',
        '/properties/tags/items/enum',
      );
      expectViolation(
        order,
        '{"id": "ab", "a/b": "j"}',
        '/properties/a~1b/const',
      );
    });

    test('lengths count code points', () {
      // Two emoji: two code points, four UTF-16 units.
      expect(
        check({'type': 'string', 'maxLength': 2}, '"\u{1F600}\u{1F600}"'),
        isNull,
      );
    });

    test('enum and const compare decoded values deeply', () {
      expect(
        check({
          'type': 'object',
          'const': {'a': 1, 'b': 2},
        }, '{"b": 2.0, "a": 1}'),
        isNull,
      );
      expectViolation(
        {
          'type': 'array',
          'enum': [
            [1, 2],
          ],
        },
        '[2, 1]',
        '/enum',
      );
    });

    test('a type-specific keyword applies only to its type', () {
      // minLength on a value that may be a number (no type declared below
      // the root).
      expect(
        check({
          'type': 'object',
          'properties': {
            'v': {'minLength': 3},
          },
        }, '{"v": 7}'),
        isNull,
      );
    });
  });

  group('review follow-ups: construction', () {
    test('a map that contains itself is refused, not a stack overflow', () {
      final schema = <String, Object?>{'type': 'object'};
      schema['examples'] = [schema];
      expect(
        () => ResponseFormat.jsonSchema(schema),
        throwsA(isA<ArgumentError>()),
      );
      final direct = <String, Object?>{'type': 'object'};
      direct['properties'] = {'self': direct};
      expect(
        () => ResponseFormat.jsonSchema(direct),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('nesting through properties counts too', () {
      var schema = <String, Object?>{'type': 'string'};
      for (var i = 1; i < 33; i++) {
        schema = {
          'type': 'object',
          'properties': {'p': schema},
        };
      }
      expect(() => ResponseFormat.jsonSchema(schema), throwsArgumentError);
    });

    test('equal bounds are well formed', () {
      expect(
        () => ResponseFormat.jsonSchema({
          'type': 'array',
          'minItems': 2,
          'maxItems': 2,
        }),
        returnsNormally,
      );
    });

    test('lists in the schema are unmodifiable too', () {
      final format = _schema({
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['a'],
      });
      expect(
        () => (format.schema['required']! as List).add('b'),
        throwsUnsupportedError,
      );
    });

    test('== takes 1 and 1.0 as one value, as JSON does', () {
      final a = ResponseFormat.jsonSchema({'type': 'number', 'maximum': 1});
      final b = ResponseFormat.jsonSchema({'type': 'number', 'maximum': 1.0});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(ResponseFormat.jsonSchema({'type': 'number', 'maximum': 1.5})),
      );
    });

    test('schemaJson keeps an integer-like key where the caller put it', () {
      // On the web a jsonDecode round trip moves "1" first.
      expect(
        _schema({
          'type': 'object',
          'properties': {
            'b': {'type': 'string'},
            '1': {'type': 'string'},
          },
        }).schemaJson,
        '{"type":"object","properties":{"b":{"type":"string"},'
        '"1":{"type":"string"}}}',
      );
    });
  });

  group('review follow-ups: the reply check', () {
    StructuredOutputException? check(
      Map<String, Object?> schema,
      String text,
    ) => structuredReplyFailure(_schema(schema), text, TurnEnd.endOfSequence);

    test('only JSON whitespace may surround the value', () {
      expect(check({'type': 'object'}, ' \t\r\n{}\n '), isNull);
      for (final space in [' ', '﻿', ' ']) {
        expect(
          check({'type': 'object'}, '$space{}'),
          isA<NonConformingStructuredOutputException>()
              .having((e) => e.schemaPath, 'schemaPath', isNull)
              .having((e) => e.text, 'text', '$space{}'),
          reason: space.codeUnitAt(0).toRadixString(16),
        );
      }
    });

    test('a number that decodes to infinity is non-conforming', () {
      for (final (schema, text) in [
        (<String, Object?>{'type': 'number'}, '1e400'),
        (<String, Object?>{'type': 'object'}, '{"v": -1e400}'),
      ]) {
        expect(
          check(schema, text),
          isA<NonConformingStructuredOutputException>().having(
            (e) => e.text,
            'text',
            text,
          ),
          reason: text,
        );
      }
    });

    test('object and array are told apart', () {
      expect(
        check({'type': 'object'}, '[]'),
        isA<NonConformingStructuredOutputException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/type',
        ),
      );
      expect(
        check({'type': 'array'}, '{}'),
        isA<NonConformingStructuredOutputException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/type',
        ),
      );
      expect(check({'type': 'array'}, '[]'), isNull);
    });

    test('the bounds are inclusive', () {
      expect(check({'type': 'array', 'maxItems': 2}, '[1, 2]'), isNull);
      expect(check({'type': 'array', 'minItems': 2}, '[1, 2]'), isNull);
      expect(check({'type': 'number', 'minimum': 1}, '1'), isNull);
      expect(check({'type': 'number', 'maximum': 1}, '1'), isNull);
      expect(check({'type': 'string', 'maxLength': 2}, '"ab"'), isNull);
    });

    test('a property name with ~ is escaped in the path', () {
      expect(
        check({
          'type': 'object',
          'properties': {
            'a~b': {'type': 'string'},
          },
        }, '{"a~b": 1}'),
        isA<NonConformingStructuredOutputException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/properties/a~0b/type',
        ),
      );
    });

    test('enum and const compare sizes too', () {
      expect(
        check({
          'type': 'object',
          'enum': [
            {'a': 1},
          ],
        }, '{"a": 1, "b": 2}'),
        isA<NonConformingStructuredOutputException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/enum',
        ),
      );
      expect(
        check({
          'type': 'array',
          'const': [1],
        }, '[1, 2]'),
        isA<NonConformingStructuredOutputException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/const',
        ),
      );
    });
  });
}
