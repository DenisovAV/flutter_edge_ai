import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/converters/response_converter.dart';

void main() {
  group('convertFinalResponse', () {
    test('converts text response', () {
      final result = convertFinalResponse('Hello world');

      expect(result.message?.role, Role.model);
      expect(result.finishReason, FinishReason.stop);
      final parts = result.message!.content;
      expect(parts, hasLength(1));
      expect(parts.first.isText, isTrue);
      expect(parts.first.text, 'Hello world');
    });

    test('converts single function call response', () {
      const call = gemma.FunctionCallResponse(
        name: 'get_weather',
        args: {'location': 'Paris'},
      );

      final result = convertFinalResponse('', functionCalls: [call]);

      final parts = result.message!.content;
      expect(parts, hasLength(1));
      expect(parts.first.isToolRequest, isTrue);
      expect(parts.first.toolRequest!.name, 'get_weather');
      expect(parts.first.toolRequest!.input, {'location': 'Paris'});
    });

    test('converts parallel function calls response', () {
      const call1 = gemma.FunctionCallResponse(
        name: 'get_weather',
        args: {'location': 'Paris'},
      );
      const call2 = gemma.FunctionCallResponse(
        name: 'get_time',
        args: {'timezone': 'CET'},
      );

      final result = convertFinalResponse('', functionCalls: [call1, call2]);

      final parts = result.message!.content;
      expect(parts, hasLength(2));
      expect(parts[0].isToolRequest, isTrue);
      expect(parts[0].toolRequest!.name, 'get_weather');
      expect(parts[1].isToolRequest, isTrue);
      expect(parts[1].toolRequest!.name, 'get_time');
      expect(parts[1].toolRequest!.input, {'timezone': 'CET'});
    });

    test('includes finishReason stop', () {
      final result = convertFinalResponse('text');
      expect(result.finishReason, FinishReason.stop);
    });

    test('propagates latencyMs', () {
      final result = convertFinalResponse('text', latencyMs: 42.0);
      expect(result.latencyMs, 42.0);
    });

    test('latencyMs is null when not provided', () {
      final result = convertFinalResponse('text');
      expect(result.latencyMs, isNull);
    });

    test('includes reasoning text as ReasoningPart', () {
      final result = convertFinalResponse(
        'answer',
        reasoningText: 'thinking step by step',
      );

      final parts = result.message!.content;
      expect(parts, hasLength(2));
      expect(parts[0].isReasoning, isTrue);
      expect(parts[0].reasoning, 'thinking step by step');
      expect(parts[1].isText, isTrue);
      expect(parts[1].text, 'answer');
    });

    test('skips empty reasoning text', () {
      final result = convertFinalResponse('answer', reasoningText: '');

      final parts = result.message!.content;
      expect(parts, hasLength(1));
      expect(parts.first.isText, isTrue);
    });

    test('reasoning-only response has no empty TextPart', () {
      final result = convertFinalResponse('', reasoningText: 'thinking...');

      final parts = result.message!.content;
      expect(parts, hasLength(1));
      expect(parts.first.isReasoning, isTrue);
      expect(parts.first.reasoning, 'thinking...');
    });
  });

  group('convertStreamChunk', () {
    test('converts text chunk', () {
      const chunk = gemma.TextResponse('token');

      final result = convertStreamChunk(chunk);

      expect(result.role, Role.model);
      expect(result.content, hasLength(1));
      expect(result.content.first.isText, isTrue);
      expect(result.content.first.text, 'token');
    });

    test('converts function call chunk', () {
      const chunk = gemma.FunctionCallResponse(
        name: 'search',
        args: {'q': 'test'},
      );

      final result = convertStreamChunk(chunk);

      expect(result.content.first.isToolRequest, isTrue);
    });

    test('converts thinking chunk to ReasoningPart', () {
      const chunk = gemma.ThinkingResponse('reasoning...');

      final result = convertStreamChunk(chunk);

      expect(result.content, hasLength(1));
      expect(result.content.first.isReasoning, isTrue);
      expect(result.content.first.reasoning, 'reasoning...');
    });

    test('converts parallel function call chunk', () {
      const chunk = gemma.ParallelFunctionCallResponse(
        calls: [
          gemma.FunctionCallResponse(name: 'a', args: {'x': 1}),
          gemma.FunctionCallResponse(name: 'b', args: {'y': 2}),
        ],
      );

      final result = convertStreamChunk(chunk);

      expect(result.content, hasLength(2));
      expect(result.content[0].isToolRequest, isTrue);
      expect(result.content[0].toolRequest!.name, 'a');
      expect(result.content[1].isToolRequest, isTrue);
      expect(result.content[1].toolRequest!.name, 'b');
    });

    test('returns empty content for empty thinking chunk', () {
      const chunk = gemma.ThinkingResponse('');

      final result = convertStreamChunk(chunk);

      expect(result.content, isEmpty);
    });
  });
}
