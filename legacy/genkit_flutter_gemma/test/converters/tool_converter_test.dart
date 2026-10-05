import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/converters/tool_converter.dart';

void main() {
  group('convertTools', () {
    test('converts tool definitions', () {
      final tools = [
        ToolDefinition(
          name: 'get_weather',
          description: 'Get weather for a location',
          inputSchema: {
            'type': 'object',
            'properties': {
              'location': {'type': 'string'},
            },
            'required': ['location'],
          },
        ),
      ];

      final result = convertTools(tools);

      expect(result, hasLength(1));
      expect(result[0].name, 'get_weather');
      expect(result[0].description, 'Get weather for a location');
      expect(result[0].parameters['properties'], isNotNull);
    });

    test('returns empty list for null tools', () {
      expect(convertTools(null), isEmpty);
    });

    test('returns empty list for empty tools', () {
      expect(convertTools([]), isEmpty);
    });

    test('converts multiple tools', () {
      final tools = [
        ToolDefinition(name: 'tool_a', description: 'A'),
        ToolDefinition(name: 'tool_b', description: 'B'),
      ];

      final result = convertTools(tools);

      expect(result, hasLength(2));
      expect(result[0].name, 'tool_a');
      expect(result[1].name, 'tool_b');
    });

    test('handles tool with no input schema', () {
      final tools = [
        ToolDefinition(name: 'my_tool', description: 'desc'),
      ];

      final result = convertTools(tools);

      expect(result[0].parameters, isEmpty);
    });
  });
}
