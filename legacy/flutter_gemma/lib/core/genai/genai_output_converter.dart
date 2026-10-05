import 'package:genai_primitives/genai_primitives.dart';

import '../model_response.dart';

/// One streamed [ModelResponse] variant → one single-part model [ChatMessage].
ChatMessage chatMessageFromChunk(ModelResponse chunk) {
  final parts = <StandardPart>[];
  switch (chunk) {
    case TextResponse(:final token):
      parts.add(TextPart(token));
    case ThinkingResponse(:final content):
      parts.add(ThinkingPart(content));
    case FunctionCallResponse(:final name, :final args):
      parts.add(ToolPart.call(callId: name, toolName: name, arguments: args));
    case ParallelFunctionCallResponse(:final calls):
      for (final c in calls) {
        parts.add(
          ToolPart.call(callId: c.name, toolName: c.name, arguments: c.args),
        );
      }
  }
  return ChatMessage(role: ChatMessageRole.model, parts: parts);
}

/// Coalesce a whole model turn into one [ChatMessage].
///
/// Parts follow generation order: ThinkingPart → TextPart → ToolPart.call…. A
/// preamble ("Let me check…") that accompanies a tool call is kept, not dropped
/// — matching what [chatMessageFromChunk] emits on the streaming path.
///
/// `callId` mirrors `toolName`: flutter_gemma's tool protocol is name-keyed
/// ([FunctionCallResponse] carries no independent id), so parallel calls to the
/// same tool share a callId and callId is ignored when a result is fed back in.
ChatMessage chatMessageFromParts({
  String? text,
  List<FunctionCallResponse> calls = const [],
  String? thinking,
  Map<String, Object?> metadata = const {},
}) {
  final parts = <StandardPart>[];
  if (thinking != null && thinking.isNotEmpty) {
    parts.add(ThinkingPart(thinking));
  }
  if (text != null && text.isNotEmpty) {
    parts.add(TextPart(text));
  }
  for (final c in calls) {
    parts.add(
      ToolPart.call(callId: c.name, toolName: c.name, arguments: c.args),
    );
  }
  return ChatMessage(
    role: ChatMessageRole.model,
    parts: parts,
    metadata: metadata,
  );
}
