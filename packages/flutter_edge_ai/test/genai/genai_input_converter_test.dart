import 'dart:typed_data';
import 'package:flutter_edge_ai/genai.dart';
import 'package:flutter_edge_ai/core/genai/genai_input_converter.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('user text → one user Message', () async {
    final out = await messagesFromChatMessage(ChatMessage.user('hi'));
    expect(out, hasLength(1));
    expect(out.first.text, 'hi');
    expect(out.first.isUser, isTrue);
  });

  test(
    'user text + two image DataParts → one Message with both images',
    () async {
      final a = Uint8List.fromList([1]);
      final b = Uint8List.fromList([2]);
      final msg = ChatMessage.user(
        'look',
        parts: [
          TextPart('look'),
          DataPart(a, mimeType: 'image/png'),
          DataPart(b, mimeType: 'image/png'),
        ],
      );
      final out = await messagesFromChatMessage(msg);
      expect(out, hasLength(1));
      expect(out.first.images, [a, b]);
    },
  );

  test('model role → non-user Message', () async {
    final out = await messagesFromChatMessage(ChatMessage.model('ok'));
    expect(out.single.isUser, isFalse);
  });

  test('system role throws', () async {
    expect(
      () => messagesFromChatMessage(ChatMessage.system('sys')),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a model-turn ThinkingPart is stripped, sibling parts are kept', () async {
    // Gemma strips prior-turn thoughts from history; feeding a returned model
    // turn (which carries its ThinkingPart) back must not throw — drop the
    // thought, keep the answer. See genai_output_converter emitting ThinkingPart.
    final msg = ChatMessage(
      role: ChatMessageRole.model,
      parts: [const ThinkingPart('secret reasoning'), TextPart('final answer')],
    );
    final out = await messagesFromChatMessage(msg);
    expect(out, hasLength(1));
    expect(out.single.text, 'final answer');
    expect(out.single.isUser, isFalse);
  });

  test('a pure-thought model turn yields no staged Message', () async {
    final msg = ChatMessage(
      role: ChatMessageRole.model,
      parts: [const ThinkingPart('t')],
    );
    expect(await messagesFromChatMessage(msg), isEmpty);
  });

  test('a user-role ThinkingPart throws (thoughts are model output)', () async {
    // Stripping is only right for a returned model turn's history. A user
    // constructing a thought is misuse — fail loud, don't stage nothing.
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [const ThinkingPart('t'), TextPart('hi')],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('model-role tool call → Message.toolCall (round-trip)', () async {
    // The valid path generateContent relies on: the output converter emits a
    // model turn carrying a ToolPart.call, which must stage back as a
    // Message.toolCall whose JSON carries name + parameters.
    final msg = ChatMessage(
      role: ChatMessageRole.model,
      parts: [
        ToolPart.call(callId: 'calc', toolName: 'calc', arguments: {'a': 1}),
      ],
    );
    final out = await messagesFromChatMessage(msg);
    expect(out.single.type, MessageType.toolCall);
    expect(out.single.text, contains('calc'));
    expect(out.single.text, contains('"parameters"'));
  });

  test('single audio DataPart → Message with audioBytes set', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [DataPart(bytes, mimeType: 'audio/wav')],
    );
    final out = await messagesFromChatMessage(msg);
    expect(out.single.audioBytes, bytes);
    expect(out.single.images, isEmpty);
  });

  test('a user turn that stages nothing (lone empty TextPart) throws', () async {
    // Passes the parts.isEmpty guard but reduces to zero staged content — must
    // fail loud rather than silently generate on stale context.
    final msg = ChatMessage(role: ChatMessageRole.user, parts: [TextPart('')]);
    expect(() => messagesFromChatMessage(msg), throwsA(isA<ArgumentError>()));
  });

  test('tool result → Message.toolResponse', () async {
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [
        ToolPart.result(callId: '1', toolName: 'calc', result: {'v': 7}),
      ],
    );
    final out = await messagesFromChatMessage(msg);
    expect(out.single.type, MessageType.toolResponse);
    expect(out.single.toolName, 'calc');
  });

  test('a tool result on a model-role message throws', () async {
    // A tool result is caller/user input, not model output — mirror the
    // tool-call-on-user guard rather than silently accepting it.
    final msg = ChatMessage(
      role: ChatMessageRole.model,
      parts: [
        ToolPart.result(callId: '1', toolName: 'calc', result: {'v': 7}),
      ],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('second audio DataPart throws', () async {
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [
        DataPart(Uint8List.fromList([1]), mimeType: 'audio/wav'),
        DataPart(Uint8List.fromList([2]), mimeType: 'audio/wav'),
      ],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('empty parts throws', () async {
    final msg = ChatMessage(role: ChatMessageRole.user, parts: const []);
    expect(() => messagesFromChatMessage(msg), throwsA(isA<ArgumentError>()));
  });

  test('tool call in a user-role message throws', () async {
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [
        ToolPart.call(callId: '1', toolName: 'calc', arguments: {'a': 1}),
      ],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('non-media DataPart mime throws', () async {
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [
        DataPart(Uint8List.fromList([1, 2]), mimeType: 'application/pdf'),
      ],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('LinkPart throws — inference layer does not fetch URLs', () async {
    // The on-device model needs bytes; resolving links (network/file I/O) is a
    // caller/agent-layer concern, not core inference. Must throw, not fetch.
    final msg = ChatMessage(
      role: ChatMessageRole.user,
      parts: [LinkPart(Uri.parse('https://example.com/cat.png'))],
    );
    expect(
      () => messagesFromChatMessage(msg),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
