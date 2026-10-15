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
  const FunctionCallResponse({required this.name, required this.args, this.id});

  final String name;
  final Map<String, dynamic> args;

  /// The id the engine or the caller gave this call, or null when there is
  /// none. No bundled engine gives one today; genai `callId`s and Genkit
  /// `ref`s do. A tool result names it through
  /// `Message.toolResponse(toolCallId:)`. Expected to be unique within one
  /// turn, but not checked; it may repeat across turns.
  final String? id;

  @override
  String toString() =>
      'FunctionCallResponse(name: $name, args: $args${id == null ? '' : ', id: $id'})';

  @override
  bool operator ==(Object other) =>
      other is FunctionCallResponse &&
      other.name == name &&
      other.id == id &&
      _deepEquals(other.args, args);

  @override
  int get hashCode => Object.hash(name, id, _deepHash(args));
}

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) ||
          !_deepEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? value) => switch (value) {
  Map() => Object.hashAllUnordered([
    for (final entry in value.entries)
      Object.hash(entry.key, _deepHash(entry.value)),
  ]),
  List() => Object.hashAll(value.map(_deepHash)),
  _ => value.hashCode,
};

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
