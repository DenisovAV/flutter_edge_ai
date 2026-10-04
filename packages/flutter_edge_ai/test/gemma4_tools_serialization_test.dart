import 'dart:convert';

import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SdkResponseParser.serializeToolsForSdk', () {
    test('single tool produces OpenAI Chat Completions JSON', () {
      const tools = [
        Tool(
          name: 'change_color',
          description: 'Change UI background color',
          parameters: {
            'type': 'object',
            'properties': {
              'color': {'type': 'string'},
            },
            'required': ['color'],
          },
        ),
      ];
      final raw = SdkResponseParser.serializeToolsForSdk(tools);
      final decoded = jsonDecode(raw) as List<dynamic>;
      expect(decoded, hasLength(1));
      expect(decoded.first, isA<Map<String, dynamic>>());
      final entry = decoded.first as Map<String, dynamic>;
      expect(entry['type'], equals('function'));
      expect(entry['function'], isA<Map<String, dynamic>>());
      final fn = entry['function'] as Map<String, dynamic>;
      expect(fn['name'], equals('change_color'));
      expect(fn['description'], equals('Change UI background color'));
      expect(fn['parameters'], equals(tools.first.parameters));
    });

    test('multiple tools — order preserved, each wrapped', () {
      const tools = [
        Tool(name: 'first', description: 'First tool', parameters: {}),
        Tool(name: 'second', description: 'Second tool', parameters: {}),
      ];
      final decoded =
          jsonDecode(SdkResponseParser.serializeToolsForSdk(tools)) as List;
      expect(decoded, hasLength(2));
      expect((decoded[0] as Map)['function']['name'], equals('first'));
      expect((decoded[1] as Map)['function']['name'], equals('second'));
      for (final entry in decoded) {
        expect((entry as Map)['type'], equals('function'));
      }
    });
  });

  group('SdkResponseParser.buildToolResponsesJson', () {
    test('every result of a turn goes in one role:tool message', () {
      final raw = SdkResponseParser.buildToolResponsesJson([
        (name: 'get_weather', response: {'temp': 72, 'unit': 'F'}),
        (name: 'get_time', response: {'time': '12:00'}),
      ]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['role'], equals('tool'));
      expect(
        decoded['content'],
        equals([
          {
            'type': 'tool_response',
            'name': 'get_weather',
            'response': {'temp': 72, 'unit': 'F'},
          },
          {
            'type': 'tool_response',
            'name': 'get_time',
            'response': {'time': '12:00'},
          },
        ]),
      );
    });
  });

  group('SdkResponseParser.toolResponsePayload', () {
    test(
      'a JSON-encoded map, as Message.toolResponse stores it, is the map',
      () {
        expect(
          SdkResponseParser.toolResponsePayload('{"result":7006652}'),
          equals({'result': 7006652}),
        );
      },
    );

    test('other JSON goes under value', () {
      expect(
        SdkResponseParser.toolResponsePayload('42'),
        equals({'value': 42}),
      );
    });

    test('plain text goes under value', () {
      expect(
        SdkResponseParser.toolResponsePayload('OK'),
        equals({'value': 'OK'}),
      );
    });
  });
}
