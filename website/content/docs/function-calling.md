---
title: Function Calling
description: Let on-device models call external functions and integrate with other services.
image: https://flutteredge.ai/images/og-image.png
---

Function calling lets a model request that your app run an external function —
for example, changing the UI, querying a database, or calling another service —
and then continue the conversation with the result.

## Supported models

### Models with function calling support

- **Gemma 4** (E2B, E4B) — full support (native function-call tokens).
- **Gemma3n E4B `.litertlm`** — the only downloadable/network Gemma3n catalog
  entry with function calling enabled. An intentional local E2B `.task` fixture
  also enables it; the downloadable E2B and MediaPipe entries do not.
- **FunctionGemma 270M** — Google's specialized function-calling model.
- **DeepSeek R1** — function calling + thinking mode.
- **Qwen** models (0.5B, 0.6B, 1.5B) — full support.
- **Phi-4 Mini** — advanced reasoning with function calling.

### Models without function calling support

- **Gemma 3 270M** — text generation only.
- **Gemma 3 1B** — text generation only in the current catalog.
- **SmolLM 135M** — text generation only.
- **LFM2.5 230M** — text generation only.
- **SmolLM3 3B** — text generation with reasoning, no function calling.
- **Phi-4 Mini Reasoning** — reasoning model, no function calling.
- **FastVLM 0.5B** — vision model, no function calling.
- **Qwen2-VL 2B** — vision model, no function calling.
- **SmolVLM2 500M** — vision model, no function calling.
- **LLaVA-OneVision 0.5B** — vision model, no function calling.

<Info>
When you pass tools to an unsupported model, the plugin logs a warning and
ignores the tools — the model still works normally for text generation. Check the
`supportsFunctionCalls` property in your model configuration.
</Info>

### Built-in AI (OS models)

[Built-in AI](/docs/builtin-ai) models — Gemini Nano (Android), Apple Foundation
Models (iOS/macOS), Phi Silica (Windows), and browser Prompt APIs (Web) — also
support function calling, but it is **prompt-based**: these OS models don't expose a usable
structured tool API, so core `InferenceChat` weaves the tool definitions into
the prompt and parses the calls back out of the model's text. You declare tools
the same way (see below). Gemini Nano handles single-turn tool calls; multi-turn
agent chaining is **not** supported on Web.

## Declaring tools

Describe each function as a `Tool` — a `name`, a `description`, and a
JSON-Schema `parameters` map — then pass the list to `createChat` (or
`openChat`) together with `supportsFunctionCalls: true`. `createSession` also
takes `tools:`, and the two passthrough families read them there, through the
runtime's own tool path: Gemma 4, and FunctionGemma on a `.litertlm`. For every
other model it is the chat that puts the tools into the prompt and parses the
calls back out, so use the chat API:

```dart
final tools = [
  const Tool(
    name: 'change_background_color',
    description: 'Change the app background color.',
    parameters: {
      'type': 'object',
      'properties': {
        'color': {'type': 'string', 'description': 'A CSS color name.'},
      },
      'required': ['color'],
    },
  ),
];

final chat = await model.createChat(
  tools: tools,
  supportsFunctionCalls: true,
  toolChoice: ToolChoice.auto,
);
```

`ToolChoice` controls whether the model may call a tool:

- `ToolChoice.auto` (default) — the model decides.
- `ToolChoice.required` — the model must respond with a function call.
- `ToolChoice.none` — the model must not call any tool. Where the SDK renders the
  declarations this takes them out of the prompt; on a `.litertlm` Gemma 4 or
  FunctionGemma the runtime already holds them, so the model can still emit a
  call — and with parsing off it reaches the stream as raw text.

<Info>
`ToolChoice.required` reaches the model only where the SDK writes the
declarations itself. Gemma 4, and FunctionGemma on a `.litertlm`, hand them to
the runtime instead, and the runtime's tool payload carries no `tool_choice` —
so for those two `required` behaves as `auto`, silently. A `.task`
FunctionGemma gets the old "not supported" warning, and the JSON-format
families (Qwen, DeepSeek, Phi-4 Mini) do get a "you must call a function"
instruction written into their prompt.
</Info>

## Who renders the declarations

On a `.litertlm`, both Gemma 4 and FunctionGemma go through LiteRT-LM's own tool
path: the declarations travel to the runtime as structured data, the call comes
back parsed, and the result of a turn goes back as one role-`tool` message that
continues the same model turn. Since **flutter_gemma 1.8.4 with
flutter_gemma_litertlm 1.7.1** that is true for FunctionGemma too — before them,
its tool results were sent as an ordinary user message, and the model answered
them by repeating the call it had just made. Both halves are needed: core decides
the wire format, the engine sends it.

Where a call comes back as text rather than structured `tool_calls` — the web
SDK, or a `.litertlm` exported without the FunctionGemma model type, whose
runtime opens no tool-call channel — flutter_edge_ai parses that text itself, so
your code still receives a `FunctionCallResponse`.

