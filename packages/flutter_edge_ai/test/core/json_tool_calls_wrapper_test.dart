import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/function_call_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// A text engine replays `Message.toolCall(calls:)` as its canonical JSON, and
/// a model may answer in the shape it sees in its history.
void main() {
  final canonical = Message.toolCall(
    calls: const [
      FunctionCallResponse(name: 'search', args: {'q': 'a'}, id: 'c1'),
      FunctionCallResponse(name: 'lookup', args: {}),
    ],
  ).text;
  const expected = [
    FunctionCallResponse(name: 'search', args: {'q': 'a'}),
    FunctionCallResponse(name: 'lookup', args: {}),
  ];

  for (final type in const [
    ModelType.gemmaIt,
    ModelType.general,
    ModelType.hammer,
    ModelType.qwen,
    ModelType.phi,
    ModelType.deepSeek,
    ModelType.llama,
  ]) {
    test('${type.name} reads the canonical tool_calls text', () {
      expect(FunctionCallParser.parseAll(canonical, modelType: type), expected);
    });
  }

  test('an OpenAI-style item is read too', () {
    expect(
      FunctionCallParser.parseAll(
        '{"tool_calls":[{"type":"function","function":'
        '{"name":"search","arguments":{"q":"a"}}}]}',
        modelType: ModelType.general,
      ),
      [expected.first],
    );
  });

  test('a tool_calls list with an item it cannot read gives none', () {
    expect(
      FunctionCallParser.parseAll(
        '{"tool_calls":[{"name":"search","arguments":{"q":"a"}},'
        '{"arguments":{}}]}',
        modelType: ModelType.general,
      ),
      isEmpty,
    );
  });
}
