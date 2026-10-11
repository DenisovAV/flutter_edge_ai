import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

/// The `ref` of the [index]th tool call of a turn, counted from 0 in the order
/// the model emitted them. Genkit matches each tool response to its request by
/// `ref`, falling back to the tool's name, so without one two calls to the
/// same tool in one turn collide.
String toolCallRef(int index) => 'call_$index';

/// Converts a completed flutter_edge_ai response into a Genkit [ModelResponse].
///
/// Maps:
/// - Text → [ModelResponse] with [TextPart]
/// - Function call → [ModelResponse] with [ToolRequestPart], numbered with
///   [toolCallRef] in order
/// - Reasoning → prepended [ReasoningPart] before text/tool content
ModelResponse convertFinalResponse(
  String fullText, {
  List<gemma.FunctionCallResponse>? functionCalls,
  String? reasoningText,
  double? latencyMs,
  GenerationUsage? usage,
}) {
  final content = <Part>[];

  if (reasoningText != null && reasoningText.isNotEmpty) {
    content.add(ReasoningPart(reasoning: reasoningText));
  }

  if (functionCalls != null && functionCalls.isNotEmpty) {
    for (final (index, call) in functionCalls.indexed) {
      content.add(
        ToolRequestPart(
          toolRequest: ToolRequest(
            ref: toolCallRef(index),
            name: call.name,
            input: call.args,
          ),
        ),
      );
    }
  } else if (fullText.isNotEmpty) {
    content.add(TextPart(text: fullText));
  }

  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(role: Role.model, content: content),
    latencyMs: latencyMs,
    usage: usage,
  );
}

/// Converts a streaming [gemma.ModelResponse] chunk to a Genkit [ModelResponseChunk].
///
/// Used with `context.sendChunk()` for streaming model output. Tool calls are
/// numbered from [firstToolCallIndex], the number of calls the turn already
/// streamed, so a chunk's refs match the final response's.
ModelResponseChunk convertStreamChunk(
  gemma.ModelResponse chunk, {
  int firstToolCallIndex = 0,
}) {
  ToolRequestPart call(int offset, gemma.FunctionCallResponse c) =>
      ToolRequestPart(
        toolRequest: ToolRequest(
          ref: toolCallRef(firstToolCallIndex + offset),
          name: c.name,
          input: c.args,
        ),
      );

  final List<Part> content = switch (chunk) {
    gemma.TextResponse(:final token) => [TextPart(text: token)],
    final gemma.FunctionCallResponse single => [call(0, single)],
    gemma.ParallelFunctionCallResponse(:final calls) => [
      for (final (offset, c) in calls.indexed) call(offset, c),
    ],
    gemma.ThinkingResponse(:final content) => [
      if (content.isNotEmpty) ReasoningPart(reasoning: content),
    ],
  };

  return ModelResponseChunk(role: Role.model, content: content);
}

/// The number of tool calls in [chunk].
int toolCallsIn(gemma.ModelResponse chunk) => switch (chunk) {
  gemma.FunctionCallResponse() => 1,
  gemma.ParallelFunctionCallResponse(:final calls) => calls.length,
  _ => 0,
};

/// Genkit usage for one generation: the engine's token counts where it
/// reports them, the media the request carried, and the time to first token
/// and decode speed under `custom`. Null when there is nothing to report.
///
/// A zero is treated as "not reported": an engine that cannot count tokens
/// returns 0 rather than null.
GenerationUsage? convertUsage(
  gemma.SessionMetrics? metrics, {
  int inputImages = 0,
  int inputAudioFiles = 0,
}) {
  int? positive(int? value) => (value != null && value > 0) ? value : null;
  final custom = <String, dynamic>{
    'timeToFirstTokenMs': ?metrics?.timeToFirstTokenMs,
    'tokensPerSecond': ?metrics?.tokensPerSecond,
  };
  final usage = GenerationUsage(
    inputTokens: positive(metrics?.inputTokens),
    outputTokens: positive(metrics?.outputTokens),
    totalTokens: positive(metrics?.totalTokens),
    inputImages: positive(inputImages),
    inputAudioFiles: positive(inputAudioFiles),
    custom: custom.isEmpty ? null : custom,
  );
  return usage.toJson().isEmpty ? null : usage;
}
