import 'package:flutter_edge_ai/core/chat.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// #325 regression: when a streaming generation is cancelled (or ends) with an
/// EMPTY accumulated assistant response, that empty turn must NOT be written
/// into chat history — otherwise it pollutes _modelHistory and later short
/// replies come back empty.
///
/// This session's getResponseAsync() yields an EMPTY stream, simulating a
/// stopGeneration() that fires before any text token is produced.
class _EmptyResponseSession implements InferenceModelSession {
  final List<Message> addedMessages = [];

  @override
  Future<void> addQueryChunk(Message message) async =>
      addedMessages.add(message);

  @override
  Future<String> getResponse() async => '';

  @override
  Stream<String> getResponseAsync() => const Stream<String>.empty();

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
  test(
    '#325: cancelled/empty assistant response is NOT appended to history',
    () async {
      final session = _EmptyResponseSession();
      final chat = InferenceChat(
        sessionCreator: () async => session,
        maxTokens: 1024,
        fileType: ModelFileType.litertlm,
      );
      await chat.initSession();

      await chat.addQuery(const Message(text: 'Hello', isUser: true));

      // Drain the (empty) async stream — simulates a cancelled generation
      // that produced no text.
      await for (final _ in chat.generateChatResponseAsync()) {}

      // The user turn is in history; the empty assistant turn must NOT be.
      final assistantTurns = chat.fullHistory.where((m) => !m.isUser).toList();
      expect(
        assistantTurns,
        isEmpty,
        reason: 'An empty assistant turn must not be written to history (#325)',
      );
    },
  );
}
