/// genai_primitives adoption surface for flutter_edge_ai (#181).
///
/// A side barrel (NOT re-exported from `flutter_edge_ai.dart`) so genai_primitives
/// 0.x churn stays contained. Import `package:flutter_edge_ai/genai.dart` to use
/// [ChatMessage] with [InferenceChat.sendMessage] / [generateContent].
library;

export 'package:genai_primitives/genai_primitives.dart';
export 'core/genai/genai_chat_extension.dart' show GenAiChat;
