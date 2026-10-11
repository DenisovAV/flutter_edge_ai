import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

import 'llama_inference_session.dart';

/// Edge AI chat using llamadart's typed output and a single transcript owner.
///
/// Model family labels remain metadata: the GGUF template owns all prompting.
/// The inherited bounded tool loop works with the typed calls returned here.
class LlamaInferenceChat extends edge.InferenceChat {
  /// Creates a chat over a model-supplied session factory.
  LlamaInferenceChat({
    required super.sessionCreator,
    required super.maxTokens,
    super.tokenBuffer,
    super.supportImage,
    super.supportAudio,
    super.supportsFunctionCalls,
    super.maxFunctionBufferLength,
    super.tools,
    super.enableThinking,
    super.modelType,
    super.fileType,
    super.toolChoice,
  }) : super(runtimeInjectsToolDeclarations: true);

  LlamaInferenceSession get _llamaSession => session as LlamaInferenceSession;

  @override
  List<edge.Message> get fullHistory => _llamaSession.messages;

  @override
  int get currentTokens => _llamaSession.getSessionMetrics().totalTokens;

  @override
  Future<void> addQueryChunk(
    edge.Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) => _llamaSession.addQueryChunk(message);

  @override
  Stream<edge.ModelResponse> generateChatResponseAsync() =>
      _llamaSession.getResponses();

  @override
  Future<edge.ModelResponse> generateChatResponse() async {
    final text = StringBuffer();
    final calls = <edge.FunctionCallResponse>[];
    await for (final response in generateChatResponseAsync()) {
      switch (response) {
        case edge.TextResponse(:final token):
          text.write(token);
        case edge.FunctionCallResponse():
          calls.add(response);
        case edge.ParallelFunctionCallResponse():
          calls.addAll(response.calls);
        case edge.ThinkingResponse():
          break;
      }
    }
    if (calls.length == 1) return calls.single;
    if (calls.isNotEmpty) {
      return edge.ParallelFunctionCallResponse(calls: calls);
    }
    return edge.TextResponse(text.toString());
  }

  @override
  Future<void> clearHistory({List<edge.Message>? replayHistory}) async {
    await session.close();
    await initSession();
    try {
      for (final message in replayHistory ?? const <edge.Message>[]) {
        await addQueryChunk(message);
      }
    } catch (_) {
      // A malformed replay must not leave a partially staged conversation.
      await session.close();
      await initSession();
      rethrow;
    }
  }
}
