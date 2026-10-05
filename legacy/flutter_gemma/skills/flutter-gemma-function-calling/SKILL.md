---
name: flutter-gemma-function-calling
description: Use when adding function calling (tool calling) to a flutter_gemma chat — letting an on-device model call the app's own Dart functions, declaring Tool objects, handling FunctionCallResponse or ParallelFunctionCallResponse, returning results with Message.toolResponse, or running the built-in tool loop generateChatResponseWithTools. Also use when the model describes an action in prose instead of calling the tool, raw tool-call markers appear in the reply text, or a switch over ModelResponse fails to compile. For plain chat, use flutter-gemma-inference. Not for flutter_gemma_agent, which gives the on-device model SKILL.md skills of its own.
---

# Function calling with flutter_gemma

Packages, engine and model install are in the flutter-gemma-inference skill. This one starts from a loaded `InferenceModel`.

## Rules

1. `createChat` needs `tools` and `supportsFunctionCalls: true`. Without the flag no call is parsed and only a debug warning is logged — and on `.litertlm` with Gemma 4 or FunctionGemma the declarations still reach the SDK, so the model answers with raw tool-call JSON inside the text stream.
2. Pass `modelType` on web and on ONNX. `createChat` on native `.litertlm`, on MediaPipe Android and iOS, and on built-in AI uses the installed model's type when it is left out; the web engines and ONNX fall back to `ModelType.gemmaIt`, and another model's calls then arrive as raw text. `openChat` always falls back — pass it there on every platform.
3. Switch over all four `ModelResponse` subtypes. It is sealed — a switch that leaves out `ThinkingResponse` does not compile.
4. Return tool results as data, errors included. Never throw from a tool.
5. Prefer `generateChatResponseWithTools` to a hand-written loop.
6. Use a tool-capable model: Gemma 4, Gemma 3n, Gemma 3 1B, FunctionGemma, Phi-4 Mini, Qwen 2.5, Qwen3, DeepSeek R1. Gemma 3 270M and SmolLM cannot call tools.

## Declare a tool

`parameters` is a JSON Schema object. The model matches the user's intent against `description`, so write it as an action and describe every parameter.

```dart
import 'package:flutter_gemma/flutter_gemma.dart';

const changeColor = Tool(
  name: 'change_color',
  description: 'Change the app background colour.',
  parameters: {
    'type': 'object',
    'properties': {
      'color': {'type': 'string', 'description': 'A colour name, e.g. red.'},
    },
    'required': ['color'],
  },
);
```

## Open the chat

```dart
final InferenceChat chat = await model.createChat(
  tools: myTools,
  supportsFunctionCalls: true,
  modelType: ModelType.gemma4,
);
```

## The built-in loop

It calls the handler for each tool call, feeds the result back, and continues until the model answers in text or `maxToolTurns` is reached.

```dart
await chat.addQueryChunk(Message(text: prompt, isUser: true));
final answer = StringBuffer();
await for (final r in chat.generateChatResponseWithTools(
  onToolCall: (FunctionCallResponse call) => runTool(call.name, call.args),
  maxToolTurns: 8,
  onMaxToolTurns: () => print('stopped after 8 tool turns'),
)) {
  if (r is TextResponse) answer.write(r.token);
}
```

`onToolCall` receives a `FunctionCallResponse` with `name` and `args`, and returns the map the model reads back. The stream carries `TextResponse` and `ThinkingResponse`. Reaching `maxToolTurns` ends the stream without an error — `onMaxToolTurns` is the only signal. An exception from `onToolCall` is reported to the model, then rethrown on the stream.

## Handling calls yourself

```dart
final response = await chat.generateChatResponse();
switch (response) {
  case FunctionCallResponse(:final name, :final args):
    final result = await runTool(name, args);
    await chat.addQueryChunk(
      Message.toolResponse(toolName: name, response: result),
    );
    final followUp = await chat.generateChatResponse();
  case ParallelFunctionCallResponse(:final calls):
    for (final call in calls) {
      final result = await runTool(call.name, call.args);
      await chat.addQueryChunk(
        Message.toolResponse(toolName: call.name, response: result),
      );
    }
    final afterAll = await chat.generateChatResponse();
  case TextResponse(:final token):
    print(token); // the model chose to answer directly — a valid outcome
  case ThinkingResponse():
    break;
}
```

## Errors are results

```dart
await chat.addQueryChunk(
  Message.toolResponse(
    toolName: 'change_color',
    response: {'error': 'unknown colour: mauvish'},
  ),
);
```

The model can recover from an error it can read. An exception thrown out of a tool ends the turn instead.

## Traps

**Model answers in prose**
- Symptom: "I would change the colour to red" instead of a call.
- Fix: check `supportsFunctionCalls: true`, pass `modelType` on web and ONNX, then check the model is tool-capable.

**Raw markers in the text**
- Symptom: `<|tool_call>` or `<tool_call|>` appears in `TextResponse` tokens.
- Fix: `modelType` does not match the installed model.

**Model calls the same tool again instead of answering the result**
- Symptom: FunctionGemma on `.litertlm` repeats the call it just made after `Message.toolResponse`.
- Fix: `flutter_gemma` 1.8.4 with `flutter_gemma_litertlm` 1.7.1 — both halves. Core picks the wire format, the engine sends it; older pairs send the result as an ordinary user message.

**Nothing after the tool result**
- Symptom: the call arrives, the result goes back, and the stream ends with no text.
- Fix: nothing to fix on FunctionGemma — it is an action model and ending the turn at the call is what it was trained for. Render the tool's own result, and use Gemma 4 when the model should talk about what came back.

## Web

Function calling works on the `.litertlm` web engine. Pass `modelType`, and close each chat before creating the next — the web engine holds one session at a time.
