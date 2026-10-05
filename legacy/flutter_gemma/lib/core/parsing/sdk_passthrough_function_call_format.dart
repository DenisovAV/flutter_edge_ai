import 'function_call_format.dart';
import 'package:flutter_gemma/core/model_response.dart';

/// Passthrough [FunctionCallFormat] for backends that surface tool calls
/// through structured SDK responses rather than text-stream parsing
/// (e.g. LiteRT-LM Gemma 4 — the C++ runtime parses native
/// `<|tool_call>...<tool_call|>` tokens itself and returns OpenAI-style JSON).
///
/// All detection methods report "no function call in text", so streaming chat
/// flows treat the text channel as plain text. The actual tool calls are read
/// out of the session's last raw JSON via `SdkResponseParser.extractToolCalls`
/// in [InferenceChat.generateChatResponse].
class SdkPassthroughFunctionCallFormat extends FunctionCallFormat {
  /// The backend (e.g. LiteRT-LM Gemma 4) renders the tool declarations from
  /// `tools_json` at conversation creation, so the Dart-side tools prompt must
  /// be skipped to avoid double-wrapping them.
  @override
  bool get runtimeInjectsToolDeclarations => true;

  @override
  bool isFunctionCallStart(String buffer) => false;

  @override
  bool isDefinitelyText(String buffer) => true;

  @override
  bool isFunctionCallComplete(String buffer) => false;

  @override
  FunctionCallResponse? parse(String text) => null;

  @override
  List<FunctionCallResponse> parseAll(String text) => const [];
}
