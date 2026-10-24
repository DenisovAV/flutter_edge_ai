---
title: Thinking Mode
description: View a model's reasoning, from a runtime thought channel or think tags, as separate thinking responses.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Thinking mode exposes the model's internal reasoning process as a separate
response channel, so you can show a "thinking" bubble in your UI before the final
answer.

## Supported models

Reasoning reaches you as `ThinkingResponse` in one of two ways:

- **A runtime thought channel** — any `ModelType`. A `.litertlm` bundle that
  declares the channel (Gemma 4 E2B/E4B, SmolLM3 3B, Phi-4 Mini Reasoning,
  Qwen3 4B Thinking 2507, …) streams its reasoning there, and the runtime
  splits it out.
- **`<think>` tags** — parsed by core for `ModelType.deepSeek`, `qwen`, `qwen3`
  and `qwen35` (e.g. DeepSeek R1, Qwen3).

**Qwen3 0.6B** (`ModelType.qwen3`) thinks by default. With `enableThinking: false`
flutter_edge_ai sends `enable_thinking: false` and appends ` /no_think` to each
text message — the only off switch for a bundle whose template ignores the flag.
Use `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` from
[litert-community/Qwen3-0.6B](https://huggingface.co/litert-community/Qwen3-0.6B),
or `Qwen3-0.6B.litertlm` from the same repo downloaded after the repo replaced
its tokenizer (2026-10-13, 15:53 UTC): a copy downloaded before that does not
load ([#659](https://github.com/DenisovAV/flutter_edge_ai/issues/659)).

Enable it with `enableThinking: true` and the matching `ModelType`. See
[Models](/docs/models) for which models think.

Some models always reason — DeepSeek R1, Qwen3 4B Thinking 2507. With
`enableThinking: false` their reasoning is hidden, not skipped: it still costs
time and output tokens, and flutter_edge_ai prints a one-time `NOTE` per chat
when it hides any.

<Warning>

Reasoning tags are parsed per `ModelType`, and only `deepSeek` and the Qwen
types have a tag parser — `general`, `phi` and the others have none. On a
`.litertlm` whose bundle declares a thought channel — **SmolLM3 3B** (`general`)
and **Phi-4 Mini Reasoning** (`phi`) among them — the runtime splits the
reasoning out and it arrives as `ThinkingResponse` whatever the type. Without a
channel, a model that reasons but runs as such a type emits no `ThinkingResponse`, and its
raw thinking blocks arrive inside the answer as ordinary `TextResponse` tokens.
Strip them yourself, or don't advertise a thinking UI for those models.

</Warning>

## Thinking budget

`LiteRtLmEngine(thinkingTokenBudget: 2048)` (`flutter_edge_ai_litertlm` 1.18.0)
caps how many tokens a turn with `enableThinking: true` spends thinking, in
every model that engine builds, on the CPU, the GPU and the NPU. Null, the
default, sets no budget. At the budget LiteRT-LM closes the thought channel and
the model goes on to its answer or tool call:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(thinkingTokenBudget: 2048)],
);
```

Without a budget a model can think until `maxOutputTokens` and end the turn
with an empty answer: Intel's Gemma 4 26B for its NPU did. Thinking tokens still
count towards `maxOutputTokens`, so leave room for the answer. The budget
applies to `.litertlm` bundles that stream their thinking through the `thought`
channel, as Gemma 4 does; the web engine accepts it and ignores it. Measured on
macOS with Gemma 4 E2B, greedy: a budget of 64 cut the thinking from 1724 to 198
characters on the CPU and from 1465 to 198 on the GPU, and the model still
answered.

## Handling thinking responses

The model emits a `ThinkingResponse` (with `response.content`) for its reasoning,
alongside regular `TextResponse` tokens for the final answer:

```dart
chat.generateChatResponseAsync().listen((response) {
  if (response is ThinkingResponse) {
    // Model's reasoning process
    print('Thinking: ${response.content}');
    _showThinkingBubble(response.content);
  } else if (response is TextResponse) {
    // The final answer
    print('Text token: ${response.token}');
  }
});
```

You can also create a thinking message manually:

```dart
final thinkingMessage = Message.thinking(text: "Let me analyze this problem...");
```

## Platform support

| Platform | Thinking Mode |
|---|---|
| Android | ✅ Full with `.litertlm`; tag-based models only with `.task` |
| iOS | ✅ Full with `.litertlm`; tag-based models only with `.task` |
| Desktop (macOS/Windows/Linux) | ✅ Full |
| Web | ✅ Full with `.litertlm` (Gemma 4 measured in Chrome); not on MediaPipe |

<Warning>

On Web, the <code>.litertlm</code> engine sends the same <code>enable_thinking</code> as native, and
Gemma 4 E2B returns <code>ThinkingResponse</code> in Chrome; core also splits the
<code>&lt;think&gt;...&lt;/think&gt;</code> tags a model emits there (e.g. through ONNX on web). MediaPipe Web has no
thinking API, ONNX ignores <code>enableThinking</code> (on Web and native alike, though
core still parses <code>&lt;think&gt;</code> tags a model emits), and the catalog's DeepSeek R1
<code>.task</code> model has no Web entry.

</Warning>

## Advanced: ModelThinkingFilter

For custom inference implementations, `ModelThinkingFilter` cleans model outputs —
removing model-specific tokens. This is handled automatically by the chat API,
but is available if you need it:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

String cleanedResponse = ModelThinkingFilter.cleanResponse(
  rawResponse,
  enableThinking: true,
  modelType: ModelType.deepSeek,
  fileType: ModelFileType.task,
);

// It removes the reasoning blocks (even when enableThinking is false):
// - <|channel>thought\n...<channel|> (a thought channel, every model type)
// - <think>...</think> (DeepSeek and the Qwen types); for DeepSeek, which
//   starts inside its reasoning, everything up to the first </think>
// and trims whitespace. Turn markers (<end_of_turn>, <|im_end|>) are stripped
// only for .bin / .tflite and .gguf files — on .task and .litertlm the runtime
// already ends the turn.
```
