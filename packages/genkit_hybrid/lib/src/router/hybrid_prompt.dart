import 'dart:async';

import 'package:genkit/genkit.dart';

import 'hybrid_routing_exception.dart';

/// A prompt routed by a hybrid router, from `HybridRouter.definePrompt`.
///
/// [call] and [stream] take what `Prompt.call` / `Prompt.stream` take except
/// `model` and `config`, and throw [HybridRoutingException] when the router
/// refuses. A prompt has no interrupt parameters: resume one whose tool
/// interrupted with `router.generate(messages:, toolNames:,
/// interruptRespond:)`, which keeps the router's decision.
final class HybridPrompt<Input, Output> {
  HybridPrompt(this.prompt);

  /// The registered Genkit prompt, for APIs that take a [Prompt]. Called
  /// directly it returns Genkit's `failed` result on a refusal instead of
  /// throwing.
  final Prompt<Input, Output> prompt;

  PromptRef get ref => prompt.ref;

  /// The request this prompt would send, router ref included.
  Future<GenerateActionOptions> render(
    Input? input, {
    List<Message>? messages,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    bool? returnToolRequests,
    int? maxTurns,
    GenerateActionOutputConfig? output,
    List<GenerateMiddlewareRef>? use,
  }) => prompt.render<Object?>(
    input,
    messages: messages,
    tools: tools,
    toolNames: toolNames,
    toolChoice: toolChoice,
    returnToolRequests: returnToolRequests,
    maxTurns: maxTurns,
    output: output,
    use: use,
  );

  Future<GenerateResult<Output>> call(
    Input? input, {
    List<Message>? messages,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    bool? returnToolRequests,
    int? maxTurns,
    GenerateActionOutputConfig? output,
    Map<String, dynamic>? context,
    List<GenerateMiddlewareRef>? use,
    CancellationToken? cancel,
  }) async => checkedRoutingResult(
    await prompt.call<Object?>(
      input,
      messages: messages,
      tools: tools,
      toolNames: toolNames,
      toolChoice: toolChoice,
      returnToolRequests: returnToolRequests,
      maxTurns: maxTurns,
      output: output,
      context: context,
      use: use,
      cancel: cancel,
    ),
  );

  /// Streams the prompt; a refusal fails both the chunk stream and
  /// `onResult`.
  ActionStream<GenerateResponseChunk<Output>, GenerateResult<Output>> stream(
    Input? input, {
    List<Message>? messages,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    bool? returnToolRequests,
    int? maxTurns,
    GenerateActionOutputConfig? output,
    Map<String, dynamic>? context,
    List<GenerateMiddlewareRef>? use,
    CancellationToken? cancel,
  }) {
    final inner = prompt.stream<Object?>(
      input,
      messages: messages,
      tools: tools,
      toolNames: toolNames,
      toolChoice: toolChoice,
      returnToolRequests: returnToolRequests,
      maxTurns: maxTurns,
      output: output,
      context: context,
      use: use,
      cancel: cancel,
    );
    final chunks = StreamController<GenerateResponseChunk<Output>>();
    final result = inner.onResult.then(checkedRoutingResult);
    inner.listen(
      chunks.add,
      // The same error completes `onResult`, which reports it below.
      onError: (Object _) {},
      onDone: () => result.then(
        (_) => chunks.close(),
        onError: (Object e, StackTrace s) {
          chunks.addError(e, s);
          chunks.close();
        },
      ),
    );
    return ActionStream.withResult(chunks.stream, result);
  }
}
