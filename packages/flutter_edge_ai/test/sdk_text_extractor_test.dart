import 'package:flutter_edge_ai/src/parsing/sdk_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SdkTextExtractor.extractTextFromResponse', () {
    test('extracts text content items', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text",'
          '"text":"Hello"},{"type":"image","blob":"ignored"}]}';

      expect(SdkTextExtractor.extractTextFromResponse(raw), 'Hello');
    });

    test('preserves a web chunk with plain string content', () {
      const raw = '{"role":"assistant","content":"<|tool_call>call:ping{}"}';

      expect(
        SdkTextExtractor.extractTextFromResponse(raw),
        '<|tool_call>call:ping{}',
      );
    });

    test('extracts thinking channel before content', () {
      const raw =
          '{"role":"assistant","channels":{"thought":"checking"},'
          '"content":[{"type":"text","text":"answer"}]}';

      expect(
        SdkTextExtractor.extractTextFromResponse(raw),
        '<|channel>thought\nchecking<channel|>',
      );
    });

    test('a tool-call chunk is returned as its JSON', () {
      // Gemma 4 writes a sentence, then calls a tool in the same generation:
      // the call is its own chunk. InferenceChat leaves it out of the text
      // only when it handles calls; otherwise the app sees the JSON.
      const raw =
          '{"role":"assistant","tool_calls":[{"type":"function",'
          '"function":{"name":"runIntent","arguments":{"intent":"x"}}}]}';

      expect(SdkTextExtractor.extractTextFromResponse(raw), raw);
      expect(isSdkToolCallChunk(raw), isTrue);
    });

    test('isSdkToolCallChunk is true only for a call with no text', () {
      expect(
        isSdkToolCallChunk(
          '{"role":"assistant","content":[{"type":"text","text":"Sure."}]}',
        ),
        isFalse,
      );
      expect(
        isSdkToolCallChunk(
          '{"role":"assistant","content":[{"type":"text","text":"Sure."}],'
          '"tool_calls":[{"type":"function","function":{"name":"x"}}]}',
        ),
        isFalse,
      );
      expect(isSdkToolCallChunk('{"tool_calls": "x"}'), isFalse);
      expect(isSdkToolCallChunk('Sure, {not json'), isFalse);
      expect(isSdkToolCallChunk('{"tool_calls":[]'), isFalse);
    });

    test('text next to tool calls in one chunk is still text', () {
      const raw =
          '{"role":"assistant","content":[{"type":"text","text":"Sure."}],'
          '"tool_calls":[{"type":"function","function":{"name":"x"}}]}';

      expect(SdkTextExtractor.extractTextFromResponse(raw), 'Sure.');
    });

    test('passes through malformed or missing content chunks', () {
      expect(SdkTextExtractor.extractTextFromResponse('partial'), 'partial');
      expect(SdkTextExtractor.extractTextFromResponse('{}'), '{}');
    });

    test('rejects an unexpected content shape', () {
      expect(
        () => SdkTextExtractor.extractTextFromResponse('{"content":42}'),
        throwsStateError,
      );
    });
  });
}
