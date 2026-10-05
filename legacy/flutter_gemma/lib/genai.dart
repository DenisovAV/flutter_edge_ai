/// genai_primitives adoption surface for flutter_gemma (#181).
///
/// A side barrel (NOT re-exported from `flutter_gemma.dart`) so genai_primitives
/// 0.x churn stays contained. Import `package:flutter_gemma/genai.dart` to use
/// [ChatMessage] with [InferenceChat.sendMessage] / [generateContent].
library;

export 'package:genai_primitives/genai_primitives.dart';
export 'core/genai/genai_chat_extension.dart' show GenAiChat;
