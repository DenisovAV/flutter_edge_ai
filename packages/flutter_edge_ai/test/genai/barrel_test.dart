import 'package:flutter_edge_ai/genai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('genai barrel re-exports genai_primitives core types', () {
    final msg = ChatMessage.user('hello');
    expect(msg.role, ChatMessageRole.user);
    expect(msg.parts.whereType<TextPart>().first.text, 'hello');
  });
}
