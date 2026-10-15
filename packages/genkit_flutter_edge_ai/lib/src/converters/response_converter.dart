import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

/// The `ref` of the [index]th tool call of a turn when the engine gave the call
/// no [gemma.FunctionCallResponse.id], counted from 0 in the order the model
/// emitted them. Genkit matches each tool response to its request by `ref`,
/// falling back to the tool's name, so without one two calls to the same tool
/// in one turn collide.
String toolCallRef(int index) => 'call_$index';

/// The `ref` of each of a turn's [calls], in order: the call's own id, unless
/// an earlier call of the turn already has that ref, else the first
/// [toolCallRef] from its index on that no earlier call uses. Refs never
/// repeat within a turn, which Genkit needs to pair each response with its
/// request. Only earlier calls count, so the refs of a streamed chunk,
/// computed with the calls before it, are the ones the final response gives
/// them.
List<String> toolCallRefs(List<gemma.FunctionCallResponse> calls) {
  final used = <String>{};
  final refs = <String>[];
  for (final (index, call) in calls.indexed) {
    var ref = call.id;
    if (ref == null || used.contains(ref)) {
      var n = index;
      while (used.contains(toolCallRef(n))) {
        n++;
      }
      ref = toolCallRef(n);
    }
    used.add(ref);
    refs.add(ref);
  }
  return refs;
}

/// Converts a completed flutter_edge_ai response into a Genkit [ModelResponse].
///
/// Maps:
/// - Text → [ModelResponse] with [TextPart]
/// - Function call → [ModelResponse] with [ToolRequestPart], its `ref` the
///   call's id, or a numbered ref when it has none ([toolCallRefs])
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
    final refs = toolCallRefs(functionCalls);
    for (final (index, call) in functionCalls.indexed) {
      content.add(
        ToolRequestPart(
          toolRequest: ToolRequest(
            ref: refs[index],
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
  );
}

/// Converts a streaming [gemma.ModelResponse] chunk to a Genkit [ModelResponseChunk].
///
/// Used with `context.sendChunk()` for streaming model output. Tool calls get
/// their refs from [toolCallRefs] over [earlierCalls], the calls the turn
/// already streamed, and this chunk's, so a chunk's refs match the final
/// response's.
ModelResponseChunk convertStreamChunk(
  gemma.ModelResponse chunk, {
  List<gemma.FunctionCallResponse> earlierCalls = const [],
}) {
  List<Part> requests(List<gemma.FunctionCallResponse> calls) {
    final refs = toolCallRefs([
      ...earlierCalls,
      ...calls,
    ]).skip(earlierCalls.length).toList();
    return [
      for (final (i, c) in calls.indexed)
        ToolRequestPart(
          toolRequest: ToolRequest(ref: refs[i], name: c.name, input: c.args),
        ),
    ];
  }

  final List<Part> content = switch (chunk) {
    gemma.TextResponse(:final token) => [TextPart(text: token)],
    final gemma.FunctionCallResponse single => requests([single]),
    gemma.ParallelFunctionCallResponse(:final calls) => requests(calls),
    gemma.ThinkingResponse(:final content) => [
      if (content.isNotEmpty) ReasoningPart(reasoning: content),
    ],
  };

  return ModelResponseChunk(role: Role.model, content: content);
}

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
