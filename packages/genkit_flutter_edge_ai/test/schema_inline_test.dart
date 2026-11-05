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

  test('annotations beside a \$ref win over the definition\'s', () {
    expect(
      inlineSchemaRefs({
        r'$ref': r'#/$defs/Recipe',
        'description': 'Mine.',
        r'$defs': {
          'Recipe': {...recipe, 'description': 'Its own.', 'title': 'R'},
        },
      }),
      {...recipe, 'description': 'Mine.', 'title': 'R'},
    );
  });

  test('a single allOf with annotations is its element (schemantic\'s '
      '@Field(description:))', () {
    expect(
      inlineSchemaRefs({
        'type': 'object',
        'properties': {
          'main': {
            'allOf': [
              {r'$ref': r'#/$defs/Recipe'},
            ],
            'description': 'The main dish.',
          },
        },
        r'$defs': {'Recipe': recipe},
      }),
      {
        'type': 'object',
        'properties': {
          'main': {...recipe, 'description': 'The main dish.'},
        },
      },
    );
  });

  test('an allOf with a keyword beside it stays an allOf, its references '
      'inlined', () {
    // Core refuses allOf, so this one stays a prompt instruction.
    expect(
      inlineSchemaRefs({
        'allOf': [
          {r'$ref': r'#/$defs/Recipe'},
        ],
        'type': 'object',
        r'$defs': {'Recipe': recipe},
      }),
      {
        'allOf': [recipe],
        'type': 'object',
      },
    );
  });

  test('properties may be named like keywords', () {
    expect(
      inlineSchemaRefs({
        'type': 'object',
        'properties': {
          'examples': {r'$ref': r'#/$defs/Recipe'},
          'enum': {r'$ref': r'#/$defs/Recipe'},
          'const': {'type': 'string'},
          r'$ref': {'type': 'string'},
        },
        r'$defs': {'Recipe': recipe},
      }),
      {
        'type': 'object',
        'properties': {
          'examples': recipe,
          'enum': recipe,
          'const': {'type': 'string'},
          r'$ref': {'type': 'string'},
        },
      },
    );
  });

  test('a definition name is a JSON Pointer token in a URI fragment', () {
    const a = {'type': 'string'};
    const b = {'type': 'integer'};
    const c = {'type': 'number'};
    expect(
      inlineSchemaRefs({
        'type': 'object',
        'properties': {
          'slash': {r'$ref': r'#/$defs/a~1b'},
          'tilde': {r'$ref': r'#/$defs/a~0b'},
          'space': {r'$ref': r'#/$defs/a%20b'},
        },
        r'$defs': {
          'a/b': a,
          'a~b': b,
          'a b': c,
          // Never what an escaped name points at.
          'a~1b': {'type': 'boolean'},
          'a~0b': {'type': 'boolean'},
        },
      }),
      {
        'type': 'object',
        'properties': {'slash': a, 'tilde': b, 'space': c},
      },
    );
  });

  test('a map that contains itself is not inlined', () {
    final node = <String, dynamic>{'type': 'object'};
    node['properties'] = {'self': node};
    expect(inlineSchemaRefs(node), isNull);

    final list = <Object?>[];
    list.add({'anyOf': list});
    expect(inlineSchemaRefs({'type': 'object', 'anyOf': list}), isNull);
  });

  test('a definition referenced twice is inlined twice, shared', () {
    final schema = inlineSchemaRefs({
      'type': 'object',
      'properties': {
        'a': {r'$ref': r'#/$defs/Recipe'},
        'b': {r'$ref': r'#/$defs/Recipe'},
      },
      r'$defs': {'Recipe': recipe},
    })!;
    final properties = schema['properties']! as Map;
    expect(properties['a'], recipe);
    expect(identical(properties['a'], properties['b']), isTrue);
  });

  test('references that grow exponentially are not inlined', () {
    // D0 has two properties referencing D1, each of which has two
    // referencing D2, …: 2^24 nodes once inlined.
    final defs = <String, Object?>{
      for (var i = 0; i < 24; i++)
        'D$i': {
          'type': 'object',
          'properties': {
            'a': {r'$ref': '#/\$defs/D${i + 1}'},
            'b': {r'$ref': '#/\$defs/D${i + 1}'},
          },
        },
      'D24': {'type': 'string'},
    };
    final stopwatch = Stopwatch()..start();
    expect(inlineSchemaRefs({r'$ref': r'#/$defs/D0', r'$defs': defs}), isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
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
        'c': {
          'type': 'string',
          'examples': [
            {r'$ref': 'not a reference'},
          ],
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
    (
      'a reference into definitions that are not a map',
      {r'$ref': r'#/$defs/Recipe', r'$defs': 'x'},
    ),
    (
      // `/` is a pointer separator unless escaped as `~1`.
      'an unescaped slash, even when a definition has that name',
      {
        r'$ref': r'#/$defs/a/b',
        r'$defs': {'a/b': recipe},
      },
    ),
    (
      'a pointer deeper than one definition',
      {
        r'$ref': r'#/$defs/Recipe/properties',
        r'$defs': {'Recipe': recipe},
      },
    ),
  ]) {
    test('$what is not inlined', () {
      expect(inlineSchemaRefs(schema), isNull);
    });
  }
}
