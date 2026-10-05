import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/plugin.dart';

/// Converts a completed flutter_gemma response into a Genkit [ModelResponse].
///
/// Maps:
/// - Text → [ModelResponse] with [TextPart]
/// - Function call → [ModelResponse] with [ToolRequestPart]
/// - Reasoning → prepended [ReasoningPart] before text/tool content
ModelResponse convertFinalResponse(
  String fullText, {
  List<gemma.FunctionCallResponse>? functionCalls,
  String? reasoningText,
  double? latencyMs,
}) {
  final content = <Part>[];

  if (reasoningText != null && reasoningText.isNotEmpty) {
    content.add(ReasoningPart(reasoning: reasoningText));
  }

  if (functionCalls != null && functionCalls.isNotEmpty) {
    for (final call in functionCalls) {
      content.add(ToolRequestPart(
        toolRequest: ToolRequest(name: call.name, input: call.args),
      ));
    }
  } else if (fullText.isNotEmpty) {
    content.add(TextPart(text: fullText));
  }

  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: content,
    ),
    latencyMs: latencyMs,
  );
}

/// Converts a streaming [gemma.ModelResponse] chunk to a Genkit [ModelResponseChunk].
///
/// Used with `context.sendChunk()` for streaming model output.
ModelResponseChunk convertStreamChunk(gemma.ModelResponse chunk) {
  final content = <Part>[];

  switch (chunk) {
    case gemma.TextResponse(:final token):
      content.add(TextPart(text: token));
    case gemma.FunctionCallResponse(:final name, :final args):
      content.add(ToolRequestPart(
        toolRequest: ToolRequest(name: name, input: args),
      ));
    case gemma.ParallelFunctionCallResponse(:final calls):
      for (final call in calls) {
        content.add(ToolRequestPart(
          toolRequest: ToolRequest(name: call.name, input: call.args),
        ));
      }
    case gemma.ThinkingResponse(:final content):
      if (content.isNotEmpty) {
        // Destructured 'content' shadows outer list; early return avoids conflict.
        return ModelResponseChunk(
          role: Role.model,
          content: [ReasoningPart(reasoning: content)],
        );
      }
  }

  return ModelResponseChunk(
    role: Role.model,
    content: content,
  );
}
