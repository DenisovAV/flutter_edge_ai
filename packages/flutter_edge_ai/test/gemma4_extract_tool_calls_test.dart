import 'dart:convert';

import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SdkResponseParser.extractToolCalls', () {
    test('OpenAI-style top-level tool_calls (Phase 0b empirical shape)', () {
      // The exact response shape captured from gemma-4-E2B-it on macOS GPU
      // 2026-04-29 (see example/integration_test/gemma4_raw_output_capture.dart).
      const raw =
          '{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"change_color","arguments":{"color":"<|\\"|>red<|\\"|>"}}}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.first.name, equals('change_color'));
      expect(calls.first.args, equals({'color': 'red'}));
    });

    test('flat top-level tool_calls without function wrapper', () {
      const raw = '{"tool_calls":[{"name":"foo","arguments":{"x":1}}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.first.name, equals('foo'));
      expect(calls.first.args, equals({'x': 1}));
    });

    test('parallel tool_calls — order preserved', () {
      final raw = jsonEncode({
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'first',
              'arguments': {'a': 1},
            },
          },
          {
            'type': 'function',
            'function': {
              'name': 'second',
              'arguments': {'b': 2},
            },
          },
        ],
      });
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls.map((c) => c.name).toList(), equals(['first', 'second']));
    });

    test('multimodal content array tool_call', () {
      final raw = jsonEncode({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Calling tool now.'},
          {
            'type': 'tool_call',
            'tool_call': {
              'name': 'lookup',
              'arguments': {'query': 'flutter'},
            },
          },
        ],
      });
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.first.name, equals('lookup'));
      expect(calls.first.args, equals({'query': 'flutter'}));
    });

    test('plain text response yields empty list', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text","text":"Hello!"}]}';
      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });

    test('malformed JSON yields empty list (no throw)', () {
      expect(SdkResponseParser.extractToolCalls('this is not json'), isEmpty);
      expect(SdkResponseParser.extractToolCalls(''), isEmpty);
      expect(SdkResponseParser.extractToolCalls('{'), isEmpty);
    });

    test('concatenated JSON documents (parallel calls in distinct messages)', () {
      // Real shape captured from SDK on macOS GPU 2026-04-29 when prompt asks
      // for two unrelated tools: SDK emits two top-level JSON objects glued
      // together rather than one with a unified tool_calls array.
      const raw =
          '{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"change_color","arguments":{"color":"<|\\"|>blue<|\\"|>"}}}]}'
          '{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"set_volume","arguments":{"level":30}}}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(2));
      expect(calls[0].name, equals('change_color'));
      expect(calls[0].args, equals({'color': 'blue'}));
      expect(calls[1].name, equals('set_volume'));
      expect(calls[1].args, equals({'level': 30}));
    });

    test('nested args strip escape tokens recursively', () {
      // Escape tokens may appear inside nested objects, lists, or both.
      final raw = jsonEncode({
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'complex',
              'arguments': {
                'tags': ['<|"|>red<|"|>', '<|"|>blue<|"|>'],
                'meta': {'note': '<|"|>important<|"|>', 'count': 7},
              },
            },
          },
        ],
      });
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.first.args['tags'], equals(['red', 'blue']));
      expect(
        calls.first.args['meta'],
        equals({'note': 'important', 'count': 7}),
      );
    });
  });

  group('SdkResponseParser.cleanRawForHistory', () {
    // #248: chat history must not echo `<|"|>` tokens back to the model on
    // subsequent turns, otherwise Gemma 4 starts reproducing them in
    // tool_calls arguments and string-enum values get corrupted.
    test('strips <|"|> tokens from arguments before history persist', () {
      final raw = jsonEncode({
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'search_payments',
              'arguments': {
                'aggregation': '<|"|>sumAmount<|"|>',
                'startYear': 2023,
              },
            },
          },
        ],
      });
      final cleaned = SdkResponseParser.cleanRawForHistory(raw);
      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
      final args =
          (decoded['tool_calls'] as List).first['function']['arguments']
              as Map<String, dynamic>;
      expect(args['aggregation'], equals('sumAmount'));
      expect(args['startYear'], equals(2023));
    });

    test('handles nested maps and lists', () {
      final raw = jsonEncode({
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'tag_items',
              'arguments': {
                'tags': ['<|"|>red<|"|>', '<|"|>blue<|"|>'],
                'meta': {'note': '<|"|>important<|"|>'},
              },
            },
          },
        ],
      });
      final cleaned = SdkResponseParser.cleanRawForHistory(raw);
      expect(cleaned.contains('<|"|>'), isFalse);
    });

    test('returns input unchanged when not valid JSON', () {
      const malformed = 'not really json {{{';
      expect(
        SdkResponseParser.cleanRawForHistory(malformed),
        equals(malformed),
      );
    });

    test('preserves non-string fields verbatim', () {
      final raw = jsonEncode({
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'set_volume',
              'arguments': {'level': 75, 'muted': false, 'ratio': 0.5},
            },
          },
        ],
      });
      final cleaned = SdkResponseParser.cleanRawForHistory(raw);
      final args =
          (jsonDecode(cleaned)
                  as Map<
                    String,
                    dynamic
                  >)['tool_calls'][0]['function']['arguments']
              as Map<String, dynamic>;
      expect(args['level'], equals(75));
      expect(args['muted'], equals(false));
      expect(args['ratio'], equals(0.5));
    });
  });
}