Two consequences worth knowing:

- Nothing in your code changes. `createChat(tools: ..., supportsFunctionCalls: true)`
  and the loop stay the same; the wire format is chosen from `modelType` and the
  file type together.
- `ToolChoice.none` cannot take the declarations back out, because the runtime
  holds them. It stops the SDK from suppressing tool-call text, which is why a
  call made under `none` can reach the bubble as raw markup.

On `.task` models through MediaPipe there is no native tool path, so
FunctionGemma keeps the text wire format the SDK renders itself.

FunctionGemma is also an action model, and that shows in the turn after the
result: `google/mobile-actions`, the corpus it is tuned on, does not contain a
single row where the assistant writes a sentence after a tool result, so it
often ends its turn at the call. Render the tool's own result in your UI rather
than waiting for prose, and reach for Gemma 4 when you want the model to talk
about what came back.

## Handling function calls

When the model wants to call a function, the response stream emits a
`FunctionCallResponse` with the function name and arguments. Execute it, then send
a `Message.toolResponse(...)` back to the model:

```dart
chat.generateChatResponseAsync().listen((response) {
  if (response is TextResponse) {
    // Regular text token
    print('Text token: ${response.token}');
  } else if (response is FunctionCallResponse) {
    // Model wants to call a function
    print('Function: ${response.name}');
    print('Arguments: ${response.args}');
    _handleFunctionCall(response);
  }
});
```

<Info>
A model can also request **several** calls at once — the stream then emits a
`ParallelFunctionCallResponse` carrying a `calls` list of `FunctionCallResponse`s.
`generateChatResponseWithTools` (below) handles this internally; a manual
listener must handle it too:

```dart
} else if (response is ParallelFunctionCallResponse) {
  for (final call in response.calls) {
    _handleFunctionCall(call);
  }
}
```
</Info>

Send the function result back to the model so it can continue:

```dart
final toolMessage = Message.toolResponse(
  toolName: 'change_background_color',
  response: {'status': 'success', 'color': 'blue'},
);
await chat.addQueryChunk(toolMessage);
final followUp = await chat.generateChatResponse();
```

### Or drive the whole loop in one call (recommended)

`InferenceChat.generateChatResponseWithTools` runs that whole cycle for you — it
streams the reply, and whenever the model calls a tool it invokes your
`onToolCall`, feeds the result back as a `Message.toolResponse`, and continues
until the model produces a final call-free answer (bounded by `maxToolTurns`).
You only implement the tools; the parse → execute → feed-back loop is handled.

```dart
final stream = chat.generateChatResponseWithTools(
  onToolCall: (call) async {
    // Run whatever tool the model asked for; return its result map.
    return switch (call.name) {
      'change_background_color' => {'status': 'success', 'color': call.args['color']},
      _ => {'error': 'unknown tool ${call.name}'},
    };
  },
  maxToolTurns: 8,           // safety cap on tool round-trips
  isCancelled: () => false,  // optional: return true to stop (e.g. barge-in)
);

await for (final response in stream) {
  if (response is TextResponse) print(response.token); // final-answer tokens
}
```

This is the same driver the voice loop uses: `VoiceSession.fromChat(…, onToolCall:)`
runs function calls inside a spoken turn through it (see
[Speech → Tool calling in the voice loop](/docs/speech#tool-calling-in-the-voice-loop)).

## Platform support

Function calling is supported on **Android, iOS, Web, and Desktop**. For Gemma 4,
the native function-call tokens are routed through the LiteRT-LM SDK chat-template
path (use `ModelType.gemma4`).

With the [Built-in AI](/docs/builtin-ai) engine (`flutter_edge_ai_builtin_ai`)
function calling is prompt-based rather than a native tool API — Gemini Nano
(Android), Apple Foundation Models (iOS/macOS), and Phi Silica (Windows) handle
single-turn tool calls; on Web multi-turn agent chaining is not supported. Tool
declarations are deliberately not handed to the OS runner as well, which would
run two competing tool loops for one turn. Apple's *native* tool calling stays
reachable through `flutter_local_ai`'s own `LocalAiSession` API, outside
flutter_edge_ai's chat loop.

<Warning>
Function calling works on the web `.litertlm` path, with one upstream caveat:
constrained decoding is left off there ([LiteRT-LM#2434](https://github.com/google-ai-edge/LiteRT-LM/issues/2434)
aborts the next turn after a tool call when it is on), so the call's JSON shape
is not grammar-enforced. See [Troubleshooting](/docs/troubleshooting).
</Warning>

See [Models](/docs/models#modeltype-reference) for the correct `ModelType` per
model family.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-function-calling`](/docs/package-skills), the skill that teaches it declaring tools, handling `FunctionCallResponse`, and the built-in tool loop.
