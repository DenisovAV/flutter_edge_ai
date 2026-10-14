import 'dart:convert';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every text a `Message.toolCall` has been written with must still replay.
void main() {
  List<FunctionCallResponse> parse(String text) =>
      toolCallsOf(Message.toolCall(text: text));

  const search = FunctionCallResponse(name: 'search', args: {'q': 'a'});
  const searchA = FunctionCallResponse(
    name: 'search',
    args: {'q': 'a'},
    id: 'a',
  );

  test('stored calls win over the text', () {
    final message = Message.toolCall(
      text: 'whatever the model wrote',
      calls: const [searchA],
    );

    expect(toolCallsOf(message), [searchA]);
  });

  test('a message that is not a tool call has none', () {
    expect(toolCallsOf(Message.text(text: '{"name":"search"}')), isEmpty);
    expect(
      toolCallsOf(Message.toolResponse(toolName: 'search', response: {})),
      isEmpty,
    );
  });

  test('canonical text, ids kept', () {
    expect(
      parse(
        '{"tool_calls":[{"id":"a","name":"search","arguments":{"q":"a"}},'
        '{"name":"clock","arguments":{}}]}',
      ),
      [searchA, const FunctionCallResponse(name: 'clock', args: {})],
    );
  });

  test('round trip through the canonical text', () {
    final written = Message.toolCall(calls: const [searchA, search]);

    expect(parse(written.text), written.toolCalls);
  });

  test('the raw LiteRT-LM response InferenceChat stored', () {
    expect(
      parse(
        '{"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"search","arguments":{"q":"a"}}}]}',
      ),
      [search],
    );
  });

  test('several raw responses back to back', () {
    expect(
      parse(
        '{"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"search","arguments":{"q":"a"}}}]}'
        '{"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"clock","arguments":{}}}]}',
      ),
      [search, const FunctionCallResponse(name: 'clock', args: {})],
    );
  });

  test('the multimodal content shape', () {
    expect(
      parse(
        '{"role":"assistant","content":[{"type":"tool_call","tool_call":'
        '{"name":"search","arguments":{"q":"a"}}}]}',
      ),
      [search],
    );
  });

  test('the genai and Genkit shape, one call or a list', () {
    expect(parse('{"name":"search","parameters":{"q":"a"}}'), [search]);
    expect(
      parse(
        '[{"name":"search","parameters":{"q":"a"}},'
        '{"name":"clock","parameters":null}]',
      ),
      [search, const FunctionCallResponse(name: 'clock', args: {})],
    );
  });

  test('a list of calls keeps their ids', () {
    expect(
      parse(
        '[{"id":"a","name":"search","parameters":{"q":"a"}},'
        '{"id":"b","name":"clock","arguments":"{}"}]',
      ),
      [searchA, const FunctionCallResponse(name: 'clock', args: {}, id: 'b')],
    );
  });

  test('OpenAI wire: id outside, arguments as a JSON string', () {
    expect(
      parse(
        jsonEncode({
          'tool_calls': [
            {
              'id': 'a',
              'type': 'function',
              'function': {'name': 'search', 'arguments': '{"q":"a"}'},
            },
          ],
        }),
      ),
      [searchA],
    );
  });

  test('blank or missing arguments are {}', () {
    for (final call in [
      {'name': 'clock', 'arguments': ''},
      {'name': 'clock', 'arguments': '  '},
      {'name': 'clock', 'parameters': null},
      {'name': 'clock'},
    ]) {
      expect(parse(jsonEncode(call)), [
        const FunctionCallResponse(name: 'clock', args: {}),
      ], reason: '$call');
    }
  });

  test('arguments that are not a JSON object drop the call', () {
    expect(parse('{"name":"search","arguments":"not json"}'), isEmpty);
    expect(parse('{"name":"search","arguments":[1]}'), isEmpty);
  });

  test('raw Gemma 4 tokens the web SDK leaves as text', () {
    expect(parse('<|tool_call>call:search{q:<|"|>a<|"|>}<tool_call|>'), [
      search,
    ]);
  });

  test('FunctionGemma wire text', () {
    expect(
      parse(
        '<start_function_call>call:search{q:<escape>a<escape>}'
        '<end_function_call>',
      ),
      [search],
    );
  });

  test("the model's own text-path blocks", () {
    expect(
      parse('<tool_call>{"name":"search","arguments":{"q":"a"}}</tool_call>'),
      [search],
      reason: 'Qwen',
    );
    expect(
      parse('```json\n{"name": "search", "parameters": {"q": "a"}}\n```'),
      [search],
      reason: 'JSON in markdown',
    );
    expect(
      parse(
        '<|tool_calls|>[{"name":"search","arguments":{"q":"a"}}]<|/tool_calls|>',
      ),
      [search],
      reason: 'Phi',
    );
    expect(
      parse(
        '<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>search\n'
        '{"q":"a"}<｜tool▁call▁end｜><｜tool▁calls▁end｜>',
      ),
      [search],
      reason: 'DeepSeek',
    );
    expect(parse('<|python_tag|>[search(q="a")]'), [search], reason: 'Llama');
  });

  test('text with no call parses to none', () {
    expect(parse(''), isEmpty);
    expect(parse('Sure, let me look that up.'), isEmpty);
    expect(parse('{"role":"assistant","tool_calls":[]}'), isEmpty);
  });
}
