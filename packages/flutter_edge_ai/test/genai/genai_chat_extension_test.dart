import 'package:flutter_edge_ai/genai.dart';
import 'package:flutter_edge_ai/core/genai/genai_chat_extension.dart';
import 'package:flutter_test/flutter_test.dart';

// This suite verifies the guard behavior that needs no live engine.
void main() {
  test('sendMessage rejects a model-role ChatMessage', () async {
    // Uses the top-level guard the extension calls; see rejectModelRole.
    expect(
      () => rejectModelRole(ChatMessage.model('echo')),
      throwsA(isA<ArgumentError>()),
    );
    // A user message passes the guard (no throw).
    rejectModelRole(ChatMessage.user('hi'));
  });
}
