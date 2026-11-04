import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

import 'llama_inference_session.dart';

/// One chat's turns on llamadart's typed output, with the session as the
/// single owner of the transcript.
///
/// Model family labels remain metadata: the GGUF template owns all
/// prompting. Core's bounded tool loop works with the typed calls returned
/// here. A replay that fails needs nothing undone: core has already reopened
/// the chat's session, empty.
final class LlamaChatTurnHooks extends ChatTurnHooks {
  /// Creates the hooks of one chat.
  LlamaChatTurnHooks({required this.enableThinking, required this.tokenBuffer});

  /// Whether the app asked to see the model's reasoning.
  final bool enableThinking;

  /// Tokens the chat keeps free: the oldest turns are dropped to keep them.
  final int tokenBuffer;

  bool _reportedHiddenThinking = false;

  @override
  Stream<edge.ModelResponse> responses(
    edge.InferenceModelSession session, {
    required int tokenBuffer,
  }) async* {
    final llamaSession = session as LlamaInferenceSession;
    try {
      yield* llamaSession.getResponses(tokenBuffer: tokenBuffer);
    } finally {
      final hidden = llamaSession.hiddenThinkingCharacters;
      if (!enableThinking && hidden > 0 && !_reportedHiddenThinking) {
        _reportedHiddenThinking = true;
        // A release build also needs this one-time notice, as core does.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai] NOTE: the model reasoned although thinking is off; '
          '$hidden characters of reasoning were hidden. Not every model can '
          'switch reasoning off, and hidden reasoning still costs time and '
          'output tokens. Shown once per chat.',
        );
      }
    }
  }

  @override
  List<edge.Message> history(edge.InferenceModelSession session) =>
      (session as LlamaInferenceSession).messages;

  @override
  int tokenCount(edge.InferenceModelSession session) =>
      session.getSessionMetrics().totalTokens;

  /// Also hands the session the chat's [tokenBuffer] for its structured
  /// turns, which core runs through the session's own turn.
  @override
  Future<void> addQueryChunk(
    edge.InferenceModelSession session,
    edge.Message message,
  ) {
    (session as LlamaInferenceSession).chatTokenBuffer = tokenBuffer;
    return session.addQueryChunk(message);
  }

  @override
  Future<void> replayFinished(edge.InferenceModelSession session) async =>
      (session as LlamaInferenceSession).commitReplay();
}
