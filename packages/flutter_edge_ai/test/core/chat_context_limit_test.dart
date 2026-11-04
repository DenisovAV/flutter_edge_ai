// A chat turn whose input the engine refused for the context window: the
// turn fails, its end is TurnEnd.contextLimit, and the messages staged for it
// are taken back out of the chat's history (the engine never added them to
// its context). Any other failure leaves the history as it is.
import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session whose next turn is scripted: [chunks], then [error] if set, and
/// an end of [end].
final class _Session extends InferenceModelSession {
  List<String> chunks = const ['OK'];
  Object? error;
  TurnEnd end = TurnEnd.endOfSequence;
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
}
