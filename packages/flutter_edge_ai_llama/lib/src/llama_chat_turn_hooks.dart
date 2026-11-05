import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

import 'llama_inference_session.dart';

/// One chat's turns on llamadart's typed output, with the session as the
/// single owner of the transcript.
///
/// The hooks own the chat's [tokenBuffer] and give it to the session on
/// every call core makes with it ([_bind]): input, replay, history and the
/// token count after each turn. Core opens a chat's sessions with no chat
/// values, so this is where the session learns it; every turn that could
/// drop an older one follows such a call (core counts each structured reply
/// through [tokenCount], and a rebuilt session is replayed through
/// [addQueryChunk]), including input staged on `chat.session` directly.
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
    final llamaSession = _bind(session);
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

  LlamaInferenceSession _bind(edge.InferenceModelSession session) =>
      (session as LlamaInferenceSession)..chatTokenBuffer = tokenBuffer;

  @override
  List<edge.Message> history(edge.InferenceModelSession session) =>
      _bind(session).messages;

  /// After a structured turn, the history the session kept, which it has
  /// trimmed under core's rebuild threshold; else the last turn's total.
  @override
  int tokenCount(edge.InferenceModelSession session) {
    final llamaSession = _bind(session);
    return llamaSession.retainedTokens ??
        llamaSession.getSessionMetrics().totalTokens;
  }

  @override
  Future<void> addQueryChunk(
    edge.InferenceModelSession session,
    edge.Message message,
  ) => _bind(session).addQueryChunk(message);

  @override
  Future<void> replayFinished(edge.InferenceModelSession session) async =>
      _bind(session).commitReplay();

  @override
  Future<void> replayFailed(
    edge.InferenceModelSession session,
    Object error,
  ) async => _bind(session);
}
