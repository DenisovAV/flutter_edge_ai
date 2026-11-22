// How InferenceChat counts the tokens it holds and when it trims (#821): the
// user's text and every image are counted, the same figure is taken off when
// a message is dropped, and a message that would reach the limit trims before
// it is sent. One token per character, so every number below is a length.
// Turns run streamed: that is the path that counts a reply.
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
  final staged = <Message>[];
  int sizeCalls = 0;

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
    sizeCalls++;
    return text.length;
  }

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message);

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

/// A chat over [_Session]s that all answer [reply]; [sessions] lists them in
/// the order the chat opened them.
Future<(InferenceChat, List<_Session>)> _chat({
  required int maxTokens,
  String reply = 'bb',
  ChatTurnHooks? hooks,
  List<Tool> tools = const [],
}) async {
  final sessions = <_Session>[];
  final chat = InferenceChat(
    sessionCreator: () async {
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
    final (chat, sessions) = await _chat(maxTokens: 20);
    await chat.addQuery(const Message(text: 'aa', isUser: true));
    await _reply(chat); // 'bb': 4 of 20
    final queued = 'c' * 15;
    await chat.addQueryChunk(Message(text: queued, isUser: true)); // 19
    // 5 more reach 24: 'aa' and 'bb' go, which leaves 20, still at the
    // limit; the queued chunk stays all the same.
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
}

/// Hooks that queue a message the engine's way, as llama's do.
final class _QueueHooks extends ChatTurnHooks {
  @override
  Future<void>? addQueryChunk(InferenceModelSession session, Message message) =>
      Future.value();
}
