/// A chunk of model output as the driver streams it.
sealed class DriverChunk {
  const DriverChunk();
}

class DriverText extends DriverChunk {
  const DriverText(this.token);
  final String token;
}

class DriverThinking extends DriverChunk {
  const DriverThinking(this.content);
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

  Future<void> close();
}
