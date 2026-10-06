# genkit_flutter_edge_ai

Genkit Dart plugin for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) — local, on-device LLM inference (Gemma, Qwen, Phi, DeepSeek, and more), fully offline.

<p align="center">
  <img src="https://raw.githubusercontent.com/DenisovAV/flutter_edge_ai/main/packages/genkit_flutter_edge_ai/assets/cover.jpeg" alt="genkit_flutter_edge_ai_cover">
</p>

> **Renamed from [`genkit_flutter_gemma`](https://pub.dev/packages/genkit_flutter_gemma).**
> Model and embedder ids are now `flutter-edge-ai/<name>` (they were
> `flutter-gemma/<name>`); `flutterEdgeAi.model(...)` builds them for you. 0.7.0
> drops the old Dart names; `dart fix --apply` renames them. See the
> [migration guide](https://flutteredge.ai/docs/migration).

## Features

- Wraps `flutter_edge_ai` as a Genkit model provider
- Supports text generation (blocking and streaming)
- Embeddings — register a `FlutterEdgeAiEmbedderConfig`, reference it with `flutterEdgeAi.embedder(...)`
- Multimodal input (images, audio) — supports `data:` URIs, `file://` paths, and `http(s)://` URLs
- Function calling / tool use with `toolChoice` control (`auto`, `required`, `none`) — honors Genkit's native top-level `toolChoice`
- Parallel tool calls — multiple function calls in a single model response
- Structured JSON output — pass an `outputSchema`, read the parsed object from `response.output`
- Context-window trimmer middleware (`trimContext`) — drops oldest turns to fit the on-device KV budget
- Thinking mode (Gemma 4, DeepSeek, Qwen3)
- Generation latency tracking via `latencyMs` in responses
- Configurable via `@Schema()`-annotated options

## Supported Model Architectures

| Architecture | ModelType | Notes |
|---|---|---|
| Gemma 4 | `ModelType.gemma4` | Multimodal (image, audio); thinking mode; native `.litertlm` tool-call tokens |
| Gemma 3 / Gemma3n IT | `ModelType.gemmaIt` | Gemma 3 text models and Gemma3n multimodal models |
| DeepSeek | `ModelType.deepSeek` | Thinking mode |
| Qwen / Qwen3 / Qwen3.5+ | `ModelType.qwen` / `ModelType.qwen3` / `ModelType.qwen35` | Qwen3 supports thinking mode |
| Llama | `ModelType.llama` | |
| Phi | `ModelType.phi` | Phi-4 |
| FunctionGemma | `ModelType.functionGemma` | Specialized function calling |

## Setup

`genkit_flutter_edge_ai` depends only on the **core** `flutter_edge_ai` package — it
stays engine-agnostic. Since the 1.0.0 architecture split (released under the
old `flutter_gemma` name), the inference engines and
embedding backends ship as **separate, opt-in packages**, and the core
registers none of them by default. Your app must add the packages it needs and
register their providers in `await FlutterEdgeAi.initialize()`.

| Package | Provider | Add it when you use… |
|---|---|---|
| `flutter_edge_ai_litertlm` | `LiteRtLmEngine()`, `LiteRtEmbeddingBackend()` | `.litertlm` models (Gemma 4, desktop) and/or text embeddings (EmbeddingGemma) |
| `flutter_edge_ai_mediapipe` | `MediaPipeEngine()` | `.task` / `.bin` models (Gemma 3, mobile/web) |
| `flutter_edge_ai_embeddings` | `GemmaEmbeddingTokenizers()` | text embeddings — required beside any embedding backend |

```yaml
# pubspec.yaml (your app)
dependencies:
  genkit_flutter_edge_ai: ^0.8.0
  flutter_edge_ai: ^2.1.0
  flutter_edge_ai_litertlm: ^1.9.0   # only the engines/backends you actually use
  flutter_edge_ai_embeddings: ^2.2.2  # the tokenizers an embedding backend needs
  flutter_edge_ai_mediapipe: ^1.1.0
```

```dart
// main() — register the providers from the packages you added above.
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
```

> If you skip registration, the first `getActiveModel` throws a `StateError`
> telling you to add the engine package.

## Quick Start

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
// Engines/backends are opt-in (see Setup) — register the ones you need.
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

// Initialize and install model (host app responsibility)
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
    .fromAsset('assets/gemma-3-1b-it-int4.task')
    .install();

// Create Genkit with plugin
final ai = Genkit(plugins: [
  GenkitFlutterEdgeAiPlugin(
    models: [
      FlutterEdgeAiModelConfig(
        name: 'gemma-3-nano',
        modelType: ModelType.gemmaIt,
      ),
    ],
    embedders: [
      FlutterEdgeAiEmbedderConfig(name: 'embedding-gemma-300m'),
    ],
  ),
]);

// Generate
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'Hello!',
);
print(response.text);
```

## Configuration

Pass `FlutterEdgeAiModelOptions` to customize inference:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'Hello!',
  config: FlutterEdgeAiModelOptions(
    maxTokens: 2048,
    temperature: 0.5,
    topK: 40,
    supportImage: true,
  ),
);
```

| Option | Type | Default | Description |
|---|---|---|---|
| `maxTokens` | `int?` | 1024 | **Context window** (input + output), not reply length — it goes straight into `getActiveModel(maxTokens:)`. To shorten replies, trim the prompt or use the context-window middleware; lowering this shrinks the KV cache. |
| `temperature` | `double?` | 0.8 | Sampling temperature |
| `topK` | `int?` | 1 | Top-K sampling |
| `topP` | `double?` | null | Top-P (nucleus) sampling |
| `supportImage` | `bool?` | false | Enable multimodal image input |
| `supportAudio` | `bool?` | false | Enable audio input (Gemma 4, Gemma3n) |
| `enableThinking` | `bool?` | false | Enable thinking mode (Gemma 4, DeepSeek, Qwen3) |
| `randomSeed` | `int?` | 1 | Random seed for deterministic output |
| `toolChoice` | `String?` | `'auto'` | Tool calling mode: `'auto'`, `'required'`, `'none'` |
| `systemInstruction` | `String?` | null | System-level instruction (overrides system-role messages) |
| `maxFunctionBufferLength` | `int?` | null | Max token buffer for streaming tool-call arguments (increase for large payloads) |
| `enableSpeculativeDecoding` | `bool?` | null | MTP speculative decoding for Gemma 4 E2B/E4B (null = model default, true/false = force on/off) |
| `preferredBackend` | `String?` | null | Text-decoder backend: `'cpu'`, `'gpu'`, `'npu'` (null = engine default) |
| `preferredVisionBackend` | `String?` | null | Vision-encoder backend: `'cpu'`, `'gpu'`, `'npu'` (null defaults to CPU; ignored by MediaPipe) |
| `preferredAudioBackend` | `String?` | null | Audio-encoder backend: `'cpu'`, `'gpu'`, `'npu'` (null defaults to CPU; set `'gpu'` for faster audio; ignored by MediaPipe) |

## Streaming

```dart
final stream = ai.generateStream(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'Write a story.',
);

final reply = StringBuffer();
await for (final chunk in stream) {
  reply.write(chunk.text); // update your UI with reply.toString()
}
```

## Tool Use

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'What is the weather in Paris?',
  tools: [weatherTool],
);
```

## Structured Output

The plugin advertises `output: ['text', 'json']`. On-device Gemma has no native
schema-constrained decoder, so Genkit's instruction-injection fallback drives
JSON output: the plugin returns raw model text and Genkit's `extractJson`
populates `response.output`. Pass an `outputSchema` (a `schemantic` type) and
read the parsed object:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'Give me a pancake recipe.',
  outputSchema: Recipe.$schema, // any @Schema()-annotated type
);

final Recipe? recipe = response.output;
```

