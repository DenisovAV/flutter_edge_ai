import 'package:flutter_edge_ai/core/chat.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Session stub that implements systemInstruction prepend logic,
/// mirroring MobileInferenceModelSession / WebModelSession behavior.
class _SessionWithInstruction implements InferenceModelSession {
  final List<Message> addedMessages = [];
  final String? systemInstruction;
  bool _systemInstructionSent = false;

  _SessionWithInstruction({this.systemInstruction});

  @override
  Future<void> addQueryChunk(Message message) async {
    var msg = message;
    if (message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty) {
      _systemInstructionSent = true;
      msg = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }
    addedMessages.add(msg);
  }

  @override
  Future<String> getResponse() async => 'stub response';

  @override
  Stream<String> getResponseAsync() => Stream.value('stub');

  @override
  Future<int> sizeInTokens(String text) async => text.length ~/ 4;

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

void main() {
  group('InferenceChat systemInstruction', () {
    late _SessionWithInstruction session;

    setUp(() {
      session = _SessionWithInstruction(
        systemInstruction: 'You are a helpful pirate.',
      );
    });

    test(
      'prepends system instruction to first user message for .task fileType',
      () async {
        final chat = InferenceChat(
          sessionCreator: () async => session,
          maxTokens: 1024,
          systemInstruction: 'You are a helpful pirate.',
          fileType: ModelFileType.task,
        );
        await chat.initSession();

        await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

        expect(session.addedMessages.length, 1);
        expect(
          session.addedMessages.first.text,
          contains('[System: You are a helpful pirate.]'),
        );
        expect(session.addedMessages.first.text, contains('Hello'));
      },
    );

    test('does NOT prepend system instruction to assistant messages', () async {
      final s = _SessionWithInstruction(systemInstruction: 'You are a pirate.');
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        systemInstruction: 'You are a pirate.',
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(
        const Message(text: 'Some response', isUser: false),
      );

      expect(s.addedMessages.length, 1);
      expect(s.addedMessages.first.text, 'Some response');
    });

    test('prepends only to the FIRST user message', () async {
      final s = _SessionWithInstruction(systemInstruction: 'Be concise.');
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        systemInstruction: 'Be concise.',
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'First', isUser: true));
      await chat.addQueryChunk(const Message(text: 'Second', isUser: true));

      expect(s.addedMessages.length, 2);
      expect(s.addedMessages[0].text, contains('[System: Be concise.]'));
      expect(s.addedMessages[1].text, 'Second');
    });

    test('does not prepend when systemInstruction is null', () async {
      final s = _SessionWithInstruction();
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(s.addedMessages.first.text, 'Hello');
    });

    test('does not prepend when systemInstruction is empty', () async {
      final s = _SessionWithInstruction(systemInstruction: '');
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        systemInstruction: '',
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(s.addedMessages.first.text, 'Hello');
    });

    test('clearHistory resets system instruction flag', () async {
      late _SessionWithInstruction currentSession;
      final chat = InferenceChat(
        sessionCreator: () async {
          currentSession = _SessionWithInstruction(
            systemInstruction: 'Be brief.',
          );
          return currentSession;
        },
        maxTokens: 1024,
        systemInstruction: 'Be brief.',
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'First', isUser: true));
      expect(
        currentSession.addedMessages.last.text,
        contains('[System: Be brief.]'),
      );

      await chat.clearHistory();

      await chat.addQueryChunk(
        const Message(text: 'After clear', isUser: true),
      );
      expect(
        currentSession.addedMessages.last.text,
        contains('[System: Be brief.]'),
      );
      expect(currentSession.addedMessages.last.text, contains('After clear'));
    });

    test('system instruction works together with tools prompt', () async {
      final s = _SessionWithInstruction(systemInstruction: 'Be a pirate.');
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        systemInstruction: 'Be a pirate.',
        fileType: ModelFileType.task,
        supportsFunctionCalls: true,
        tools: const [
          Tool(
            name: 'test',
            description: 'Test tool',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

      final sentText = s.addedMessages.first.text;
      // Both system instruction and tools prompt should be present
      expect(sentText, contains('[System: Be a pirate.]'));
      expect(sentText, contains('tool_code'));
    });

    // On non-web, non-desktop platforms, .litertlm still prepends
    // because _isNativeSystemInstruction checks platform.
    // In unit tests (which run on host), defaultTargetPlatform varies,
    // so we test .binary as a guaranteed-prepend fileType.
    test('prepends for .binary fileType (always MediaPipe fallback)', () async {
      final s = _SessionWithInstruction(
        systemInstruction: 'Respond in French.',
      );
      final chat = InferenceChat(
        sessionCreator: () async => s,
        maxTokens: 1024,
        systemInstruction: 'Respond in French.',
        fileType: ModelFileType.binary,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(
        s.addedMessages.first.text,
        contains('[System: Respond in French.]'),
      );
    });
  });

  group('Session systemInstruction', () {
    test('prepends to first user message (direct session call)', () async {
      final session = _SessionWithInstruction(
        systemInstruction: 'You are a helpful assistant.',
      );

      await session.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(session.addedMessages.length, 1);
      expect(
        session.addedMessages.first.text,
        contains('[System: You are a helpful assistant.]'),
      );
      expect(session.addedMessages.first.text, contains('Hello'));
    });

    test('does NOT prepend to assistant messages', () async {
      final session = _SessionWithInstruction(systemInstruction: 'Be concise.');

      await session.addQueryChunk(
        const Message(text: 'Model response', isUser: false),
      );

      expect(session.addedMessages.length, 1);
      expect(session.addedMessages.first.text, 'Model response');
    });

    test('prepends only to the FIRST user message', () async {
      final session = _SessionWithInstruction(systemInstruction: 'Be brief.');

      await session.addQueryChunk(const Message(text: 'First', isUser: true));
      await session.addQueryChunk(const Message(text: 'Second', isUser: true));

      expect(session.addedMessages.length, 2);
      expect(session.addedMessages[0].text, contains('[System: Be brief.]'));
      expect(session.addedMessages[1].text, 'Second');
    });

    test('null instruction → no prepend', () async {
      final session = _SessionWithInstruction();

      await session.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(session.addedMessages.first.text, 'Hello');
    });

    test('empty instruction → no prepend', () async {
      final session = _SessionWithInstruction(systemInstruction: '');

      await session.addQueryChunk(const Message(text: 'Hello', isUser: true));

      expect(session.addedMessages.first.text, 'Hello');
    });

    test('InferenceChat via session — no double prepend', () async {
      // When InferenceChat uses _SessionWithInstruction, the prepend happens
      // in the session. InferenceChat no longer does its own prepend.
      // Result: exactly ONE prepend, not two.
      late _SessionWithInstruction currentSession;
      final chat = InferenceChat(
        sessionCreator: () async {
          currentSession = _SessionWithInstruction(
            systemInstruction: 'Be helpful.',
          );
          return currentSession;
        },
        maxTokens: 1024,
        systemInstruction: 'Be helpful.',
        fileType: ModelFileType.task,
      );
      await chat.initSession();

      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));

      final text = currentSession.addedMessages.first.text;
      // Should contain [System: ...] exactly ONCE
      expect('[System: Be helpful.]'.allMatches(text).length, 1);
      expect(text, contains('Hi'));
    });
  });
}
