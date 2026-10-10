---
title: Capabilities
description: Which runtime gives you text generation, embeddings and speech on each platform, what each engine supports, and how to check support at runtime.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Flutter Edge AI is modular: core runs nothing on its own, and each runtime you
add brings its own capabilities. This page shows what you can swap for what.

## What each runtime provides

| | LiteRT | ONNX Runtime | MediaPipe | Built-in AI |
|---|---|---|---|---|
| **Text generation** | ✅ All | ✅ All | ✅ Mobile + Web | ✅ All but Linux |
| **Embeddings** | ✅ All | ✅ All | — | — |
| **Speech-to-text** | ✅ Native | — | — | — |
| **Text-to-speech** | ✅ Native | — | — | — |

All means Android, iOS, macOS, Windows, Linux and Web; Native means all of
them except Web; Mobile means Android and iOS. The packages are
`flutter_edge_ai_litertlm` (plus `flutter_edge_ai_speech` for speech),
`flutter_edge_ai_onnx`, `flutter_edge_ai_mediapipe` and
`flutter_edge_ai_builtin_ai`.

So text generation has four interchangeable runtimes, embeddings have two
(LiteRT and ONNX, both on every platform), and speech has one (LiteRT, on
native platforms).

- **Embeddings**: LiteRT runs `.tflite` models (EmbeddingGemma, Gecko), ONNX
  runs `.onnx` models (MiniLM, EmbeddingGemma). Both take their tokenizer from
  `flutter_edge_ai_embeddings`. On the Web, ONNX embeddings accept WordPiece
  (BERT-style) models only.
- **Speech**: speech-to-text runs moonshine, Whisper and Parakeet on a finished
  recording (it does not stream); text-to-speech runs Matcha, Qwen3-TTS and
  Inflect. `VoiceSession` combines the two into a voice loop.
- **Built-in AI** uses the model the OS ships: Gemini Nano on Android, Apple
  Foundation Models on iOS and macOS 26+, Phi Silica on Windows, and the Chrome
  Prompt API on the Web.
- Native libraries are built for arm64 on Android, iOS and macOS, for x64 on
  Windows, and for x64 and arm64 on Linux (ONNX Runtime: Linux x64 only).

## What each engine supports for text generation

| | LiteRT-LM | MediaPipe | ONNX | Built-in AI |
|---|---|---|---|---|
| **Vision** | ✅ Native | ✅ | — | ✅ Android |
| **Audio** | ✅ Native | ✅ Mobile | — | — |
| **Function calling** | ✅ Native/Prompt | ✅ Prompt | ✅ Prompt | ✅ Prompt |
| **Thinking** | ✅ Full | ✅ Tags | ✅ Tags | — |

- **Function calling.** *Native*: the engine hands the tools to the runtime.
  LiteRT-LM does this for Gemma 4 and FunctionGemma, and on native platforms
  also constrains decoding to the call format; other models on LiteRT-LM use
  the prompt path. *Prompt*: `InferenceChat` describes the tools in the prompt
  and parses the call out of the reply, so it works with any model that follows
  the format.
- **Gemma 4 function calling** needs LiteRT-LM (`.litertlm`). On MediaPipe and
  ONNX the tools do not reach a Gemma 4 model.
- **Thinking.** *Tags*: models that write their reasoning between `<think>`
  tags (Qwen3, DeepSeek R1). Core parses the tags, so this works on any engine.
  *Full* adds Gemma 4's separate thinking channel, which needs LiteRT-LM
  (`.litertlm`) — native or web.
- **Built-in AI**: vision works on Android. On iOS and macOS it needs OS 27 and
  an app built with the OS 27 SDK, and is not verified on a device yet; on OS 26
  it is text-only. Apple Foundation Models (iOS and macOS 26+) also has native
  tool calling.
  `BuiltInAiEngine` does not pass tools to it, because `InferenceChat` already
  runs the tool loop; you can reach it through the experimental
  `BuiltInAiModel.localAiModel`. Gemini Nano, Phi Silica and the Chrome Prompt
  API have no native tool calling. Phi Silica returns the whole reply as one
  chunk instead of streaming it.

## Checking support at runtime

There is no single "what can this engine do" call. Support is settled in three
places.

**Which runtime runs a model** follows the file type you declare when you
install it (`ModelFileType`). If no registered engine can run it, creating the
model throws a `StateError` that names the package to add. Embedding and speech
backends are chosen the same way; a vector store is chosen by its
`VectorStoreSpec.providerId` among the providers passed to `FlutterEdgeAiRag`.

**What the device can do** has explicit checks:

```dart
// OS models: is Gemini Nano, Apple Foundation Models or Phi Silica ready here?
final availability = await BuiltInAi.availability();

// OS models: native tool calling, vision, structured output.
// LocalAi comes from flutter_local_ai, which flutter_edge_ai_builtin_ai uses;
// add it as a direct dependency to import it.
final caps = await LocalAi.capabilities();
final nativeTools = caps.supportsToolCalling;

// Vector stores: can a registered provider open this store on this platform?
// (rag: a FlutterEdgeAiRag instance)
final canOpen = rag.canOpen(spec);
```

**Model features are flags you set**: `supportImage` and `supportAudio` on
`getActiveModel`, `supportsFunctionCalls` and `enableThinking` on `createChat`.
ONNX, Built-in AI and LiteRT-LM on web throw `UnsupportedError` for image or
audio input they cannot take.

After a model loads, `InferenceModel.activeBackend` and
`EmbeddingModel.activeBackend` report the accelerator it actually runs on.
