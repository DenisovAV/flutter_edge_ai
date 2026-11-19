// The tool-call reader the adapter hands litertlm_dart for replayed history:
// core's parser, so a call the model wrote as text is replayed as that call.
import 'dart:convert';

import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine.dart'
    show liteRtLmToolCallsOf;
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart' show nativeToolCalls;

String _reply(String text) => jsonEncode({
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
});

void main() {
  for (final (label, raw) in [
    (
      'a FunctionGemma call written as text',
      _reply(
        '<start_function_call>call:get_weather{city:<escape>Paris<escape>}'
        '<end_function_call>',
      ),
    ),
    (
      'a raw Gemma 4 <|tool_call> block',
      _reply('<|tool_call>call:get_weather{city:<|"|>Paris<|"|>}<tool_call|>'),
    ),
    (
      'a call native converted',
      jsonEncode({
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'get_weather',
              'arguments': {'city': 'Paris'},
            },
          },
        ],
      }),
    ),
  ]) {
    test('$label is read as get_weather{city: Paris}', () {
      final calls = liteRtLmToolCallsOf(raw);
      expect(calls.map((c) => c.name), ['get_weather']);
      expect(calls.single.arguments, {'city': 'Paris'});
    });
  }

  test('the runtime default reads only native calls, which is why the '
      'adapter passes its own', () {
    expect(
      nativeToolCalls(
        _reply(
          '<start_function_call>call:get_weather{city:<escape>Paris<escape>}'
          '<end_function_call>',
        ),
      ),
      isEmpty,
    );
  });
}
