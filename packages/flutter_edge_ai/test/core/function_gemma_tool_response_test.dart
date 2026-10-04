import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tool result is the only thing the model reads to answer. Golden strings
/// below are rendered by FunctionGemma's own `chat_template.jinja`: it splays a
/// dict response into dictsorted `key:value` pairs through `format_argument`,
/// so numbers and booleans stay bare and only strings are escape-wrapped.
///
/// The template ships with the model; an ungated copy lives at
/// huggingface.co/onnx-community/functiongemma-270m-it-ONNX.
void main() {
  String render(Map<String, dynamic> response) =>
      Message.toolResponse(
        toolName: 'get_weather',
        response: response,
      ).transformToChatPrompt(
        type: ModelType.functionGemma,
        fileType: ModelFileType.task,
      );

  group('FunctionGemma tool response', () {
    test('splays a dict into bare keys, not a JSON blob under `result`', () {
      expect(
        render({'status': 'ok', 'count': 2}),
        startsWith(
          '<start_function_response>response:get_weather'
          '{count:2,status:<escape>ok<escape>}<end_function_response>',
        ),
      );
    });

    test('keeps booleans, doubles and lists in their own types', () {
      expect(
        render({
          'ok': true,
          'ratio': 0.5,
          'items': ['a', 'b'],
        }),
        contains(
          '{items:[<escape>a<escape>,<escape>b<escape>],ok:true,ratio:0.5}',
        ),
      );
    });

    test('a single `value` key renders as the template\'s scalar form', () {
      expect(
        render({'value': 'sunny'}),
        contains('{value:<escape>sunny<escape>}'),
      );
    });

    test('never emits the invented `result` key', () {
      expect(render({'status': 'ok'}), isNot(contains('result:')));
    });

    test('continues the model turn instead of opening a new one', () {
      // The template renders call -> response -> answer inside one
      // `<start_of_turn>model`. Appending another header nested a turn the model
      // never saw. Verified on device: generation still fires without it.
      expect(
        render({'status': 'ok'}),
        equals(
          '<start_function_response>response:get_weather'
          '{status:<escape>ok<escape>}<end_function_response>',
        ),
      );
    });
  });
}
