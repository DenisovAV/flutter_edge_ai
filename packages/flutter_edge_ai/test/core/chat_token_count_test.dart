// How InferenceChat counts the tokens it holds and when it trims (#821): the
// user's text and every image are counted, the same figure is taken off when
// a message is dropped, and a message that would reach the limit trims before
// it is sent. One token per character, so every number below is a length.
// Turns run streamed unless a test says otherwise.
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

final _image = Uint8List.fromList([1, 2, 3]);

/// A session that counts one token per character and records what it gets.
final class _Session extends InferenceModelSession {
  _Session(this.reply);

  /// What the next turn answers.
  String reply;

  /// When set, the next turn fails with it before any text.
  Object? failWith;

  /// When it returns true for a text, sizeInTokens fails on it.
  bool Function(String text)? sizeFails;
  final staged = <Message>[];
  int sizeCalls = 0;
  bool closed = false;

  void _checkOpen() {
    if (closed) throw StateError('session closed');
  }

  @override
  EngineTurn startTurn() {
    final failure = failWith;
    failWith = null;
    return EngineTurn(
      text: failure == null
          ? Stream.value(reply)
          : Stream<String>.error(failure),
      end: null,
    );
  }

  @override
  Stream<String> getResponseAsync() => startTurn().text;

  @override
  Future<String> getResponse() => getResponseAsync().join();

  @override
  Future<int> sizeInTokens(String text) async {
    _checkOpen();
    sizeCalls++;
    if (sizeFails?.call(text) ?? false) throw StateError('count failed');
    return text.length;
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    _checkOpen();
    staged.add(message);
  }

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async => closed = true;
}

/// When set, the chats' sessionCreator throws it.
Object? _createFails;

/// A chat over [_Session]s that all answer [reply]; [sessions] lists them in
/// the order the chat opened them.
Future<(InferenceChat, List<_Session>)> _chat({
  required int maxTokens,
  String reply = 'bb',
  ChatTurnHooks? hooks,
  List<Tool> tools = const [],
  ModelType modelType = ModelType.gemmaIt,
}) async {
  _createFails = null;
  final sessions = <_Session>[];
  final chat = InferenceChat(
    sessionCreator: () async {
      if (_createFails case final error?) throw error;
      final s = _Session(reply);
      sessions.add(s);
      return s;
    },
    maxTokens: maxTokens,
    tokenBuffer: 0,
    supportImage: true,
    supportsFunctionCalls: tools.isNotEmpty,
    tools: tools,
    turnHooks: hooks,
    modelType: modelType,
  );
  await chat.initSession();
  return (chat, sessions);
}

/// One streamed turn, the path that counts the reply; its text.
Future<String> _reply(InferenceChat chat) async => [
  await for (final r in chat.generateChatResponseAsync())
    if (r is TextResponse) r.token,
].join();

List<String> _texts(_Session s) => [for (final m in s.staged) m.text];

