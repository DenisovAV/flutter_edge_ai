import 'package:flutter_edge_ai/src/chat.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_response.dart';
import 'package:flutter_test/flutter_test.dart';

/// What InferenceChat records when the session under a streaming turn is
/// closed before the reply is finished (B90).
///
/// Native LiteRT-LM ends such a stream with `done` after the chunks that had
/// arrived (the close's cancel counts as a requested one), so the chat cannot
/// tell the cut reply from a finished one. This session replays both endings
/// an engine can choose: `done` after two chunks, or an error after them.
class _ClosedMidTurnSession implements InferenceModelSession {
  _ClosedMidTurnSession({this.error});

  /// When set, the stream ends with this error instead of `done`.
  final Object? error;
  bool closed = false;

  @override
  Future<void> addQueryChunk(Message message) async {}

  @override
  Future<String> getResponse() async => throw UnimplementedError();

  /// Runs between the two chunks and the end: the close happens here.
  Future<void> Function()? midTurn;

  @override
  Stream<String> getResponseAsync() async* {
    yield 'The capital';
    yield ' of France';
    // The app closes the session here (session.close(), model.close(), an
    // uninstall that closes the cached model, or InferenceChat.clearHistory).
    await midTurn?.call();
    closed = true;
    if (error != null) throw error!;
  }

  @override
  Future<int> sizeInTokens(String text) async {
    // As FfiInferenceModelSession: every call after close throws.
    if (closed) throw StateError('Session is closed');
    return text.length ~/ 4;
  }

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async => closed = true;
}

Future<InferenceChat> _chatOn(InferenceModelSession session) async {
  final chat = InferenceChat(
    sessionCreator: () async => session,
    maxTokens: 4096,
    fileType: ModelFileType.litertlm,
  );
  await chat.initSession();
  await chat.addQuery(const Message(text: 'Capital of France?', isUser: true));
  return chat;
}

void main() {
  test('a turn whose stream ends with done after a close keeps the cut reply '
      'in history as a finished assistant turn', () async {
    final chat = await _chatOn(_ClosedMidTurnSession());

    final tokens = <String>[];
    await for (final r in chat.generateChatResponseAsync()) {
      if (r is TextResponse) tokens.add(r.token);
    }

    expect(tokens.join(), 'The capital of France');
    final assistant = chat.fullHistory.where((m) => !m.isUser).toList();
    expect(
      assistant.map((m) => m.text),
      ['The capital of France'],
      reason:
          'nothing marks the turn as cut: the consumer and the history '
          'both read it as the whole reply',
    );
  });

  test('a turn whose stream ends with an error after a close surfaces the '
      'error and records no assistant turn', () async {
    final chat = await _chatOn(
      _ClosedMidTurnSession(error: StateError('closed during generation')),
    );

    final tokens = <String>[];
    await expectLater(() async {
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) tokens.add(r.token);
      }
    }(), throwsA(isA<StateError>()));

    expect(tokens.join(), 'The capital of France');
    expect(chat.fullHistory.map((m) => (m.isUser, m.text)), [
      (true, 'Capital of France?'),
    ], reason: 'the user turn stays; the cut reply is not recorded');
  });

  test('clearHistory during a turn that then ends with done writes the old '
      "conversation's cut reply into the cleared history", () async {
    final first = _ClosedMidTurnSession();
    final second = _ClosedMidTurnSession();
    final sessions = [first, second];
    final chat = InferenceChat(
      sessionCreator: () async => sessions.removeAt(0),
      maxTokens: 4096,
      fileType: ModelFileType.litertlm,
    );
    await chat.initSession();
    await chat.addQuery(
      const Message(text: 'Capital of France?', isUser: true),
    );
    // clearHistory closes `first` and opens `second` while `first` streams.
    first.midTurn = chat.clearHistory;

    await for (final _ in chat.generateChatResponseAsync()) {}

    expect(
      chat.fullHistory.map((m) => (m.isUser, m.text)),
      [(false, 'The capital of France')],
      reason:
          'the cleared chat starts with an assistant turn from the '
          'conversation it replaced',
    );
  });
}
