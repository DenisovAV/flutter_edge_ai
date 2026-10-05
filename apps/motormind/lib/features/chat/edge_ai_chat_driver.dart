import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../models/model_catalog.dart';

/// The real [ChatDriver]: one `InferenceChat` over the loaded model, with the
/// advisor's tools declared and the system prompt installed.
class EdgeAiChatDriver implements ChatDriver {
  EdgeAiChatDriver._(this._chat, this._model, this._spec);

  final InferenceChat _chat;
  final InferenceModel _model;
  final AdvisorModelSpec _spec;

  static Future<EdgeAiChatDriver> open(
    InferenceModel model,
    AdvisorModelSpec spec, {
    required String systemInstruction,
  }) async {
    final chat = await model.createChat(
      temperature: spec.temperature,
      topK: spec.topK,
      topP: spec.topP,
      tools: [
        for (final t in AdvisorTools.all)
          Tool(name: t.name, description: t.description, parameters: t.parameters),
      ],
      supportsFunctionCalls: spec.supportsTools,
      isThinking: false,
      modelType: spec.modelType,
      systemInstruction: systemInstruction,
    );
    return EdgeAiChatDriver._(chat, model, spec);
  }

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) async* {
    await _chat.addQueryChunk(Message.text(text: userText, isUser: true));
    final stream = _chat.generateChatResponseWithTools(
      onToolCall: (call) => onToolCall(call.name, call.args.cast<String, Object?>()),
      maxToolTurns: 6,
    );
    await for (final r in stream) {
      switch (r) {
        case TextResponse(:final token):
          yield DriverText(token);
        case ThinkingResponse(:final content):
          yield DriverThinking(content);
        case FunctionCallResponse() || ParallelFunctionCallResponse():
          break; // consumed by the loop
      }
    }
  }

  @override
  Future<void> updateSystemInstruction(String instruction) async {
    // The SDK fixes the instruction at chat creation; a new chat would drop
    // history. Left as a no-op until a history-preserving path exists.
  }

  @override
  Future<void> close() => _chat.close();

  String get modelId => _spec.id;
  InferenceModel get model => _model;
}