## Context-Window Trimming

On-device models run with a fixed, small context window (`maxTokens` — 1024 for
most `.litertlm` models). A long multi-turn chat overflows it and the native
runtime fails to allocate the KV cache mid-generation. `trimContext()` is a
Genkit middleware that drops the oldest **non-system** turns before each model
call, always keeping every system message and the most recent message:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-nano'),
  prompt: 'Continue our conversation…',
  messages: longHistory,
  use: [trimContext(maxInputTokens: 800)],
);
```

With no arguments the budget is derived from the request's `maxTokens` (the
model's context window) minus 256 tokens of response headroom. Token counts are
estimated with a `chars / 4` heuristic; a contiguous suffix of recent turns is
kept, never a gap.

## Embeddings

```dart
// Install embedding model + tokenizer (host app responsibility)
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork('https://huggingface.co/.../embeddinggemma-300M.tflite')
    .tokenizerFromNetwork('https://huggingface.co/.../sentencepiece.model')
    .install();

// Generate embeddings
final embeddings = await ai.embed(
  embedder: flutterEdgeAi.embedder('embedding-gemma-300m'),
  documents: [
    DocumentData(content: [TextPart(text: 'Flutter is a UI toolkit.')]),
    DocumentData(content: [TextPart(text: 'Dart is a programming language.')]),
  ],
);

for (final embedding in embeddings) {
  print('Vector (${embedding.embedding.length} dims): '
      '${embedding.embedding.take(5)}...');
}
```

## Known Limitations

- **Engine registration**: In the current `flutter_edge_ai` architecture, inference engines and embedding backends are opt-in. The host app must add the relevant packages (`flutter_edge_ai_litertlm` for `.litertlm`, `flutter_edge_ai_mediapipe` for `.task`/`.bin`, `flutter_edge_ai_embeddings` plus a backend such as `flutter_edge_ai_litertlm`'s `LiteRtEmbeddingBackend` for embeddings) and register their providers in `await FlutterEdgeAi.initialize()` before using the plugin. This split first shipped as `flutter_gemma` 1.0.0.
- **Model installation**: The plugin does NOT manage model installation. The host app must install models via `FlutterEdgeAi.installModel()` and embedders via `FlutterEdgeAi.installEmbedder()` before using the plugin.
- **System role**: System messages are passed natively via `createChat(systemInstruction:)`. Only text content is supported in system messages. The capability first shipped under the old package name in `flutter_gemma` 0.13.0.
- **Thinking mode**: DeepSeek `.task` exposes thinking on Android/iOS; Gemma 4 exposes it through `.litertlm` engines, native and Web. Qwen3's emitted `<think>` tags are parsed by core platform-independently, including Web. MediaPipe Web has no thinking API, ONNX Web ignores `enableThinking`, and the catalog has no DeepSeek Web entry.
