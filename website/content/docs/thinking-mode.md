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
- **Qwen3 0.6B** — `ModelType.qwen3`; thinks by default. With `isThinking: false`
  flutter_edge_ai sends `enable_thinking: false` and appends ` /no_think` to each
  text message — the only off switch for a bundle whose template ignores the flag.
- **Any bundle with a thought channel** (e.g. Qwen3 4B Thinking 2507) — the
  runtime streams the reasoning on the channel, and it arrives as
  `ThinkingResponse` whatever the `ModelType`.

Enable it with `isThinking: true` and the matching `ModelType`.

<Warning>

Reasoning tags are parsed per `ModelType`, and `ModelType.general` has no tag
parser (a bundle's thought channel is still split out). Models that reason but run as `general` — **SmolLM3 3B**,
**Phi-4 Mini Reasoning** — emit no `ThinkingResponse`, and their thinking tags
are not stripped either: the raw blocks arrive inside the answer as ordinary
`TextResponse` tokens. Strip them yourself, or don't advertise a thinking UI for
those models.

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
| Web | ⚠️ Qwen3 tag-based reasoning only |

<Warning>

On Web, core can split Qwen3's emitted <code>&lt;think&gt;...&lt;/think&gt;</code> tags into
<code>ThinkingResponse</code> because that parser is platform-independent. Gemma 4 is a
different path: the <code>.litertlm</code> engine passes <code>extra_context</code> and filter config,
but the measured <code>web_thinking_limitation_test.dart</code> still receives only
<code>TextResponse</code>, so its thinking channel is unsupported. MediaPipe Web has no
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
  isThinking: true,
  modelType: ModelType.deepSeek,
  fileType: ModelFileType.task,
);

// It removes the reasoning blocks (for these model types even when
// isThinking is false):
// - <think>...</think> (DeepSeek, Qwen, Qwen3)
// - <|channel>thought\n...<channel|> (Gemma 3 / Gemma 4 types)
// and trims whitespace. Turn markers (<end_of_turn>, <|im_end|>) are stripped
// only for .bin / .tflite files — on .task and .litertlm the runtime already
// ends the turn.
```
