import 'package:flutter_edge_ai/core/parsing/sdk_text_extractor.dart';
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
