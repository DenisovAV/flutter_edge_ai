import 'package:flutter_edge_ai/engine.dart';

/// A session that does nothing, for a test chat whose turns are scripted
/// through [ChatTurnHooks]: core hands the hooks the chat's session, and a
/// chat built with `sessionCreator: null` has none of its own.
final class NoopSession extends InferenceModelSession {
  @override
  Future<String> getResponse() async => '';

  @override
  Stream<String> getResponseAsync() => const Stream<String>.empty();

  @override
  Future<int> sizeInTokens(String text) async => 0;

  @override
  Future<void> addQueryChunk(Message message) async {}

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

/// Hooks whose turns come from [turn]: each call of `responses` is one turn.
final class ScriptedTurnHooks extends ChatTurnHooks {
  ScriptedTurnHooks(this.turn);

  final Stream<ModelResponse> Function() turn;

  @override
  Stream<ModelResponse> responses(
    InferenceModelSession session, {
    required int tokenBuffer,
  }) => turn();
}
