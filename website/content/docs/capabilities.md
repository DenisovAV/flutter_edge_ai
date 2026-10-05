---
title: Capabilities
description: Which runtime gives you text generation, embeddings and speech on each platform, what each engine supports, and how to check support at runtime.
image: https://flutteredge.ai/images/og-image.png
---

Flutter Edge AI is modular: core runs nothing on its own, and each runtime you
add brings its own capabilities. This page shows what you can swap for what.

## What each runtime provides

| Runtime | Packages | Text generation | Embeddings | Speech-to-text | Text-to-speech |
|---|---|---|---|---|---|
| **LiteRT** | `flutter_edge_ai_litertlm`, `flutter_edge_ai_speech` | ✅ All | ✅ All | ✅ Native, ❌ Web | ✅ Native, ❌ Web |
| **ONNX Runtime** | `flutter_edge_ai_onnx` | ✅ All | ✅ All | ❌ | ❌ |
| **MediaPipe** | `flutter_edge_ai_mediapipe` | ✅ Android, iOS, Web | ❌ | ❌ | ❌ |
| **Built-in AI** (OS models) | `flutter_edge_ai_builtin_ai` | ✅ All except Linux | ❌ | ❌ | ❌ |

All means Android, iOS, macOS, Windows, Linux and Web; Native means all of
them except Web.

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
- Native libraries are built for arm64 on Android, iOS and macOS, and for x64
  on Windows and Linux.

## What each engine supports for text generation

| Engine | Vision | Audio | Function calling | Thinking |
|---|---|---|---|---|
| **LiteRT-LM** | ✅ Native, ❌ Web | ✅ Native, ❌ Web | ✅ Native for Gemma 4 and FunctionGemma, prompt-based for other models | ✅ Gemma 4 on native platforms, tag-based models everywhere |
| **MediaPipe** | ✅ | ✅ Android, iOS | Prompt-based, ⚠️ not Gemma 4 | Tag-based models |
| **ONNX** | ❌ | ❌ | Prompt-based, ⚠️ not Gemma 4 | Tag-based models |
| **Built-in AI** | ✅ Android, ⚠️ iOS and macOS 27+ | ❌ | Prompt-based; Apple Foundation Models also has native tools | ❌ |

- **Prompt-based function calling**: `InferenceChat` describes the tools in the
  prompt and parses the call out of the reply. **Native**: the engine hands the
  tools to the runtime; on native platforms LiteRT-LM also constrains decoding
  to the call format.
- **Gemma 4 function calling** needs LiteRT-LM (`.litertlm`). On MediaPipe and
  ONNX the tools do not reach a Gemma 4 model.
- **Built-in AI**: Apple Foundation Models (iOS and macOS 26+) has native tool
  calling. `BuiltInAiEngine` does not pass tools to it, because `InferenceChat`
  already runs the tool loop; you can reach it through the experimental
  `BuiltInAiModel.localAiModel`. Gemini Nano, Phi Silica and the Chrome Prompt
  API have no native tool calling. Phi Silica returns the whole reply as one
  chunk instead of streaming it.
- **Tag-based thinking**: models that write their reasoning between `<think>`
  tags (Qwen3, DeepSeek R1). Core parses the tags, so this works on any engine.
  Gemma 4's separate thinking channel needs LiteRT-LM on a native platform.

## Checking support at runtime

There is no single "what can this engine do" call. Support is settled in three
places.

**Which runtime runs a model** follows the file type you declare when you
install it (`ModelFileType`). If no registered engine can run it, creating the
model throws a `StateError` that names the package to add. Embedding backends,
speech backends and vector stores are chosen the same way.

**What the device can do** has explicit checks:

```dart
// OS models: is Gemini Nano, Apple Foundation Models or Phi Silica ready here?
final availability = await BuiltInAi.availability();

// OS models: native tool calling, vision, structured output.
// LocalAi comes from flutter_local_ai, which flutter_edge_ai_builtin_ai uses.
final caps = await LocalAi.capabilities();
final nativeTools = caps.supportsToolCalling;

// Vector stores: can a registered provider open this store on this platform?
final canOpen = rag.canOpen(spec);
```

**Model features are flags you set**: `supportImage` and `supportAudio` on
`getActiveModel`, `supportsFunctionCalls` and `isThinking` on `createChat`.
ONNX and Built-in AI throw `UnsupportedError` for image or audio input they
cannot take.

After a model loads, `InferenceModel.activeBackend` and
`EmbeddingModel.activeBackend` report the accelerator it actually runs on.
