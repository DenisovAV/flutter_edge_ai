import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// FunctionGemma's call only reaches `tool_calls` when the runtime parses it.
/// The web SDK, and a `.litertlm` exported without the function_gemma model
/// type, hand it back as text; [SdkResponseParser.extractToolCalls] then reads
/// the wire format the model wrote.
void main() {
  group('SdkResponseParser.extractToolCalls — FunctionGemma text fallback', () {
    test('a call inside a text content item', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text","text":'
          '"<start_function_call>call:multiply{a:1234,b:5678}<end_function_call>"}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.single.name, 'multiply');
      expect(calls.single.args, {'a': 1234, 'b': 5678});
    });

    test('a call split across streamed chunks', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text","text":'
          '"<start_function_call>call:show_alert{title:<escape>Test"}]}'
          '{"role":"assistant","content":[{"type":"text","text":'
          '"<escape>,message:<escape>Hello<escape>}<end_function_call>"}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls.single.name, 'show_alert');
      expect(calls.single.args, {'title': 'Test', 'message': 'Hello'});
    });

    test('a web chunk whose content is a plain string', () {
      const raw =
          '{"role":"assistant","content":'
          '"<start_function_call>call:get_time{}<end_function_call>"}';
      expect(SdkResponseParser.extractToolCalls(raw).single.name, 'get_time');
    });

    test('structured tool_calls are taken as they are', () {
      const raw =
          '{"role":"assistant","tool_calls":[{"type":"function","function":'
          '{"name":"multiply","arguments":{"a":1234.0,"b":5678.0}}}]}';
      final calls = SdkResponseParser.extractToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.single.args, {'a': 1234.0, 'b': 5678.0});
    });

    test('an answer in plain text is not a call', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text","text":'
          '"The product of 1234 times 5678 is 7006652."}]}';
      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });
  });
}