void main() {
  test('the user\'s text is counted when it is queued', () async {
    final (chat, _) = await _chat(maxTokens: 1024);
    await chat.addQuery(const Message(text: 'hello', isUser: true));
    expect(chat.currentTokens, 5);
    await _reply(chat);
    expect(chat.currentTokens, 5 + 2, reason: 'and the reply after it');
  });

  test('every image is counted, read as the engines read them', () async {
    for (final (message, want) in [
      (Message(text: '', images: [_image, _image], isUser: true), 514),
      (Message(text: '', imageBytes: _image, isUser: true), 257),
      // images, when set, are the message's images; imageBytes is not added.
      (
        Message(text: '', imageBytes: _image, images: [_image], isUser: true),
        257,
      ),
      (Message(text: 'ab', images: [_image], isUser: true), 2 + 257),
    ]) {
      final (chat, _) = await _chat(maxTokens: 1024);
      await chat.addQuery(message);
      expect(chat.currentTokens, want, reason: '$message');
    }
  });

  test('the tools prompt is counted once, when it is sent', () async {
    const tool = Tool(name: 'get_time', description: 'Tells the time');
    final (chat, _) = await _chat(maxTokens: 100000, tools: [tool]);
    await chat.addQuery(const Message(text: 'hi', isUser: true));
    expect(chat.currentTokens, chat.createToolsPrompt().length + 2);
  });

  test('a message that would reach the limit trims before it is sent, and a '
      'dropped message takes off what it added', () async {
    // 'a' and its image (258) and the reply 'bb' (2) hold 260 of 300.
    final (chat, sessions) = await _chat(maxTokens: 300);
    await chat.addQuery(Message(text: 'a', imageBytes: _image, isUser: true));
    await _reply(chat);
    expect(chat.currentTokens, 260);

    // 40 more reach 300: the first message is dropped before this one is
    // sent, image included, and the reply is kept.
    final long = 'c' * 40;
    await chat.addQuery(Message(text: long, isUser: true));
    expect(sessions, hasLength(2));
    expect(_texts(sessions.first), [
      'a',
    ], reason: 'the old session never got it');
    expect(_texts(sessions.last), ['bb', long]);
    expect(chat.currentTokens, 2 + 40);
    expect(chat.fullHistory, hasLength(3), reason: 'fullHistory keeps all');
  });

  test('the trim after a reply takes off the same figure', () async {
    // 'a' + image (258), reply 'bb' (2): 260 reaches 260, so the first
    // message is dropped; what is left is the reply alone.
    final (chat, sessions) = await _chat(maxTokens: 260);
    await chat.addQuery(Message(text: 'a', imageBytes: _image, isUser: true));
    await _reply(chat);
    expect(sessions, hasLength(2));
    expect(_texts(sessions.last), ['bb']);
    expect(chat.currentTokens, 2);
  });

  test('messages queued for the coming turn are never dropped, and a failed '
      'turn after the trim takes back exactly its own', () async {
    final (chat, sessions) = await _chat(maxTokens: 21);
    await chat.addQuery(const Message(text: 'aa', isUser: true));
    await _reply(chat); // 'bb': 4 of 21
    final queued = 'c' * 15;
    await chat.addQueryChunk(Message(text: queued, isUser: true)); // 19
    // 5 more reach 24: dropping 'aa' leaves 22, still at the limit, so 'bb'
    // goes too; the queued chunk, which would have gone next, stays.
    await chat.addQueryChunk(const Message(text: 'ddddd', isUser: true));
    expect(_texts(sessions.last), [queued, 'ddddd']);
    expect(chat.currentTokens, 20);

    sessions.last.failWith = StateError('engine failed');
    await expectLater(_reply(chat), throwsStateError);
    // Taken back to before the two chunks: the trim took 'aa' and 'bb' from
    // the model's history, fullHistory still has them.
    expect(chat.currentTokens, 0);
    expect([for (final m in chat.fullHistory) m.text], ['aa', 'bb']);

    // The next turn goes out on its own.
    await chat.addQuery(const Message(text: 'e', isUser: true));
    expect(await _reply(chat), 'bb');
    expect(chat.currentTokens, 1 + 2);
  });

  test('a chat whose engine queues messages itself is not counted', () async {
    final (chat, sessions) = await _chat(maxTokens: 2, hooks: _QueueHooks());
    await chat.addQuery(const Message(text: 'hello', isUser: true));
    expect(sessions.single.sizeCalls, 0);
    expect(sessions.single.staged, isEmpty);
    expect(chat.currentTokens, 0);
  });

  test(
    'the blocking path counts its reply, and the next message trims',
    () async {
      final (chat, sessions) = await _chat(maxTokens: 20);
      final q = 'q' * 4;
      for (var i = 0; i < 3; i++) {
        await chat.addQuery(Message(text: q, isUser: true));
        await chat.generateChatResponse();
      }
      // Three questions (4) and three replies (2).
      expect(chat.currentTokens, 18);
      expect(sessions, hasLength(1));

      // 4 more reach 22: the first question goes before this one is sent.
      await chat.addQuery(Message(text: q, isUser: true));
      expect(sessions, hasLength(2));
      expect(_texts(sessions.last), ['bb', q, 'bb', q, 'bb', q]);
      expect(chat.currentTokens, 18);
    },
  );

  test('a message that cannot fit drops nothing; the engine refuses it and '
      'the history stays', () async {
    final (chat, sessions) = await _chat(maxTokens: 30);
    await chat.addQuery(Message(text: 'a' * 10, isUser: true));
    await _reply(chat); // 12 of 30
    // 40 over a limit of 30: dropping all 12 would still not make room.
    await chat.addQuery(Message(text: 'x' * 40, isUser: true));
    expect(sessions, hasLength(1));
    expect(_texts(sessions.single), ['a' * 10, 'x' * 40]);
    expect(chat.currentTokens, 52);

    sessions.single.failWith = const ContextLimitException('too long');
    await expectLater(_reply(chat), throwsA(isA<ContextLimitException>()));
    expect(chat.currentTokens, 12);
    expect([for (final m in chat.fullHistory) m.text], ['a' * 10, 'bb']);
  });

  test('nor does it drop messages queued for the turn to make room', () async {
    final (chat, sessions) = await _chat(maxTokens: 20);
    await chat.addQuery(const Message(text: 'aa', isUser: true));
    await _reply(chat); // 4 of 20
    final queued = 'c' * 15;
    await chat.addQueryChunk(Message(text: queued, isUser: true)); // 19
    // 24: dropping 'aa' and 'bb' leaves 20, still at the limit; only the
    // queued chunk would make room, and it stays.
    await chat.addQueryChunk(const Message(text: 'ddddd', isUser: true));
    expect(sessions, hasLength(1));
    expect(chat.currentTokens, 24);
  });

  test('a replayed history can be trimmed, and a failed turn after it takes '
      'back only its own message', () async {
    final (chat, sessions) = await _chat(maxTokens: 30);
    final replay = [
      for (var i = 0; i < 6; i++) ...[
        const Message(text: 'uuuu', isUser: true),
        const Message(text: 'mm'),
      ],
    ];
    await chat.clearHistory(replayHistory: replay); // 36 of 30
    expect(chat.currentTokens, 36);
    final replayed = sessions.length;

    await chat.addQuery(const Message(text: 'z', isUser: true));
    expect(sessions, hasLength(replayed + 1), reason: 'trimmed before z');
    // 'uuuu', 'mm', 'uuuu' dropped: 26 left, then 'z'.
    expect(chat.currentTokens, 27);

    sessions.last.failWith = StateError('engine failed');
    await expectLater(_reply(chat), throwsStateError);
    expect(chat.currentTokens, 26);
    expect(chat.fullHistory, hasLength(12));
  });

  test('a tool response never loses the call it answers', () async {
    const call = FunctionCallResponse(name: 'get_time', args: {});
    final callMessage = Message.toolCall(text: 'c' * 10, calls: const [call]);
    final response = Message.toolResponse(
      toolName: 'get_time',
      response: {'r': 'x' * 30},
    );
    final (chat, sessions) = await _chat(maxTokens: 40);
    await chat.clearHistory(
      replayHistory: [
        Message(text: 'u' * 10, isUser: true),
        callMessage,
      ],
    ); // 20 of 40
    final replayed = sessions.length;
    // 20 + 38 reach 58: dropping the question leaves 48, over the limit, and
    // the call it would take next is the one being answered: nothing goes.
    await chat.addQueryChunk(response);
    expect(sessions, hasLength(replayed));
    expect(sessions.last.staged.last, same(response));
    expect(
      sessions.last.staged[sessions.last.staged.length - 2].type,
      MessageType.toolCall,
    );
  });

  test('nor the call an earlier response already answered', () async {
    // Two calls, one answered: the second response must find the call too.
    const first = FunctionCallResponse(name: 'a', args: {});
    const second = FunctionCallResponse(name: 'b', args: {});
    final (chat, sessions) = await _chat(maxTokens: 40);
    await chat.clearHistory(
      replayHistory: [
        Message(text: 'u' * 10, isUser: true),
        Message.toolCall(text: 'c' * 10, calls: const [first, second]),
        Message.toolResponse(toolName: 'a', response: {'r': 'x'}),
      ],
    ); // 10 + 10 + 9 = 29 of 40
    final replayed = sessions.length;
    final answer = Message.toolResponse(
      toolName: 'b',
      response: {'r': 'y' * 20},
    );
    // 29 + 28 reach 57: dropping the question leaves 47, over the limit, and
    // the call with its first response is all that is left to drop.
    await chat.addQueryChunk(answer);
    expect(sessions, hasLength(replayed));
    expect(sessions.last.staged.last, same(answer));
  });

  test('a trim drops a tool call together with its responses', () async {
    const call = FunctionCallResponse(name: 'get_time', args: {});
    final (chat, sessions) = await _chat(maxTokens: 30);
    await chat.clearHistory(
      replayHistory: [
        Message(text: 'u' * 5, isUser: true),
        Message.toolCall(text: 'c' * 5, calls: const [call]),
        Message.toolResponse(toolName: 'get_time', response: {'r': 'x'}),
        Message(text: 'v' * 5, isUser: true),
        const Message(text: 'bb'),
      ],
    ); // 5 + 5 + 9 + 5 + 2 = 26 of 30
    final w = 'w' * 12;
    await chat.addQuery(Message(text: w, isUser: true));
    // Dropping 'uuuuu' leaves 33 with 'w'; the call and its response go
    // together, which leaves 19: the rebuilt session starts with no orphan.
    expect(_texts(sessions.last), ['v' * 5, 'bb', w]);
    expect(chat.currentTokens, 19);
  });

  test('the tools prompt is sized before anything is sent', () async {
    const tool = Tool(name: 'get_time', description: 'Tells the time');
    final (chat, sessions) = await _chat(maxTokens: 100000, tools: [tool]);
    final prompt = chat.createToolsPrompt();
    sessions.single.sizeFails = (text) => text == prompt;
    await expectLater(
      chat.addQuery(const Message(text: 'hi', isUser: true)),
      throwsStateError,
    );
    expect(sessions.single.staged, isEmpty, reason: 'nothing was sent');
    expect(chat.currentTokens, 0);

    sessions.single.sizeFails = null;
    await chat.addQuery(const Message(text: 'hi', isUser: true));
    expect(_texts(sessions.single), [prompt, 'hi']);
    expect(chat.currentTokens, prompt.length + 2);
  });

  test('the tools prompt going out with a message counts toward the room '
      'that message needs', () async {
    const tool = Tool(name: 'get_time', description: 'Tells the time');
    final probe = InferenceChat(
      sessionCreator: null,
      maxTokens: 1,
      supportsFunctionCalls: true,
      tools: [tool],
    );
    final p = probe.createToolsPrompt().length;
    // A replayed model message (10) and room for p + 11: 'hi' (2) alone
    // fits, with the prompt sent before it (p) it does not.
    final (chat, sessions) = await _chat(maxTokens: p + 11, tools: [tool]);
    await chat.clearHistory(replayHistory: [Message(text: 'm' * 10)]);
    final replayed = sessions.length;
    await chat.addQuery(const Message(text: 'hi', isUser: true));
    expect(sessions, hasLength(replayed + 1));
    expect(_texts(sessions.last), [chat.createToolsPrompt(), 'hi']);
    expect(chat.currentTokens, p + 2);
  });

  test(
    'Qwen3\'s /no_think is counted, and taken off with its message',
    () async {
      final (chat, sessions) = await _chat(
        maxTokens: 20,
        modelType: ModelType.qwen3,
      );
      await chat.addQuery(const Message(text: 'hi', isUser: true));
      expect(chat.currentTokens, 'hi /no_think'.length);
      await _reply(chat); // 14 of 20
      await chat.addQuery(const Message(text: 'yo', isUser: true));
      // 26: 'hi /no_think' goes; 'bb' and 'yo /no_think' are left.
      expect(_texts(sessions.last), ['bb', 'yo /no_think']);
      expect(chat.currentTokens, 2 + 12);
    },
  );

  test('a session that keeps the transcript is not trimmed by core', () async {
    final (chat, sessions) = await _chat(
      maxTokens: 5,
      hooks: _TranscriptHooks(),
    );
    await chat.clearHistory(
      replayHistory: [const Message(text: 'aaaa', isUser: true)],
    );
    final replayed = sessions.length;
    await chat.addQuery(const Message(text: 'bbbb', isUser: true)); // 8 of 5
    expect(sessions, hasLength(replayed));
  });

  test('a count that fails inside the trim changes nothing', () async {
    final (chat, sessions) = await _chat(maxTokens: 10);
    await chat.addQuery(const Message(text: 'aa', isUser: true));
    await _reply(chat); // 4 of 10
    sessions.single.sizeFails = (text) => text == 'aa';
    final x = 'x' * 7;
    await expectLater(
      chat.addQuery(Message(text: x, isUser: true)),
      throwsStateError,
    );
    expect(sessions, hasLength(1));
    expect(chat.currentTokens, 4);

    sessions.single.sizeFails = null;
    await chat.addQuery(Message(text: x, isUser: true));
    expect(_texts(sessions.last), ['bb', x]);
    expect(chat.currentTokens, 2 + 7);
  });

  test('a rebuild that fails in the trim is thrown by every later call, '
      'until clearHistory', () async {
    final (chat, _) = await _chat(maxTokens: 10);
    await chat.addQuery(const Message(text: 'aa', isUser: true));
    await _reply(chat); // 4 of 10
    final failure = StateError('no session');
    _createFails = failure;
    await expectLater(
      chat.addQuery(Message(text: 'x' * 7, isUser: true)),
      throwsA(same(failure)),
    );
    _createFails = null;
    await expectLater(
      chat.addQuery(const Message(text: 'y', isUser: true)),
      throwsA(same(failure)),
      reason: 'not the closed session\'s error',
    );
    await chat.clearHistory();
    await chat.addQuery(const Message(text: 'y', isUser: true));
    expect(chat.currentTokens, 1);
  });
}

/// Hooks that queue a message the engine's way, as llama's do.
final class _QueueHooks extends ChatTurnHooks {
  @override
  Future<void>? addQueryChunk(InferenceModelSession session, Message message) =>
      Future.value();
}

/// Hooks for a session that keeps the transcript itself; core still queues
/// the messages.
final class _TranscriptHooks extends ChatTurnHooks {
  @override
  List<Message>? history(InferenceModelSession session) => const [];
}
