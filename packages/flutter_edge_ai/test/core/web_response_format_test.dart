@TestOn('browser')
library;

// What only the web can get wrong about a ResponseFormat: a jsonDecode round
// trip there returns maps that put integer-like keys first, and its numbers
// do not tell 1 from 1.0.
//
// Run: flutter test --platform chrome test/core/web_response_format_test.dart

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/structured/reply_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schemaJson keeps an integer-like key where the caller put it', () {
    final format =
        ResponseFormat.jsonSchema({
              'type': 'object',
              'properties': {
                'b': {'type': 'string'},
                '1': {'type': 'string'},
              },
            })
            as JsonSchemaResponseFormat;
    expect(
      format.schemaJson,
      '{"type":"object","properties":{"b":{"type":"string"},'
      '"1":{"type":"string"}}}',
    );
    expect((format.schema['properties']! as Map).keys, ['b', '1']);
  });

  test('== takes 1 and 1.0 as one value, as on the VM', () {
    expect(
      ResponseFormat.jsonSchema({'type': 'number', 'maximum': 1}),
      ResponseFormat.jsonSchema({'type': 'number', 'maximum': 1.0}),
    );
  });

  test('the reply check refuses what JSON.parse would not take either', () {
    final format =
        ResponseFormat.jsonSchema({'type': 'number'})
            as JsonSchemaResponseFormat;
    expect(structuredReplyFailure(format, '1', TurnEnd.endOfSequence), isNull);
    for (final text in [' 1', '1e400']) {
      expect(
        structuredReplyFailure(format, text, TurnEnd.endOfSequence),
        isA<NonConformingStructuredOutputException>(),
        reason: text,
      );
    }
  });
}
