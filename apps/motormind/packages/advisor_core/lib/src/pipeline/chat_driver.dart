/// A chunk of model output as the driver streams it.
sealed class DriverChunk {
  const DriverChunk();
}

/// A piece of the reply text meant for the person.
class DriverText extends DriverChunk {
  /// Creates a text chunk carrying [token].
  const DriverText(this.token);

  /// The text produced since the previous chunk; may be a partial word.
  final String token;
}

/// A piece of the model's reasoning, kept apart from the reply.
class DriverThinking extends DriverChunk {
  /// Creates a thinking chunk carrying [content].
  const DriverThinking(this.content);

  /// The reasoning text produced since the previous chunk.
  final String content;
}

/// Signature of the app-side function that executes a tool call.
typedef ToolCallHandler =
    Future<Map<String, Object?>> Function(String name, Map<String, Object?> args);

/// The seam between the pipeline and an inference SDK. The real
/// implementation wraps `InferenceChat.generateChatResponseWithTools`; tests
/// use a scripted fake. The driver owns the chat history; the pipeline owns
/// everything that happens around a turn.
abstract class ChatDriver {
  /// Sends [userText] as the user's turn and streams the model's reply. Tool
  /// calls are routed to [onToolCall] and their results fed back to the model
  /// by the driver before generation continues.
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall});

  /// Replaces the system instruction for subsequent turns, if the SDK allows
  /// it without losing history. Drivers that cannot may ignore it.
  Future<void> updateSystemInstruction(String instruction);

  /// Stops the generation in flight, if any. The stream returned by [send]
  /// ends (possibly with the text produced so far). Best effort.
  Future<void> cancel();

  /// Releases the underlying chat session; the driver is unusable afterwards.
  Future<void> close();
}
