/// A chunk of model output as the driver streams it.
sealed class DriverChunk {
  const DriverChunk();
}

/// A piece of the reply text meant for the person.
class DriverText extends DriverChunk {
  /// Creates a text chunk carrying [text].
  const DriverText(this.text);

  /// The text produced since the previous chunk; may be a partial word.
  final String text;
}

/// A piece of the model's reasoning, kept apart from the reply.
class DriverThinking extends DriverChunk {
  /// Creates a thinking chunk carrying [text].
  const DriverThinking(this.text);

  /// The reasoning text produced since the previous chunk.
  final String text;
}

/// Signature of a function that executes a tool call and returns the map the
/// model is shown as the result. The pipeline passes one to the driver for
/// every tool; the app passes one to the pipeline for the tools the pipeline
/// does not own.
typedef ToolCallHandler =
    Future<Map<String, Object?>> Function(String name, Map<String, Object?> args);

/// The seam between the pipeline and an inference SDK. The real
/// implementation wraps `InferenceChat.generateChatResponseWithTools`; tests
/// use a scripted fake. The driver owns the chat history and the system
/// instruction it was created with; the pipeline owns everything that
/// happens around a turn.
abstract class ChatDriver {
  /// Sends [userText] as the user's turn and streams the model's reply. Tool
  /// calls are routed to [onToolCall] and their results fed back to the model
  /// by the driver before generation continues.
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall});

  /// Stops the generation in flight, if any. The stream returned by [send]
  /// ends (possibly with the text produced so far). Best effort.
  Future<void> cancel();

  /// Releases the underlying chat session; the driver is unusable afterwards.
  Future<void> close();
}
