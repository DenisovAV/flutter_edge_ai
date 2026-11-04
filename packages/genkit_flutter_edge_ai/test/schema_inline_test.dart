import 'package:flutter_test/flutter_test.dart';
import 'package:genkit_flutter_edge_ai/src/schema_inline.dart';

void main() {
  const recipe = {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
    },
  };

  test('a schemantic wrapper becomes its definition', () {
    expect(
      inlineSchemaRefs({
        r'$ref': r'#/$defs/Recipe',
        r'$defs': {'Recipe': recipe},
        r'$schema': 'http://json-schema.org/draft-07/schema#',
      }),
      recipe,
    );
  });

  test('nested references are inlined, annotations kept', () {
    expect(
      inlineSchemaRefs({
        'type': 'object',
        'properties': {
          'main': {r'$ref': '#/definitions/Recipe', 'description': 'Main.'},
          'sides': {
            'type': 'array',
            'items': {r'$ref': r'#/$defs/Recipe'},
          },
        },
        r'$defs': {'Recipe': recipe},
        'definitions': {'Recipe': recipe},
      }),
      {
        'type': 'object',
        'properties': {
          'main': {...recipe, 'description': 'Main.'},
          'sides': {'type': 'array', 'items': recipe},
        },
      },
    );
  });

  test('enum and const values are data, not schemas', () {
    const schema = {
      'type': 'object',
      'properties': {
        'a': {
          'enum': [
            {r'$ref': 'not a reference'},
          ],
        },
        'b': {
          'const': {r'$ref': 'not a reference'},
        },
      },
    };
    expect(inlineSchemaRefs(schema), schema);
  });

  test('a schema without references is unchanged, minus \$schema', () {
    expect(inlineSchemaRefs({...recipe, r'$schema': 'x'}), recipe);
  });

  for (final (what, schema) in <(String, Map<String, dynamic>)>[
    (
      'a recursive type',
      {
        r'$ref': r'#/$defs/Node',
        r'$defs': {
          'Node': {
            'type': 'object',
            'properties': {
              'next': {r'$ref': r'#/$defs/Node'},
            },
          },
        },
      },
    ),
    ('a missing definition', {r'$ref': r'#/$defs/Gone'}),
    ('a reference outside the document', {r'$ref': 'other.json#/Recipe'}),
    (
      'a reference with a keyword beside it',
      {
        r'$ref': r'#/$defs/Recipe',
        'type': 'object',
        r'$defs': {'Recipe': recipe},
      },
    ),
    ('definitions that are not a map', {r'$defs': 'x', 'type': 'object'}),
  ]) {
    test('$what is not inlined', () {
      expect(inlineSchemaRefs(schema), isNull);
    });
  }
}
