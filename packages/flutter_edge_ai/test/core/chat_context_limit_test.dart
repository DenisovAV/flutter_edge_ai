import 'dart:typed_data';
// A chat turn whose input the engine refused for the context window: the
// turn fails, its end is TurnEnd.contextLimit, and the messages staged for it
// are taken back out of the chat's history (the engine never added them to
// its context). Any other failure leaves the history as it is.
import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/chat.dart' show chatTurnErrorEndTimeout;
import 'package:flutter_test/flutter_test.dart';

/// A session whose next turn is scripted: [chunks], then [error] if set, and
/// an end of [end].
final class _Session extends InferenceModelSession {
  List<String> chunks = const ['OK'];
  Object? error;
  TurnEnd end = TurnEnd.endOfSequence;

  /// The text fails and then neither closes nor reports an end.
  bool hangAfterError = false;
  final staged = <String>[];

  @override
  EngineTurn startTurn() {
    final text = StreamController<String>();
    final done = Completer<TurnEnd>();
    () async {
      for (final c in chunks) {
        text.add(c);
      }
      final e = error;
      if (e != null) text.addError(e);
      if (hangAfterError) return;
      await text.close();
      done.complete(end);
    }();
    return EngineTurn(text: text.stream, end: done.future);
  }

  @override
  Future<String> getResponse() async => chunks.join();

  @override
  Stream<String> getResponseAsync() => Stream.fromIterable(chunks);

  @override
  Future<int> sizeInTokens(String text) async => 1;

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message.text);

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

void main() {
  late _Session session;
  late InferenceChat chat;

  setUp(() async {
    session = _Session();
    chat = InferenceChat(
      sessionCreator: () async => session,
      maxTokens: 4096,
      tokenBuffer: 256,
    );
    await chat.initSession();
    await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));
    await chat.generateChatResponse();
  });

  List<String> history() => [for (final m in chat.fullHistory) m.text];

  for (final streaming in [false, true]) {
    final path = streaming
        ? 'generateChatResponseAsync'
        : 'generateChatResponse';

    test('$path: a refused input fails the turn and is taken back out of the '
        'history', () async {
      expect(history(), ['Hello', 'OK']);
      await chat.addQueryChunk(const Message(text: 'too long', isUser: true));
      session
        ..chunks = const []
        ..error = Exception('the input does not fit (contextLimit)')
        ..end = TurnEnd.contextLimit;
      final turn = streaming
          ? chat.generateChatResponseAsync().drain<void>()
          : chat.generateChatResponse();
      await expectLater(turn, throwsA(isA<Exception>()));
      expect(history(), ['Hello', 'OK']);

      // The next turn runs on the history the model has.
      session
        ..chunks = const ['Fine']
        ..error = null
        ..end = TurnEnd.endOfSequence;
      await chat.addQueryChunk(const Message(text: 'short', isUser: true));
      await chat.generateChatResponse();
      expect(history(), ['Hello', 'OK', 'short', 'Fine']);
    });

    test('$path: any other failure keeps the staged message', () async {
      await chat.addQueryChunk(const Message(text: 'next', isUser: true));
      session
        ..chunks = const []
        ..error = Exception('native error')
        ..end = TurnEnd.endOfSequence;
      final turn = streaming
          ? chat.generateChatResponseAsync().drain<void>()
          : chat.generateChatResponse();
      await expectLater(turn, throwsA(isA<Exception>()));
      expect(history(), ['Hello', 'OK', 'next']);
    });
  }

  test('a turn that ends contextLimit without an error (the reply filled '
      'the window) keeps its message and its reply', () async {
    await chat.addQueryChunk(const Message(text: 'go on', isUser: true));
    session
      ..chunks = const ['cut']
      ..end = TurnEnd.contextLimit;
    await chat.generateChatResponse();
    expect(history(), ['Hello', 'OK', 'go on', 'cut']);
  });

  Future<void> refuseNext() async {
    session
      ..chunks = const []
      ..error = Exception('the input does not fit (contextLimit)')
      ..end = TurnEnd.contextLimit;
    await expectLater(chat.generateChatResponse(), throwsA(isA<Exception>()));
    session
      ..chunks = const ['OK']
      ..error = null
      ..end = TurnEnd.endOfSequence;
  }

  test('the token count of a refused image message is taken back', () async {
    final before = chat.currentTokens;
    await chat.addQueryChunk(
      Message.withImage(
        text: 'look',
        imageBytes: Uint8List.fromList([1, 2, 3]),
        isUser: true,
      ),
    );
    expect(chat.currentTokens, before + 257);
    await refuseNext();
    expect(chat.currentTokens, before);
  });

  test('a tools prompt staged with a refused message is sent again with the '
      'next one', () async {
    final tools = InferenceChat(
      sessionCreator: () async => session,
      maxTokens: 4096,
      tools: const [Tool(name: 'get_time', description: 'Returns the time.')],
      supportsFunctionCalls: true,
    );
    await tools.initSession();
    chat = tools;
    session.staged.clear();
    await chat.addQueryChunk(const Message(text: 'too long', isUser: true));
    final prompts = session.staged.length - 1;
    expect(prompts, greaterThan(0), reason: 'a tools prompt was staged');
    await refuseNext();
    session.staged.clear();
    await chat.addQueryChunk(const Message(text: 'short', isUser: true));
    expect(session.staged.length - 1, prompts, reason: 'the prompt again');
  });

  test('clearHistory forgets what was staged before it: a refusal after it '
      'takes back only its own message', () async {
    await chat.addQueryChunk(const Message(text: 'staged', isUser: true));
    await chat.clearHistory();
    await chat.addQueryChunk(const Message(text: 'too long', isUser: true));
    await refuseNext();
    expect(history(), isEmpty);
  });

  test('a failed text that never closes nor ends does not hold the turn: the '
      'error arrives after the bound, the history as it is', () async {
    final saved = chatTurnErrorEndTimeout;
    chatTurnErrorEndTimeout = const Duration(milliseconds: 50);
    addTearDown(() => chatTurnErrorEndTimeout = saved);
    await chat.addQueryChunk(const Message(text: 'next', isUser: true));
    session
      ..chunks = const []
      ..error = Exception('native error')
      ..end = TurnEnd.contextLimit
      ..hangAfterError = true;
    await expectLater(
      chat.generateChatResponse().timeout(const Duration(seconds: 5)),
      throwsA(isA<Exception>().having((e) => '$e', 'e', contains('native'))),
    );
    expect(history(), ['Hello', 'OK', 'next']);
  });
}
