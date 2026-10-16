import 'package:flutter_edge_ai/src/parsing/sdk_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gemma 4 `<|tool_call>call:NAME{...}<tool_call|>` tokens that reach Dart as
/// text. `@litert-lm/core` 0.12.1 and 0.14.0 left every call that way on web
/// (verified with Gemma 4 E4B). From 0.18.0 the web runtime, like native,
/// converts a complete call to `tool_calls` itself, so the fallback sees a
/// block the runtime did not convert (cut off or malformed) and history text
/// that carries the tokens.
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

  // Gemma 4's `format_argument` writes only strings between `<|"|>`: numbers,
  // booleans and null are bare, objects and lists nest.
  group('raw <|tool_call> arguments keep their types', () {
    test('a bare integer', () {
      const raw = '<|tool_call>call:set_volume{level:5}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.name, 'set_volume');
      expect(calls.single.args, {'level': 5});
    });

    test('booleans, a negative float and null', () {
      const raw =
          '<|tool_call>call:tune{gain:-0.5,muted:false,note:null,on:true}'
          '<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {
        'gain': -0.5,
        'muted': false,
        'note': null,
        'on': true,
      });
    });

    test('a nested object and a list', () {
      const raw =
          '<|tool_call>call:schedule{at:{hour:9,minute:30},'
          'days:[<|"|>mon<|"|>,<|"|>tue<|"|>]}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {
        'at': {'hour': 9, 'minute': 30},
        'days': ['mon', 'tue'],
      });
    });

    test('a string holding a brace and a comma, then a number', () {
      const raw = '<|tool_call>call:say{text:<|"|>a}, b<|"|>,n:2}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {'text': 'a}, b', 'n': 2});
    });

    test('trailing commas are read the same at every level', () {
      // The template never writes one; reading it loses nothing, and the top
      // level always accepted it.
      const raw = '<|tool_call>call:f{o:{a:1,},xs:[1,2,],}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {
        'o': {'a': 1},
        'xs': [1, 2],
      });
    });

    test('bare None reads as null, as the template writes it', () {
      // Gemma 4's `format_argument` renders null with `{{ argument }}`, which
      // is Python's `None`. A bare `null` reads the same.
      const raw = '<|tool_call>call:f{a:None,b:null}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {'a': null, 'b': null});
    });

    test('two calls in one response', () {
      const raw =
          '<|tool_call>call:set_volume{level:5}<tool_call|>'
          '<|tool_call>call:change_color{color:<|"|>red<|"|>}<tool_call|>';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.map((c) => c.name), ['set_volume', 'change_color']);
      expect(calls.map((c) => c.args), [
        {'level': 5},
        {'color': 'red'},
      ]);
    });

    test('a string with JSON escapes, inside a stringified message', () {
      const raw =
          r'{"role":"assistant","content":"<|tool_call>call:note'
          r'{n:2,text:<|\"|>say \"hi\"\nbye<|\"|>}<tool_call|>"}';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.args, {'n': 2, 'text': 'say "hi"\nbye'});
    });

    test('a call split across streamed message chunks', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text",'
          '"text":"<|tool_call>call:set_vol"}]}'
          '{"role":"assistant","content":[{"type":"text",'
          '"text":"ume{level:5}<tool_call|>"}]}';

      final calls = SdkResponseParser.extractToolCalls(raw);

      expect(calls.single.name, 'set_volume');
      expect(calls.single.args, {'level': 5});
    });

    test('a string that never closes refuses the call, not truncated', () {
      // A partial call would fire the tool with the arguments read so far.
      const raw =
          '<|tool_call>call:send{to:<|"|>a@b.c<|"|>,body:<|"|>hi}<tool_call|>';

      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });

    test('one malformed call refuses the response, not just that call', () {
      // Balanced braces, so the call is found, but its list never closes.
      const raw =
          '<|tool_call>call:set_volume{level:5}<tool_call|>'
          '<|tool_call>call:pick{ids:[1,2}<tool_call|>';

      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });

    test('a call that never closes refuses the response', () {
      const raw =
          '<|tool_call>call:set_volume{level:5}<tool_call|>'
          '<|tool_call>call:say{text:<|"|>never closed}<tool_call|>';

      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });

    test('an empty bare value is refused, not read as an empty string', () {
      // An empty string is written `<|"|><|"|>`; nothing renders a bare one.
      expect(
        SdkResponseParser.extractToolCalls(
          '<|tool_call>call:f{a:,b:1}<tool_call|>',
        ),
        isEmpty,
      );
      expect(
        SdkResponseParser.extractToolCalls('<|tool_call>call:f{a:}'),
        isEmpty,
      );
      expect(
        SdkResponseParser.extractToolCalls(
          '<|tool_call>call:f{xs:[1,,2]}<tool_call|>',
        ),
        isEmpty,
      );
    });

    test('a bare value holding an escape or a control token is refused', () {
      // A string that lost its opening escape, and a token from the next
      // turn: neither is a value the template writes.
      expect(
        SdkResponseParser.extractToolCalls(
          '<|tool_call>call:f{a:b<|"|>c<|"|>}<tool_call|>',
        ),
        isEmpty,
      );
      expect(
        SdkResponseParser.extractToolCalls(
          '<|tool_call>call:f{a:ok<|tool_response>}<tool_call|>',
        ),
        isEmpty,
      );
    });

    test('a call inside a thought channel is not run', () {
      // A response whose fragments carry no content has no text to read: the
      // raw JSON around the thought is not the answer.
      const raw =
          '{"role":"assistant","channels":{"thought":'
          '"<|tool_call>call:set_volume{level:5}<tool_call|>"}}';

      expect(SdkResponseParser.extractToolCalls(raw), isEmpty);
    });
  });
}
