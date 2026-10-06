---
title: Thinking Mode
description: View the reasoning process of DeepSeek, Gemma 4, and Qwen3 models with thinking blocks.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Thinking mode exposes the model's internal reasoning process as a separate
response channel, so you can show a "thinking" bubble in your UI before the final
answer.

## Supported models

- **Gemma 4** (E2B, E4B) — `ModelType.gemma4`
- **DeepSeek R1** — `ModelType.deepSeek`
- **Qwen3 0.6B** — `ModelType.qwen3`; thinks by default. With `enableThinking: false`
  flutter_edge_ai sends `enable_thinking: false` and appends ` /no_think` to each
  text message — the only off switch for a bundle whose template ignores the flag.
- **Any bundle with a thought channel** (e.g. Qwen3 4B Thinking 2507) — the
  runtime streams the reasoning on the channel, and it arrives as
  `ThinkingResponse` whatever the `ModelType`.

Enable it with `enableThinking: true` and the matching `ModelType`.

Some models always reason — DeepSeek R1, Qwen3 4B Thinking 2507. With
`enableThinking: false` their reasoning is hidden, not skipped: it still costs
time and output tokens, and flutter_edge_ai prints a one-time `NOTE` per chat
when it hides any.

<Warning>

Reasoning tags are parsed per `ModelType`, and `ModelType.general` has no tag
parser. On a `.litertlm` whose bundle declares a thought channel — **SmolLM3 3B**
and **Phi-4 Mini Reasoning** among them — the runtime splits the reasoning out
and it arrives as `ThinkingResponse` whatever the type. Without a channel, a
model that reasons but runs as `general` emits no `ThinkingResponse`, and its
raw thinking blocks arrive inside the answer as ordinary `TextResponse` tokens.
Strip them yourself, or don't advertise a thinking UI for those models.

</Warning>

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
Gemma 4 E2B returns <code>ThinkingResponse</code> in Chrome; core also splits Qwen3's emitted
<code>&lt;think&gt;...&lt;/think&gt;</code> tags there. MediaPipe Web has no
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
import 'package:flutter_edge_ai/core/extensions.dart';

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
// only for .bin / .tflite files — on .task and .litertlm the runtime already
// ends the turn.
```
