/// Base interface for model responses from InferenceChat
/// Can be either TextResponse, FunctionCallResponse, or ThinkingResponse
sealed class ModelResponse {
  const ModelResponse();
}

/// Text token during streaming
class TextResponse extends ModelResponse {
  final String token;

  const TextResponse(this.token);

  @override
  String toString() => 'TextResponse("$token")';

  @override
  bool operator ==(Object other) {
    return other is TextResponse && other.token == token;
  }

  @override
  int get hashCode => token.hashCode;
}

class FunctionCallResponse extends ModelResponse {
  const FunctionCallResponse({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

/// Multiple function calls in a single model response.
class ParallelFunctionCallResponse extends ModelResponse {
  const ParallelFunctionCallResponse({required this.calls});

  final List<FunctionCallResponse> calls;
}

/// Thinking process content from the model
class ThinkingResponse extends ModelResponse {
  final String content;

  const ThinkingResponse(this.content);

  @override
  String toString() => 'ThinkingResponse("$content")';

  @override
  bool operator ==(Object other) {
    return other is ThinkingResponse && other.content == content;
  }

  @override
  int get hashCode => content.hashCode;
}
