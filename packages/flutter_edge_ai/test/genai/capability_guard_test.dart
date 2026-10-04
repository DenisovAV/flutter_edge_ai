import 'dart:typed_data';
import 'package:flutter_edge_ai/core/genai/genai_input_converter.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('image on a non-vision chat throws', () {
    final msgs = [
      Message.withImage(
        text: 'x',
        imageBytes: Uint8List.fromList([1]),
        isUser: true,
      ),
    ];
    expect(
      () => assertMessagesFitChat(
        msgs,
        supportImage: false,
        supportAudio: true,
        supportsFunctionCalls: true,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('audio on a non-audio chat throws', () {
    final msgs = [
      Message.withAudio(
        text: 'x',
        audioBytes: Uint8List.fromList([1]),
        isUser: true,
      ),
    ];
    expect(
      () => assertMessagesFitChat(
        msgs,
        supportImage: true,
        supportAudio: false,
        supportsFunctionCalls: true,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('a tool call on a non-function-call chat throws', () {
    // The guard's third branch (named for tools) — an unguarded tool call/result
    // would be silently dropped by an engine built without function support.
    final msgs = [Message.toolCall(text: '{"name":"calc","parameters":{}}')];
    expect(
      () => assertMessagesFitChat(
        msgs,
        supportImage: true,
        supportAudio: true,
        supportsFunctionCalls: false,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('a tool response on a non-function-call chat throws', () {
    final msgs = [
      Message.toolResponse(toolName: 'calc', response: {'v': 7}),
    ];
    expect(
      () => assertMessagesFitChat(
        msgs,
        supportImage: true,
        supportAudio: true,
        supportsFunctionCalls: false,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('capable chat passes', () {
    final msgs = [Message(text: 'x', isUser: true)];
    assertMessagesFitChat(
      msgs,
      supportImage: true,
      supportAudio: true,
      supportsFunctionCalls: true,
    );
  });
}
