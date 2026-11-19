// The runtime's copy of the response-chunk text reader must answer as core's
// `SdkTextExtractor`, which the web engine uses, on every chunk shape.

import 'package:flutter_edge_ai/engine.dart' show SdkTextExtractor;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chunks = [
    'not json',
    '{"content":"plain"}',
    '{"content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]}',
    '{"content":[]}',
    '{"channels":{"thought":"thinking"},"content":"x"}',
    '{"channels":{"thought":""},"content":"x"}',
    '{"role":"assistant"}',
    '{"tool_calls":[{"function":{"name":"f","arguments":{}}}]}',
  ];

  for (final chunk in chunks) {
    test('agrees with core on $chunk', () {
      expect(
        extractResponseText(chunk),
        SdkTextExtractor.extractTextFromResponse(chunk),
      );
    });
  }

  test('a content of another type is a StateError in both', () {
    const chunk = '{"content":42}';
    expect(() => extractResponseText(chunk), throwsStateError);
    expect(
      () => SdkTextExtractor.extractTextFromResponse(chunk),
      throwsStateError,
    );
  });
}
