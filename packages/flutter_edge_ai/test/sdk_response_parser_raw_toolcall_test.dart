import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// On web, `@litert-lm/core` (0.12.1 / 0.14.0) does NOT convert Gemma 4
/// `<|tool_call>call:NAME{...}<tool_call|>` tokens into structured `tool_calls`
/// JSON — the tokens stay as raw text in the message content (verified on
/// hardware with Gemma 4 E4B). Native (C++ liblitert_lm) does the conversion,
/// so this raw-token fallback is only exercised on the web path.
void main() {
  group('SdkResponseParser raw <|tool_call> fallback', () {
    test('parses the raw web token E4B emits', () {
      // Exact string Gemma 4 E4B produced on web (@litert-lm/core 0.12.1).
      const raw =
          '<|tool_call>call:calculate-hash{text:<|"|>Hello<|"|>}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls, hasLength(1));
      expect(calls.first.name, 'calculate-hash');
      expect(calls.first.args, {'text': 'Hello'});
    });

    test(
      'parses a raw token without the closing <tool_call|> (stop cut off)',
      () {
        const raw = '<|tool_call>call:get-current-time{}';

        final calls = SdkResponseParser.extractToolCalls(raw);

        expect(calls, hasLength(1));
        expect(calls.first.name, 'get-current-time');
        expect(calls.first.args, isEmpty);
      },
    );

    test('parses multiple params in one raw call', () {
      const raw =
          '<|tool_call>call:send-email{to:<|"|>a@b.com<|"|>,subject:<|"|>Hi<|"|>}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls, hasLength(1));
      expect(calls.first.name, 'send-email');
      expect(calls.first.args, {'to': 'a@b.com', 'subject': 'Hi'});
    });

    test('structured JSON tool_calls still take precedence (native path)', () {
      // When the SDK already produced tool_calls JSON, the raw fallback must
      // not double-parse. This is the native/FFI shape.
      const json =
          '{"role":"assistant","tool_calls":[{"type":"function","function":'
          '{"name":"calculate-hash","arguments":{"text":"Hello"}}}]}';

      final calls = SdkResponseParser.extractToolCalls(json);

      expect(calls, hasLength(1));
      expect(calls.first.name, 'calculate-hash');
      expect(calls.first.args, {'text': 'Hello'});
    });

    test('parses the real web shape: token inside a stringified Message', () {
      // What actually reaches lastRawResponse on web: the JS Message object is
      // JSON.stringify'd, so the raw token lives inside a "content" string and
      // the `<|"|>` escape tokens are themselves JSON-escaped to `<|\"|>`.
      const raw =
          r'{"role":"assistant","content":"<|tool_call>call:calculate-hash'
          r'{text:<|\"|>Hello<|\"|>}<tool_call|>"}';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls, hasLength(1));
      expect(calls.first.name, 'calculate-hash');
      expect(calls.first.args, {'text': 'Hello'});
    });

    test('plain prose with no tool call returns empty', () {
      const raw = 'The hash of "hello" is a1b2c3d4.';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls, isEmpty);
    });
  });
}
