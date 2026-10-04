# Flutter Edge AI

[![CI Tests](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml)
[![Release Build](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml)
[![pub package](https://img.shields.io/pub/v/flutter_edge_ai.svg)](https://pub.dev/packages/flutter_edge_ai)

**The plugin supports not only Gemma, but also other models. Here are the downloadable model families showcased in the example app:** [Gemma 4 E2B/E4B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm), [Gemma3n E2B/E4B](https://huggingface.co/google/gemma-3n-E2B-it-litert-preview), [FastVLM 0.5B](https://huggingface.co/litert-community/FastVLM-0.5B), [Gemma-3 1B](https://huggingface.co/litert-community/Gemma3-1B-IT), [Gemma 3 270M](https://huggingface.co/litert-community/gemma-3-270m-it), [FunctionGemma 270M](https://huggingface.co/sasha-denisov/function-gemma-270M-it), [Qwen3 0.6B](https://huggingface.co/litert-community/Qwen3-0.6B), [Qwen 2.5](https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct), [Phi-4 Mini](https://huggingface.co/litert-community/Phi-4-mini-instruct), [DeepSeek R1](https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B), [SmolLM 135M](https://huggingface.co/litert-community/SmolLM-135M-Instruct), [LFM2.5 230M](https://huggingface.co/litert-community/LFM2.5-230M), [SmolLM3 3B](https://huggingface.co/litert-community/SmolLM3-3B), [Phi-4 Mini Reasoning](https://huggingface.co/litert-community/Phi-4-mini-reasoning), [Qwen2-VL 2B](https://huggingface.co/litert-community/Qwen2-VL-2B), [SmolVLM2 500M](https://huggingface.co/litert-community/SmolVLM2-500M), [LLaVA-OneVision 0.5B](https://huggingface.co/litert-community/LLaVA-OneVision-0.5B), [TranslateGemma 4B](https://huggingface.co/google/translategemma-4b-it) (CPU-only). OS-provided models such as Gemini Nano, Apple Foundation Models, Windows AI Foundry, and the Chrome Prompt API are available through `flutter_edge_ai_builtin_ai` and do not require model downloads.

> **Note:** The `flutter_edge_ai` plugin supports Gemma 4 and Gemma3n (with **multimodal vision and audio support**), FastVLM, Qwen2-VL, SmolVLM2 and LLaVA-OneVision (vision), Gemma-3, FunctionGemma, Qwen3, Qwen 2.5, Phi-4 (incl. Phi-4 Mini Reasoning), DeepSeek R1, SmolLM, SmolLM3, LFM2.5, and TranslateGemma. LiteRT-LM uses `.litertlm` files on desktop; the opt-in ONNX engine instead installs a model directory on supported macOS arm64, Linux x64, and Windows x64 hosts.

[Gemma](https://ai.google.dev/gemma) is a family of lightweight, state-of-the art open models built from the same research and technology used to create the Gemini models

<p align="center">
  <img src="https://flutteredge.ai/images/og-image.png" alt="Flutter Edge AI — on-device LLMs in Flutter">
</p>

Bring the power of Google's lightweight Gemma language models and other on-device LLMs directly to your Flutter applications. With Flutter Edge AI, you can seamlessly incorporate advanced AI capabilities into your Flutter applications, all without relying on external servers.

## Features

- **Local Execution:** Run Gemma and other LLMs (Qwen, DeepSeek, Phi, FastVLM, SmolLM, …) directly on user devices for enhanced privacy and offline functionality.
- **Platform Support:** Compatible with iOS, Android, Web, macOS, Windows, and Linux platforms.
- **🧩 Modular Packages:** A small `flutter_edge_ai` core plus opt-in packages — add only the engine (`.litertlm` / `.task`), embeddings, RAG, agent, or speech code your app ships. Register them via one `await FlutterEdgeAi.initialize(...)` call. See [MIGRATION.md](MIGRATION.md).
- **🖥️ Desktop Support:** Native desktop apps (macOS, Windows, Linux) with GPU acceleration via LiteRT-LM, called directly from Dart through `dart:ffi` — no JVM/JRE bundling. See [DESKTOP_SUPPORT.md](DESKTOP_SUPPORT.md) for details.
- **🖼️ Multimodal Support:** Text + Image input with Gemma 4, Gemma3n, FastVLM, Qwen2-VL, SmolVLM2, and LLaVA-OneVision vision models (Gemma 4 on all platforms via its Web MediaPipe build; Gemma3n, Qwen2-VL, SmolVLM2, and LLaVA-OneVision on Android, iOS, and Desktop; FastVLM on Desktop). Gemma3n's Web `.litertlm` build is text-only.
- **🎙️ Audio Input:** Record and send audio messages with Gemma 4 and Gemma3n E2B/E4B models (Android, iOS device, macOS/Windows/Linux via LiteRT-LM — not on Web)
- **🎤 On-device Speech-to-Text:** Opt-in [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech) — transcribe audio fully offline with a selectable ASR model (moonshine, Whisper, Parakeet) via the LiteRT C API (Android, iOS, macOS, Windows, Linux; Web is a follow-on). Whisper is multilingual: `getActiveStt(language: 'de')` sets the output language and `transcribe(pcm, language: 'fr')` overrides it for one call — neither reloads the model
- **🔊 On-device Text-to-Speech:** Opt-in [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech) — synthesize speech fully offline with a selectable model (Matcha, Qwen3-TTS, Inflect-Nano-v2; kokoro / supertonic are follow-ons) via the LiteRT C API (Android, iOS, macOS, Windows, Linux; Web is a follow-on)
- **🗣️ On-device Voice Loop:** `VoiceSession` in [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech) chains STT → LLM → TTS into one push-to-talk turn with barge-in — the full on-device speech-to-speech pipeline. `VoiceSession.fromChat(recognizer:, chat:, synthesizer:)` streams `VoiceEvent`s from recorded PCM (native only).
- **🛠️ Function Calling:** Enable your models to call external functions and integrate with other services (supported by select models)
- **🤖 On-device Agent Skills:** Opt-in [`flutter_edge_ai_agent`](https://pub.dev/packages/flutter_edge_ai_agent) — give the model `SKILL.md` skills (text / JavaScript / native-intent / MCP) it invokes through the function-calling loop, fully offline. Gallery-compatible. Android, iOS, macOS, Windows (Web not supported yet).
- **🧠 Thinking Mode:** Receive structured reasoning from Gemma 4, DeepSeek R1, and Qwen3 on supported engines. SmolLM3 and Phi-4 Mini Reasoning generate reasoning as ordinary text because their catalog entries use `ModelType.general`.
- **🛑 Stop Generation:** Cancel text generation mid-process on Android, iOS, Web, and Desktop
- **⚡ Backend Switching:** Choose between CPU, GPU, and NPU backends per model — CPU/GPU/NPU on Android (`.litertlm`, Qualcomm Snapdragon for NPU), CPU/GPU on iOS and Desktop plus NPU on supported Intel Windows hardware; GPU for MediaPipe/LiteRT-LM Web, or CPU/WASM for ONNX Web
- **⚙️ NPU Acceleration:** Hardware NPU inference for `.litertlm` models on Qualcomm Snapdragon (Android) and Intel LunarLake/PantherLake (Windows)
- **🔍 Advanced Model Filtering:** Filter models by features (Multimodal, Function Calls, Thinking) with expandable UI (example app)
- **📊 Model Sorting:** Sort models alphabetically, by size, or use default order (example app)
- **LoRA Support:** Efficient fine-tuning and integration of LoRA (Low-Rank Adaptation) weights for tailored AI behavior.
- **📥 Enhanced Downloads:** Smart retry logic with exponential backoff for reliable model downloads
- **🔧 Download Reliability:** Automatic restart logic for interrupted downloads (resume not supported by HuggingFace CDN)
- **📱 Android Foreground Service:** opt in with `foreground: true` for large downloads, to bypass the 9-minute timeout
- **🔧 Model Replace Policy:** Configurable model replacement system (keep/replace) with automatic model switching
- **📊 Text Embeddings:** Generate 768-dim vector embeddings with EmbeddingGemma or Gecko (all native platforms + Web) via the unified LiteRT C API
- **🔎 On-device RAG:** Two vector-store backends — `flutter_edge_ai_qdrant` (qdrant-edge, native) and `flutter_edge_ai_sqlite` (in-SQLite `sqlite-vec`/`vec0` KNN on all six platforms incl. Web). Payload-aware `Filter` (must / should / mustNot) for semantic search.
- **🧩 Genkit Integration:** Use flutter_edge_ai through [Genkit](https://pub.dev/packages/genkit) via [`genkit_flutter_edge_ai`](https://pub.dev/packages/genkit_flutter_edge_ai), and route between on-device and cloud models with [`genkit_hybrid`](https://pub.dev/packages/genkit_hybrid).
- **🔧 Unified Model Management:** Single system for managing both inference and embedding models with automatic validation
- **🔐 Typed Download Errors:** Catch the public `DownloadException` sealed type (401/403/404/429/5xx) for gated HuggingFace models instead of substring-matching error strings
- **💾 Web Persistent Caching:** Models persist across browser restarts — Cache API for models <2GB, OPFS streaming for large ones (>2GB, e.g. Gemma 4 E4B) — no re-download on reload (Web only)

## Teach your AI assistant this package

`flutter_edge_ai` ships [agent skills](https://dart.dev/blog/skills-cli-1-0-bundle-and-distribute-ai-agent-skills-for-your-packages) — short instruction files your coding assistant reads so it uses this API correctly the first time:

```bash
dart run skills@ get --all
```

That scans your dependencies and installs every skill they bundle where your agent looks — Claude Code, Codex, Cursor, Antigravity, Cline, Copilot and OpenCode are supported. If it reports that it could not detect your agent, name it with `--agent claude` (or `codex`, `cursor`, …).

What they cover: registering an engine (core ships none), routing by the declared `ModelFileType` rather than the filename, and the two defaults that fail quietly — `maxTokens` is the context window and not the reply length, and `Message.isUser` defaults to `false`.

## What's new: flutter_gemma is now flutter_edge_ai

- **flutter_gemma is now flutter_edge_ai.** Every package has a new name; models, stores and platform setup carry over unchanged, and the old Dart names still compile as deprecated aliases. See [MIGRATION.md](MIGRATION.md#flutter_gemma--flutter_edge_ai-1114).

Through 1.11.3 this package shipped as `flutter_gemma`; `flutter_edge_ai` continues the numbering at 1.11.4.

## What's new in 1.9.0

- 🔤 **Embedding tokenizers are registered, not bundled.** Which tokenizer an embedding model needs is a property of the model, not of the engine that runs it — EmbeddingGemma wants SentencePiece under LiteRT and under ONNX alike. So the backends stopped carrying one: add `flutter_edge_ai_embeddings`, import it, and pass `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` beside `embeddingBackends:`. Miss it and the first embedding throws a `StateError` naming the package to add — it will not quietly tokenize with the wrong convention and hand you vectors from the wrong point in the embedding space. See [MIGRATION.md](MIGRATION.md).
- 🧩 **Engines no longer depend on the tokenizer package.** The registry let `flutter_gemma_litertlm` and `flutter_gemma_onnx` drop their dependency on `flutter_gemma_embeddings`; the contracts live in core, the implementations stay opt-in. The intentional exception to the general no-sibling rule is speech, which uses LiteRT-LM's shared native bundle.
- 🌐 **Web embeddings actually run** (`flutter_gemma_litertlm` 1.8.0) — the LiteRT.js bundle was rebuilt on `@litertjs/core` 2.5.3 and now lives, all four files together, in `flutter_edge_ai_litertlm/web/`. Copy them from there.
- 💾 **`flutter_gemma_rag_sqlite` 1.4.0 makes web `flush()` a real fence** by requiring sqlite3 3.6.0, and with it Flutter 3.47. An app on Flutter 3.44 resolves to 1.3.2 instead.

## What's new in 1.8.2

- 🤖 **Agent skills ship with the package** — `dart run skills@ get --all` installs eight skills that teach your coding assistant this API: inference (with platform setup), function calling, RAG, speech, MediaPipe, ONNX, built-in AI and diagnostics. Every code block in them is compiled against these packages before each release.

## What's new in 1.8.1

- 💾 **`VectorStoreRepository.flush()`** — a RAG index now survives the process; custom `VectorStoreRepository` implementations must declare it ([#492](https://github.com/DenisovAV/flutter_edge_ai/issues/492)).

## What's new in 1.8.0

- 🗣️ **Whisper output language per transcription** — `getActiveStt(language:)` sets the default and `transcribe(pcm, language:)` overrides it for one call, with no reload. **Breaking for custom `SpeechRecognizer` implementations**: `transcribe` gained `language:` and the type gained a `language` field ([#500](https://github.com/DenisovAV/flutter_edge_ai/issues/500)).

## What's new in 1.7.0

- 🤗 **One-call Hugging Face installs** — `fromHuggingFace(repo)` reads a repo's deployment manifest, picks the variant for the device and returns its tested runtime defaults; every engine carries its own resolver.

📖 Full docs & guides: **[flutteredge.ai](https://flutteredge.ai)**

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

## Model File Types

Flutter Edge AI supports different model file formats, which are grouped into **two types** based on how chat templates are handled:

### Type 1: SDK-managed templates
- **`.task` files:** MediaPipe-optimized format for Android, iOS, and Web-specific builds
- **`.litertlm` files:** LiteRT-LM format for Android, iOS, Desktop, and the early-preview Web runtime

The runtime applies the chat template — MediaPipe for `.task`, LiteRT-LM for `.litertlm` — so your code sends plain text on every platform, iOS included.

### Type 2: Manual Template Formatting
- **`.bin` files:** Standard binary format
- **`.tflite` files:** LiteRT format (formerly TensorFlow Lite)

Both formats require **manual chat template formatting** in your code.

**Note:** `ModelFileType` is what selects the engine — it is **not** inferred from the file name. `installModel` defaults it to `ModelFileType.task`, so declare it explicitly:
- `ModelFileType.litertlm` for `.litertlm` files. Omitting it routes the model to MediaPipe, which cannot read that format.
- `ModelFileType.task` for `.task` files
- `ModelFileType.binary` for `.bin` and `.tflite` files
- `ModelFileType.builtIn` for OS-provided models (Gemini Nano, Apple Foundation Models)

### Format by Platform

| Format | Android | iOS | Web | Desktop | Use Case |
|--------|:-------:|:---:|:---:|:-------:|----------|
| `.task` | ✅ | ✅ | ✅ | ❌ | Older models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4) |
| `.litertlm` | ✅ | ✅ ¹ | ⚠️ ² | ✅ | Newer models (Gemma 4, Qwen3, FastVLM + desktop for all) |
| `-web.task` | ❌ | ❌ | ✅ | ❌ | Web-specific MediaPipe builds (Gemma 4) |
| `.bin` | ✅ | ✅ | ✅ | ❌ | Manual chat template formatting required |
| `.tflite` | ✅ | ✅ | ✅ | ✅ | Embeddings only (EmbeddingGemma, Gecko) |

> ¹ iOS `.litertlm` runs on the FFI engine — vision and audio supported on physical devices. The Simulator stays CPU-only because Metal sim has a 256 MB single-allocation cap.
>
> ² Web `.litertlm` is an **early preview** via `@litert-lm/core` — text plus function calling. No vision, audio, Gemma 4 thinking channel or LoRA. Qwen3's emitted `<think>` tags are parsed by core on Web. For vision use a compatible MediaPipe `.task` build. See [Web `.litertlm` feature matrix](#web-litert-lm-early-preview-feature-matrix).

## Model Capabilities

The example app offers a curated list of models, each suited for different tasks. Here's a breakdown of the models available and their capabilities:

| Model Family | Best For | Function Calling | Thinking Mode | Vision | Languages | Size |
|---|---|:---:|:---:|:---:|---|---|
| **Gemma 4 E2B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ | ✅ | Multilingual | 2.4GB |
| **Gemma 4 E4B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ | ✅ | Multilingual | 4.3GB |
| **Gemma3n** | On-device multimodal chat and image analysis | ⚠️ Downloadable E4B `.litertlm`; local E2B `.task` fixture | ❌ | ✅ | Multilingual | 3-6GB |
| **FastVLM 0.5B** | Fast vision-language inference | ❌ | ❌ | ✅ | Multilingual | 0.5GB |
| **Qwen2-VL 2B** | Vision-language chat (image + text) | ❌ | ❌ | ✅ | Multilingual | 1.8GB |
| **SmolVLM2 500M** | Compact vision-language model | ❌ | ❌ | ✅ | Multilingual | 0.36GB |
| **LLaVA-OneVision 0.5B** | Compact vision-language model | ❌ | ❌ | ✅ | Multilingual | 0.83GB |
| **Phi-4 Mini** | Advanced reasoning and instruction following | ✅ | ❌ | ❌ | Multilingual | 3.9GB |
| **Phi-4 Mini Reasoning** | Step-by-step reasoning | ❌ | ⚠️ ‡ | ❌ | Multilingual | 2.8GB |
| **DeepSeek R1** | High-performance reasoning and code generation | ✅ | ✅ | ❌ | Multilingual | 1.7GB |
| **Qwen3 0.6B** | Compact multilingual chat with function calling | ✅ | ✅ | ❌ | Multilingual | 586MB |
| **Qwen 2.5** | Strong multilingual chat and instruction following | ✅ | ❌ | ❌ | Multilingual | 0.5-1.6GB |
| **Gemma 3 1B** | Balanced and efficient text generation | ❌ | ❌ | ❌ | Multilingual | 0.5GB |
| **Gemma 3 270M** | Ideal for fine-tuning (LoRA) for specific tasks | ❌ | ❌ | ❌ | Multilingual | 0.3GB |
| **FunctionGemma 270M** | Specialized for function calling on-device | ✅ | ❌ | ❌ | Multilingual | 284MB |
| **SmolLM 135M** | Ultra-compact, resource-constrained devices | ❌ | ❌ | ❌ | English | 135MB |
| **LFM2.5 230M** | Smallest entry; no HF token needed | ❌ | ❌ | ❌ | Multilingual | 168MB |
| **SmolLM3 3B** | Multilingual small LLM with reasoning mode | ❌ | ⚠️ ‡ | ❌ | Multilingual | 2.0GB |
| **TranslateGemma 4B** † | Single-shot 55-language translation | ❌ | ❌ | ❌ | 55 languages | 2-4GB |

† **TranslateGemma is CPU-only for now.** Google hasn't released a mobile/desktop `.litertlm` bundle (HF discussion [#5](https://huggingface.co/google/translategemma-4b-it/discussions/5) — "no concrete plans"). The example app uses a community-converted bundle from [`barakplasma/translategemma-4b-it-android-task-quantized`](https://huggingface.co/barakplasma/translategemma-4b-it-android-task-quantized), which publishes `.litertlm` artifacts. Both of them run correctly on `PreferredBackend.cpu` and return **only padding** on `PreferredBackend.gpu`: measured on an M4 Pro (Metal), `int4-generic` and `dynamic_int8-generic` each answered `Guten Morgen` on CPU and emitted 997 `<pad>` tokens and nothing else on GPU, from the same prompt and the same code. Nothing throws — the Metal engine is created, `activeBackend` reports `gpu`, and generation runs to the context limit. A `gemma-4-E2B-it.litertlm` bundle on the same machine, the same code path and the same backend answers correctly with no padding, so this is not the Metal path in general. Tracked upstream at [LiteRT-LM#1748](https://github.com/google-ai-edge/LiteRT-LM/issues/1748). Use CPU for this model (≈90 s prefill on a 4 B int4 bundle on M-series Macs).

‡ **Reasons, but emits no `ThinkingResponse`.** SmolLM3 and Phi-4 Mini
Reasoning use `ModelType.general`, which has no reasoning parser. Their
reasoning blocks arrive as ordinary answer text; setting `isThinking: true`
does not make them structured thinking models.

## ModelType Reference

When installing models, you need to specify the correct `ModelType`. Use this table to find the right type for your model:

| Model Family | ModelType | Examples |
|--------------|-----------|----------|
| **Gemma 4** | `ModelType.gemma4` | Gemma 4 E2B, Gemma 4 E4B (native function-call tokens) |
| **Gemma 3 / Gemma3n** | `ModelType.gemmaIt` | Gemma 3 1B, Gemma 3 270M, Gemma3n E2B/E4B |
| **DeepSeek** | `ModelType.deepSeek` | DeepSeek R1 |
| **Qwen 2.5** | `ModelType.qwen` | Qwen 2.5 1.5B, Qwen 2.5 0.5B |
| **Qwen 3** | `ModelType.qwen3` | Qwen3 0.6B |
| **FunctionGemma** | `ModelType.functionGemma` | FunctionGemma 270M IT |
| **Phi** | `ModelType.phi` | Phi-4 Mini |
| **General** | `ModelType.general` | FastVLM 0.5B, SmolLM 135M, LFM2.5 230M, SmolLM3 3B, Phi-4 Mini Reasoning, Qwen2-VL 2B, SmolVLM2 500M, LLaVA-OneVision 0.5B |

> **Note**: Gemma 4 (`ModelType.gemma4`) and FunctionGemma on a `.litertlm` route their native tool-call tokens through the LiteRT-LM SDK's chat-template path. For Gemma 3 and earlier, keep `ModelType.gemmaIt`; a `.task` FunctionGemma keeps the text format flutter_edge_ai renders itself.

**Usage Example:**
```dart
// Gemma models
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url).install();

// DeepSeek models
await FlutterEdgeAi.installModel(modelType: ModelType.deepSeek)
  .fromNetwork(url).install();

// Phi-4 (its own type — parses Phi's tool-call markers)
await FlutterEdgeAi.installModel(modelType: ModelType.phi)
  .fromNetwork(url).install();
```

## Installation

Since **1.0** (then `flutter_gemma`), the plugin is split into a small **core** package plus
**opt-in** packages for each engine / backend, so your app only pulls the native
weight it actually uses. Add the core package, then the packages for the
model formats and features you need.

1.  Add the core package and the opt-in packages you need to `pubspec.yaml`:

    ```yaml
    dependencies:
      flutter_edge_ai: latest_version              # Core — always required (no engine on its own)

      # Inference engines — add at least one:
      flutter_edge_ai_litertlm: latest_version     # .litertlm models (FFI; mobile + desktop + web)
      flutter_edge_ai_mediapipe: latest_version    # .task / .bin models (MediaPipe; mobile + web)
      flutter_edge_ai_builtin_ai: latest_version   # OS system models — Gemini Nano (Android) / Apple FM (iOS 26+/macOS) / Windows AI Foundry / Chrome Prompt API (Web)
      flutter_edge_ai_onnx: latest_version         # ONNX Runtime — ORT-GenAI text gen + ORT embeddings (FFI, native) / Transformers.js + onnxruntime-web (Web)

      # Optional — text embeddings (EmbeddingGemma / Gecko via flutter_edge_ai_litertlm's
      # LiteRtEmbeddingBackend — see the "Inference engines" section above) + on-device RAG:
      flutter_edge_ai_qdrant: latest_version   # RAG vector store (native: qdrant-edge)
      flutter_edge_ai_sqlite: latest_version   # RAG vector store (sqlite-vec/vec0; all six platforms incl. web)

      # Optional — on-device agent skills:
      flutter_edge_ai_agent: latest_version        # SKILL.md skills (text / JS / native-intent / MCP) via tool-calling

      # Optional — on-device speech (STT + TTS + voice loop):
      flutter_edge_ai_speech: latest_version       # speech: STT + TTS + push-to-talk voice loop (native only)

      # Optional — memory diagnostics (Android + iOS):
      flutter_edge_ai_diagnostics: latest_version  # what a model costs in memory the OS cannot reclaim, read from the OS
    ```

    **Pick by need:**

    | You want to… | Add |
    |---|---|
    | Run `.litertlm` models (Gemma 4, Qwen3, FastVLM, + all desktop) | `flutter_edge_ai_litertlm` |
    | Run `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4) | `flutter_edge_ai_mediapipe` |
    | Run ONNX models — ORT-GenAI (macOS/Linux/Windows/Android/iOS arm64) or Transformers.js (Web) | `flutter_edge_ai_onnx` |
    | Generate text embeddings | `flutter_edge_ai_litertlm` (`LiteRtEmbeddingBackend`) |
    | Generate text embeddings from ONNX/ORT models | `flutter_edge_ai_onnx` (`OnnxEmbeddingBackend`) |
    | On-device RAG on native (fastest on Android/iOS/desktop) | `flutter_edge_ai_qdrant` |
    | On-device RAG on any platform incl. web (portable `sqlite-vec`) | `flutter_edge_ai_sqlite` |
    | On-device agent skills (SKILL.md + tool-calling loop) | `flutter_edge_ai_agent` |
    | Transcribe audio, synthesize speech, or run a voice loop on-device (STT + TTS + voice) | `flutter_edge_ai_speech` |
    | Measure what a model costs in memory the OS cannot reclaim (Android + iOS) | `flutter_edge_ai_diagnostics` |

    Core registers **no** engine by itself — you wire the packages you added in
    `await FlutterEdgeAi.initialize(...)` (see [Initialize Flutter Edge AI](#initialize-flutter-edge-ai)).

2.  Run `flutter pub get` to install.

> **Migrating from 0.16.x (monolith)?** See **[MIGRATION.md](MIGRATION.md)** — the
> only breaking change is adding the opt-in packages and the `initialize(...)`
> call; every model / session / RAG API is unchanged.

## Platform & Architecture Support

The plugin ships native prebuilts only for the architectures below. Other ABIs fail at native load with a typed error.

| Platform        | Supported architecture            | Not supported            |
|-----------------|-----------------------------------|--------------------------|
| Android         | `arm64-v8a` (full)                | `armeabi-v7a`, `x86_64`¹ |
| iOS device      | `arm64`                           | —                        |
| iOS Simulator   | `arm64` (Apple Silicon Mac)       | `x86_64` (Intel Mac)     |
| macOS           | `arm64` (Apple Silicon)           | `x86_64` (Intel Mac)     |
| Linux           | `x86_64`, `arm64`                 | —                        |
| Windows         | `x86_64`                          | `arm64`                  |

¹ MediaPipe text inference (`.task` / `.bin`) on Android also works on `x86_64` and `armeabi-v7a` because Google ships those ABIs in `tasks-genai`. Everything backed by `libLiteRtLm` (`.litertlm` inference including its vision and audio input, embedding via LiteRT FFI, speech) is `arm64-v8a` only:

| Android feature                      | arm64-v8a | x86_64 | armeabi-v7a |
|--------------------------------------|:---------:|:------:|:-----------:|
| Text inference (`.task` / `.bin`)    |     ✅    |   ✅   |      ✅      |
| `.litertlm` (FFI)                    |     ✅    |   ❌   |      ❌      |
| Embedding (LiteRT FFI)               |     ✅    |   ❌   |      ❌      |
| Speech STT + TTS (LiteRT FFI)        |     ✅    |   ❌   |      ❌      |

If your Android app uses only the arm64-only features, restrict the build to arm64 so the Play Store does not offer broken APKs to incompatible devices:

```gradle
android {
    defaultConfig {
        ndk { abiFilters 'arm64-v8a' }
    }
}
```

For development, prefer an Apple Silicon Mac — the Android emulator runs `arm64-v8a` natively, and macOS / iOS Simulator builds are arm64.

## Setup

> **⚠️ Important:** Complete platform-specific setup before using the plugin.

1. **Download Model and optionally LoRA Weights:** Obtain a model from the [Supported Models](#-supported-models) section or [HuggingFace](https://huggingface.co/litert-community)
* For **multimodal support**, download [Gemma3n models](https://huggingface.co/google/gemma-3n-E2B-it-litert-preview) or [Gemma3n in LitertLM format](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm) that support vision input
* Optionally, use [litetune](https://litetune.dev) to fine-tune a small model, convert it to `.litertlm`, and measure conversion quality before shipping. litetune is currently alpha software.
* If you have LoRA weights, you can use them to customize the model's behavior without retraining the entire model.
* [There is an article that described all approaches](https://medium.com/@denisov.shureg/fine-tuning-gemma-with-lora-for-on-device-inference-android-ios-web-with-separate-lora-weights-f05d1db30d86)
2. **Platform specific setup:**

**iOS** — required by any engine package: `flutter_edge_ai_litertlm`, `flutter_edge_ai_mediapipe` and/or `flutter_edge_ai_builtin_ai`

* **Set the minimum iOS version to 15.0** — or **16.0** if your app depends on
  `flutter_edge_ai_mediapipe`, which needs MediaPipe GenAI. Core,
  `flutter_edge_ai_litertlm` and embeddings build from 15.0. (Requires
  `flutter_gemma` 1.6.4 or newer; earlier versions declared 16.0.)

* **`flutter_edge_ai_builtin_ai` sets no Apple floor of its own** — its
  native layer is `flutter_local_ai`, which builds from **iOS 13.0 / macOS
  12.0**. iOS is unaffected (core's 15.0 still wins); on **macOS the floor rises
  from 10.15 to 12.0**, and a lower deployment target fails resolution with a
  message naming the `flutter_local_ai` pod rather than the package you added.

  **Where you set it depends on the dependency manager.** Swift Package Manager is the
  default since Flutter 3.44 (opt-in before that), and an SPM-only app has no `Podfile` at all — set
  **iOS Deployment Target** on the Runner target in Xcode, or the build fails with
  `requires minimum platform version 15.0 … but this target supports 13.0`.
  `flutter_edge_ai_mediapipe` ships no `Package.swift`, so an app using it also gets a
  `Podfile`; set the platform there as well:

```ruby
platform :ios, '16.0'   # 15.0 if the app does not use flutter_edge_ai_mediapipe
```

  Declare `platform` only once — CocoaPods rejects a second one with
  `Invalid Podfile file: The target 'Pods' already has a platform set`.

* **Enable file sharing** in `Info.plist`:
```plist
<key>UIFileSharingEnabled</key>
<true/>
```

* **Add network access description** in `Info.plist` (for development):
```plist
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires local network access for model inference services.</string>
```

* **Enable performance optimization** in `Info.plist` (optional):
```plist
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

* **Add memory entitlements** in `Runner.entitlements` (for large models):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
	<true/>
</dict>
</plist>
```

* **Change the linking type** of pods to static in `Podfile`:
```ruby
use_frameworks! :linkage => :static
```

> No host-side `Podfile` `post_install` is required on iOS — flutter_edge_ai patches the upstream LiteRT-LM `dlopen` path to use `@executable_path/Frameworks/<X>.framework/<X>` so dyld resolves Metal accelerators directly through the Native-Assets-bundled framework. This also keeps `Runner.app/Frameworks/` App-Store-clean (fixes ITMS-90432, see #245).

**Android**

* **Add-to-app hosts must declare the Kotlin Gradle Plugin themselves.** Flutter
  auto-applies KGP to plugin modules only when the host provides it, so a Java-only
  native host fails with `Could not find method kotlin()`. Add KGP to the host's root
  `buildscript`/`plugins {}`. A normal `flutter build` app needs nothing — Flutter's
  own Gradle plugin carries KGP.

**GPU: nothing to add.** Since 1.2.0 (as `flutter_gemma`) the core plugin's own manifest declares the
OpenCL entries, and the manifest merger folds them into your app. If you pin or audit
the merged manifest, it must contain these — `libvndksupport.so` above all: without
it the OpenCL driver load is denied on Android 12+, the engine falls back to WebGPU,
and some Mali GPUs hard-freeze (#324). `libcdsprpc.so` is for the Qualcomm NPU.

```xml
<uses-native-library android:name="libvndksupport.so" android:required="false"/>
<uses-native-library android:name="libOpenCL.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-car.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-pixel.so" android:required="false"/>
<uses-native-library android:name="libcdsprpc.so" android:required="false"/>
```

* **ProGuard/R8 (only if you use `flutter_edge_ai_mediapipe`):** the package ships
  its own consumer ProGuard rules; from 1.0.6 a release build needs no rules in
  your app (built on AGP 9.1). On 1.0.5 and earlier R8 fails the release build
  with `Missing class` (seen on AGP 9) — upgrade to 1.0.6, or add to your
  `proguard-rules.pro`:

```proguard
-dontwarn com.google.auto.value.**
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
```

  If a release build then fails at run time with `UnsatisfiedLinkError` or a
  missing MediaPipe class, also add:

```proguard
# MediaPipe
-keep class com.google.mediapipe.** { *; }

# Protocol Buffers
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
```

> `flutter_edge_ai_litertlm` is delivered as a Native-Assets dylib (no MediaPipe
> Java classes), so it needs no ProGuard rules.

**Web**

On web, MediaPipe ignores `preferredBackend` and always runs on the GPU
(WebGPU); ONNX honours `PreferredBackend.cpu` by pinning WASM.

**Every web app** needs the model storage helpers. Copy `cache_api.js` and
`opfs_helper.js` from this package's `web/` directory into your app's `web/`
(find the package directory with
`grep -A1 '"name": "flutter_edge_ai"' .dart_tool/package_config.json`), then load
them in `web/index.html`:

```html
  <script src="cache_api.js"></script>
  <script src="opfs_helper.js"></script>
```

Then add the CDN script(s) for the **engine package(s) you use**.

* **`flutter_edge_ai_mediapipe`** (`.task` / `-web.task` models) — add:
```html
  <script type="module">
  import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
  window.FilesetResolver = FilesetResolver;
  window.LlmInference = LlmInference;
  </script>
```

* **`flutter_edge_ai_litertlm`** (`.litertlm` web models — early preview) — add the
  handshake below. The `@litert-lm/core` ESM doesn't assign window globals and
  module scripts are deferred, so Dart must await `window.litertLmReady` (which
  resolves to the `Engine` constructor) before any static interop:
```html
  <script type="module">
  window.litertLmReady = (async () => {
    const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
    window.Engine = m.Engine;
    return m.Engine;
  })();
  </script>
```

* **`flutter_edge_ai_onnx`** (ONNX models on web) — generation runs on
  Transformers.js, embeddings on onnxruntime-web. Add the shim for whichever
  arm(s) you register:
```html
  <script type="module">
  window.transformersReady = (async () => {
    const m = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.0');
    window.transformers = m;
    return m;
  })();
  </script>

  <script type="module">
  window.ortReady = (async () => {
    const m = await import('https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/ort.bundle.min.mjs');
    m.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/';
    window.ort = m;
    return m;
  })();
  </script>
```

* **`LiteRtEmbeddingBackend`** (web embeddings, `flutter_edge_ai_litertlm`) — copy
  the four files in `flutter_edge_ai_litertlm`' `web/` into your own `web/`
  (`litert_embeddings.js`, `sentencepiece.js`, `litert.js`, `tensorflow.js` —
  one bundle in four pieces) and load the entry module locally:
  `<script type="module" src="litert_embeddings.js"></script>`. The WASM runtime
  comes from a pinned CDN by default; see the
  [`flutter_edge_ai_litertlm` embeddings on web](https://pub.dev/packages/flutter_edge_ai_litertlm#embeddings-on-web).

* **`flutter_edge_ai_sqlite`** (web RAG) — copy the package's custom
  `sqlite3.wasm` (with `sqlite-vec`/`vec0` statically linked) into your app's web
  root as `rag/sqlite3.wasm`, and serve the app with
  `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`. No CDN `<script>` needed; see
  that package's README.

> **Model compatibility:** mobile `.task` models often don't work on web — use
> the `-web.task` (MediaPipe) or `.litertlm` (LiteRT-LM) web variant. Check the
> model repo for web-compatible builds.

**Desktop (macOS, Windows, Linux)** — use **`flutter_edge_ai_litertlm`** for
`.litertlm` models or **`flutter_edge_ai_onnx`** for directory-based ONNX models
on its supported desktop architectures

> **⚠️ Desktop Model Format**
>
> Desktop is served primarily by the **`flutter_edge_ai_litertlm`** package
> (`.litertlm` files); `flutter_edge_ai_onnx` also runs on all three desktop OSes,
> and `flutter_edge_ai_builtin_ai` runs Apple Foundation Models on macOS. There is
> no MediaPipe engine on desktop — `.task` / `.bin` models used on mobile/web are
> **NOT compatible** with desktop. (`flutter_edge_ai_embeddings` and
> `flutter_edge_ai_qdrant` / `flutter_edge_ai_sqlite` also support desktop.)
>
> The native library is fetched at build time by the package's Native-Assets
> hook — no manual download/bundling. The setup below applies to
> `flutter_edge_ai_litertlm`.

Inference (LiteRT-LM C API) and embeddings (LiteRT C API) on all native platforms run via `dart:ffi` directly in the Dart process — no JVM, no gRPC, no separate server. Native libraries are downloaded by `hook/build.dart` (Native Assets) at build time and bundled into the app automatically.

| Platform | Architecture | GPU Acceleration | Status |
|----------|-------------|------------------|--------|
| macOS | arm64 (Apple Silicon) | Metal | ✅ Ready |
| macOS | x86_64 (Intel) | - | ❌ Not Supported |
| Windows | x86_64 | DirectX 12 | ✅ Ready ² |
| Windows | arm64 | - | ❌ Not Supported |
| Linux | x86_64 | Vulkan | ✅ Ready ¹ |
| Linux | arm64 | Vulkan | ✅ Ready ¹ |

> ¹ Linux GPU requires a proper vendor Vulkan driver (NVIDIA / AMD / Intel). Mesa's `llvmpipe` software fallback is not sufficient for Gemma 4 — its hardcoded 128 MB `maxStorageBufferRange` is below the model's per-buffer requirement. Install the vendor driver (e.g. `nvidia-driver-535-server` on Ubuntu) before running on GPU.
>
> ² **Fixed in litertlm 1.4.0:** Windows **discrete GPUs** crashed on `PreferredBackend.gpu` in litertlm 1.2.0–1.3.1. Upgrade to 1.4.0; on the affected versions use `PreferredBackend.cpu` or `.npu`. macOS/Linux GPU and Windows CPU/NPU were never affected.

### macOS Setup

macOS requires a small `post_install` block in your
`macos/Podfile`. The Apple companion dylibs Google ships upstream
(`libGemmaModelConstraintProvider.dylib`, `libLiteRtMetalAccelerator.dylib`)
were linked without
`-Wl,-headerpad_max_install_names`, so Dart Native Assets' JIT bundling path
(used by `dart run` / `dart build_runner` / `flutter test` on a pure Dart
library) cannot rewrite their install_name to a long absolute path inside
`.dart_tool/lib/` and aborts (#247). To unblock both `dart run` and
`flutter build macos`, the plugin's `hook/build.dart` skips bundling those
two through Native Assets on macOS, and we instead copy them into
`App.app/Contents/Frameworks/` ourselves and patch `LiteRtLm.dylib`'s
`LC_LOAD_DYLIB` reference to the new framework path.

Paste this into your `macos/Podfile` (replacing any existing
`post_install` block) and run `pod install`:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  # flutter_gemma: stage the upstream Apple companion dylibs into the built
  # .app. `hook/build.dart` deliberately skips them from Native Assets on macOS
  # (#247 — Google ships them without `-Wl,-headerpad_max_install_names`, so the
  # JIT bundling path cannot rewrite their install_name), which leaves this
  # build phase to stage them.
  #
  # The phase only LOCATES and RUNS a script; the staging logic itself lives in
  # flutter_gemma_litertlm and is delivered next to the dylibs it stages. That
  # is deliberate: this block is frozen into your Xcode project, and a copy of
  # the logic frozen there cannot be fixed by upgrading the package.
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_targets.each do |user_target|
      phase_name = '[flutter_gemma] Setup LiteRT-LM macOS'

      # Only the app target embeds the Frameworks/ this phase patches.
      # RunnerTests inherits Runner's framework search paths and has no
      # Contents/Frameworks of its own — having the phase there creates a
      # cross-target dependency on Runner's framework output that Xcode reports
      # as "Cycle inside Flutter Assemble" (#300). Remove any stale copy from
      # non-app targets and skip them.
      unless user_target.name == 'Runner'
        user_target.build_phases
          .select { |p| p.respond_to?(:name) && p.name == phase_name }
          .each { |p| user_target.build_phases.delete(p) }
        next
      end

      existing = user_target.shell_script_build_phases.find { |p| p.name == phase_name }
      phase = existing || user_target.new_shell_script_build_phase(phase_name)
      # The embedded LiteRtLm binary is an INPUT so the phase re-runs whenever
      # Flutter's always-out-of-date `embed` phase re-copies the raw, unpatched
      # binary over the patched one. Without it Xcode caches the phase after the
      # first build and the second incremental build ships an unpatched
      # LiteRtLm that fails dlopen at runtime (#368).
      phase.input_paths = [
        '$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
      ]
      # A declared output lets Xcode order the phase in its dependency graph
      # instead of treating it as "runs every build with no outputs" — the other
      # half of the cycle warning (#300). The script touches this file.
      phase.output_paths = ['$(DERIVED_FILE_DIR)/flutter_gemma_litertlm_macos.stamp']
      phase.shell_script = <<~SHELL
        set -e
        STAGER="${HOME}/Library/Caches/flutter_gemma/native/macos_arm64/stage_macos_companions.sh"
        if [ ! -f "${STAGER}" ]; then
          echo "[flutter_gemma] ERROR: ${STAGER} not found." >&2
          echo "  flutter_gemma_litertlm 1.6.2+ installs it there from its build hook." >&2
          echo "  Upgrade the package, then: flutter clean && flutter pub get" >&2
          exit 1
        fi
        sh "${STAGER}" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        touch "${SCRIPT_OUTPUT_FILE_0}"
      SHELL
    end
  end
end
```

Add to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` lets the sandboxed app download a model — without it the request
fails with `Operation not permitted`. `disable-library-validation` takes effect
once Hardened Runtime is on, which notarization requires: the build phase above
signs LiteRT-LM and its companion libraries ad hoc. Do not add the iOS
`com.apple.developer.kernel.*` memory entitlements here — they are iOS-only, and
without a signing team they fail the build.

**Windows Setup:**

No additional configuration required. `hook/build.dart` (Native Assets) downloads `LiteRtLm.dll` + companion DLLs + the DXC runtime (`dxil.dll`, `dxcompiler.dll` v1.9.2602) from the GitHub release on first build, verifies them via SHA256, and bundles them next to your `app.exe`. End users need nothing installed: since `flutter_gemma_litertlm` 1.7.1 `LiteRtLm.dll` is linked against the static CRT and imports no CRT at all, and 16 of the bundle's 24 DLLs import none. The other eight are the Intel NPU stack behind `PreferredBackend.npu` — our own `LiteRtDispatch.dll` plus Intel's `openvino*`/`tbb*` — which need only what a Flutter Windows app already resolves, and are loaded only when that backend is selected ([#456](https://github.com/DenisovAV/flutter_edge_ai/issues/456)).

**Linux Setup:**

No additional configuration required. Build dependencies:
```bash
sudo apt install clang cmake ninja-build libgtk-3-dev lld
```

For GPU acceleration, install the vendor Vulkan driver (NVIDIA / AMD / Intel) in addition to the Vulkan loader. Mesa's `llvmpipe` software fallback caps `maxStorageBufferRange` at 128 MB and Gemma 4 will not run on it.

```bash
sudo apt install vulkan-tools libvulkan1
# Plus your vendor driver, e.g. NVIDIA:
sudo apt install nvidia-driver-535-server
```

📚 **[Full Desktop Documentation →](DESKTOP_SUPPORT.md)**

## Quick Start

> **⚠️ Important:** Complete [platform setup](#setup) before running this code.

### 1. Install a Model (One Time)

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// Install model. URL example uses the .litertlm variant so the same code
// works on Desktop (Windows/macOS/Linux) and mobile/web. For web only, the
// `.task`/`-web.task` variants of the same model also work.
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
).fromNetwork(
  'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
  token: 'your_hf_token',
).withProgress((progress) {
  print('Downloading: $progress%');
}).install();
```

> **Mobile/Web shortcut:** if you don't target Desktop, you can substitute the URL with the `.task` build of the same model. Desktop targets need the `.litertlm` build — `.task` and `.bin` are MediaPipe-only.

### 2. Create and Use Model (Multiple Times)

```dart
// Create model with specific configuration
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 2048,
  preferredBackend: PreferredBackend.gpu,
);

// Use model
final chat = await model.createChat();
await chat.addQueryChunk(Message.text(
  text: 'Explain quantum computing',
  isUser: true,
));
final response = await chat.generateChatResponse();

// Cleanup
await model.close();
```

> **`maxTokens` vs `maxOutputTokens` — don't confuse them.**
> `maxTokens` is the **context window**: the total budget shared by the input
> (system prompt + history + your message) **and** the generated reply — i.e.
> the KV-cache size. It is **not** the response length. `.litertlm` models
> require a context window of at least **1024**; passing a smaller `maxTokens`
> (e.g. `100`) used to crash with `DYNAMIC_UPDATE_SLICE` and is now clamped up
> to 1024 automatically (#318).
>
> To limit how many tokens the model **generates**, use `maxOutputTokens` on
> `createSession` / `openSession` / `createChat` / `openChat` instead:
> ```dart
> final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024); // context
> final chat = await model.createChat(maxOutputTokens: 100);        // reply cap
> ```
> (`maxOutputTokens` is honored on `.litertlm`; MediaPipe `.task` has no
> session-level output cap and ignores it.)

### System Instructions

Control model behavior with a system-level instruction:

```dart
final chat = await model.createChat(
  systemInstruction: 'You are a concise assistant. Always respond in bullet points.',
);
```

**Platform support:**
- **Android `.litertlm` / Desktop**: Passed natively via `ConversationConfig.systemInstruction`
- **Android `.task` / iOS / Web**: Prepended to first user message as fallback

### 3. Multiple Instances from Same Model

```dart
// Install once
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url).install();

// Create multiple instances
final quickModel = await FlutterEdgeAi.getActiveModel(maxTokens: 512);
final deepModel = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
// Both use the SAME model file!
```

### Concurrent sessions (`openSession`)

A single loaded model can serve several **independent** dialogues at once.
`openSession()` returns a session with its own conversation history,
detached from the legacy `model.session` singleton; `openChat()` is the
same for the higher-level chat API.

**Why use it.** The model weights (the big, expensive part — hundreds of MB
to several GB) are loaded **once** and shared across every session; each
session only adds its own lightweight conversation context. Without
`openSession`, serving two independent conversations would mean either
loading the model twice (doubling the weight memory) or constantly clearing
and rebuilding one session's history when you switch between them.

**When you'd reach for it:**
- **Multiple chats in one app** — e.g. a tabbed chat UI where each tab keeps
  its own thread, all backed by one loaded model.
- **Different roles / system instructions side by side** — one session with a
  "translator" system instruction, another as a "code reviewer", without
  reloading weights between them.
- **Background work alongside an active chat** — e.g. summarizing or tagging a
  document in one session while the user keeps chatting in another (they take
  turns on the accelerator — see the serialization note below).
- **A/B prompt comparison** — run the same model with two different setups and
  compare, sharing the loaded weights.

If you only ever have one conversation at a time, stick with the simpler
`createSession()` / `createChat()` singleton API — you don't need this.

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);

final chatA = await model.openChat(); // independent context A
final chatB = await model.openChat(); // independent context B

await chatA.addQueryChunk(Message(text: 'My name is Alice.', isUser: true));
await chatA.generateChatResponse();

await chatB.addQueryChunk(Message(text: 'My name is Bob.', isUser: true));
await chatB.generateChatResponse();

// Each remembers only its own context.
await chatA.addQueryChunk(Message(text: 'What is my name?', isUser: true));
print(await chatA.generateChatResponse()); // "Alice"

model.sessions;        // all live sessions (legacy + open)
await chatA.session.close();  // closing one leaves the others usable
```

> ⚠️ **Concurrent contexts, serialized inference.** The sessions are
> logically independent, but **only one session generates at a time** —
> calling `generateResponse()` on a second session while another is still
> running blocks until the first finishes. Generation is *not* parallel.
> This is intentional: parallel on-device inference would contend for the
> accelerator and risk OOM.

**Per-platform behavior** (transparent to your code — the API is identical):

| Path | How it works |
|------|--------------|
| `.litertlm` — native (Android/iOS/macOS/Windows/Linux) | Engine allows one live conversation; sessions multiplex — the active session's history is replayed on switch. |
| `.litertlm` — web (`@litert-lm/core`) | Separate conversations; generation still serialized. |
| `.task` — MediaPipe (Android/iOS) | N real `LlmInferenceSession` live at once (each with its own KV cache); generation serialized by a mutex. |
| `.task` — MediaPipe **web** | ❌ Not yet — `openSession()` throws `UnsupportedError`. Planned for a future release. |

**Memory**: each open session holds its own context (~100–500 MB depending
on model + `maxTokens`). On phones with large models (Gemma 4 E2B+), several
concurrent sessions can OOM. Cap the count with `maxConcurrentSessions:` on
`getActiveModel(...)` — `openSession()` throws `StateError` past the cap.
Multi-session is most reliable on desktop and high-end mobile with small
models (Gemma 3 1B / 270M).

### Removing installed models

Use `uninstallModel()` to delete a model's metadata and files. When you remove
the model that is currently **active**, also clear its persisted identity so it
isn't auto-restored on the next app launch:

```dart
// Free in-memory handles first if the model is loaded.
await model.close();

// Delete the files + metadata.
await FlutterEdgeAi.uninstallModel('Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm');

// Clear the persisted "active model" identity so it isn't auto-restored.
await FlutterEdgeAi.clearActiveInferenceIdentity();
// For an embedder, pair uninstallModel() with:
await FlutterEdgeAi.clearActiveEmbeddingIdentity();
```

`clearActiveInferenceIdentity()` / `clearActiveEmbeddingIdentity()` wipe both the
in-memory active spec and the SharedPreferences entry. Pair them with
`uninstallModel()` only when the deleted model was the active one — otherwise the
deleted model would be restored as active on the next launch.

### Handling download errors

`installModel(...).install()` throws a public `DownloadException` carrying a
sealed `DownloadError`, so you can react to gated HuggingFace models (HTTP
401/403) without substring-matching error strings:

```dart
try {
  await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
      .fromNetwork(url, token: hfToken)
      .install();
} on DownloadException catch (e) {
  switch (e.error) {
    case UnauthorizedError():   // 401 — missing/invalid token
    case ForbiddenError():      // 403 — token lacks access to a gated model
      showGatedModelDialog();
    case NotFoundError():       // 404 — bad URL (use /resolve/main/, not /blob/main/)
      showNotFoundDialog();
    case RateLimitedError():    // 429
    case ServerError():         // 5xx
    case NetworkError():        // connectivity
    case CanceledError():       // user canceled
    case UnknownError():
      showRetryDialog(e.error.toUserMessage());
  }
}
```

Each `DownloadError` exposes `toUserMessage()`, `toTitle()`, `isRetryable`, and
`requiresUserAction` helpers for building UI.

## Installation Sources

```dart
// Hugging Face repo — the engine's resolver picks the right file/variant.
// One call: omit `file` and the resolver reads the repo (a litertlm manifest,
// or the ONNX file tree) at install time and installs the right variant.
await FlutterEdgeAi.installModel(
  modelType: ModelType.general, // a resolver may override (e.g. litertlm manifest)
  fileType: ModelFileType.litertlm,
)
  .fromHuggingFace('litert-community/Qwen3-4B-Thinking-2507')
  .install();

// Or pin an explicit file (any fileType; no manifest needed):
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromHuggingFace('litert-community/Gemma3-1B-IT', file: 'model.litertlm')
  .install();

// Network — .litertlm is the cross-platform default (Android/iOS/Desktop).
// For mobile-only or web-only apps you can substitute a .task URL of the
// same model — and drop the fileType, which defaults to ModelFileType.task.
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromNetwork('https://example.com/model.litertlm', token: 'optional')
  .install();

// Flutter assets
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromAsset('assets/models/model.litertlm')
  .install();

// Native bundle
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromBundled('model.litertlm')
  .install();

// External file
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromFile('/path/to/model.litertlm')
  .install();
```

`fromHuggingFace` needs the matching engine's resolver, which the engine
registers itself: `LiteRtLmEngine` reads `litertlm_manifest.json`, `OnnxEngine`
resolves an ORT-GenAI directory (auto-picking a CPU execution-provider folder).
`resolveHuggingFace(repo, fileType:)` returns the resolved identity and
overridable runtime defaults *without* installing, so you can inspect the variant
and its `notes` first. See each engine package's README for the resolver
specifics.

## Modern API vs Legacy API

### Modern API (Recommended) ✅

**Benefits:**
- ✅ Cleaner, more intuitive
- ✅ Type-safe ModelSource
- ✅ Automatic active model management
- ✅ Install once, create many instances

**Usage:**
```dart
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url).install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
```

### Legacy API ⚠️ Deprecated

> **⚠️ DEPRECATED:** This API is maintained for backwards compatibility only. New projects should use the [Modern API](#modern-api-recommended-) above.

Still works but requires manual ModelType specification:
```dart
final model = await FlutterEdgeAiPlugin.instance.createModel(
  modelType: ModelType.gemmaIt,  // Must specify every time
  maxTokens: 2048,
);
```

---

### Initialize Flutter Edge AI

Call `await FlutterEdgeAi.initialize(...)` once in `main()` and **register the opt-in
packages you added** to `pubspec.yaml`. Core registers no engine on its own, so
without this step `getActiveModel()` / `createEmbeddingModel()` throw a clear
"add the engine package" error.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    // Inference engines — add the ones whose packages you depend on:
    inferenceEngines: const [
      LiteRtLmEngine(),     // flutter_edge_ai_litertlm  — .litertlm models
      MediaPipeEngine(),    // flutter_edge_ai_mediapipe — .task / .bin models
      BuiltInAiEngine(),    // flutter_edge_ai_builtin_ai — Gemini Nano / Apple FM / Windows AI Foundry
    ],
    // Optional — embeddings (needed for RAG / generateEmbedding):
    embeddingBackends: const [
      LiteRtEmbeddingBackend(), // flutter_edge_ai_litertlm
    ],
    // The tokenizer is registered separately — which family a model needs is a
    // property of the model, not of the engine that runs it.
    embeddingTokenizers: const [
      GemmaEmbeddingTokenizers(), // flutter_edge_ai_embeddings
    ],
    // Optional — RAG vector store (pick one; native here):
    vectorStore: QdrantVectorStore(), // flutter_edge_ai_qdrant

    // Common settings:
    // '' when the define is absent, and an empty token still sends a
    // bare `Authorization: Bearer` header — pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
    maxDownloadRetries: 10,
  );

  runApp(MyApp());
}
```

**Which parameter ← which package:**

| Parameter | Provided by | Notes |
|---|---|---|
| `inferenceEngines: [LiteRtLmEngine()]` | `flutter_edge_ai_litertlm` | `.litertlm` (mobile + desktop + web) |
| `inferenceEngines: [MediaPipeEngine()]` | `flutter_edge_ai_mediapipe` | `.task` / `.bin` (mobile + web) |
| `inferenceEngines: [BuiltInAiEngine()]` | `flutter_edge_ai_builtin_ai` | OS system models — Gemini Nano (Android + Web) / Apple FM (iOS 26+/macOS) / Windows AI Foundry. A thin adapter over `flutter_local_ai`, which owns the native layer |
| `inferenceEngines: [OnnxEngine()]` | `flutter_edge_ai_onnx` | ONNX models — ORT-GenAI (FFI; macOS/Linux/Windows/Android/iOS arm64) or Transformers.js (Web) |
| `embeddingBackends: [LiteRtEmbeddingBackend()]` | `flutter_edge_ai_litertlm` | text embeddings |
| `embeddingBackends: [OnnxEmbeddingBackend()]` | `flutter_edge_ai_onnx` | text embeddings from ONNX/ORT models (FFI native; onnxruntime-web on Web) |
| `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` | `flutter_edge_ai_embeddings` | required by BOTH embedding backends above |
| `sttBackends: [LiteRtSttBackend()]` | `flutter_edge_ai_speech` | speech-to-text (native only) |
| `ttsBackends: [LiteRtTtsBackend()]` | `flutter_edge_ai_speech` | text-to-speech (native only) |
| `vectorStore: QdrantVectorStore()` | `flutter_edge_ai_qdrant` | native RAG |
| `vectorStore: SqliteVectorStore()` / `WebSqliteVectorStore()` | `flutter_edge_ai_sqlite` | native / web RAG |

Add only the engines you ship. Passing both `LiteRtLmEngine()` and
`MediaPipeEngine()` lets one app run both formats — the registry routes each
model to the engine that handles its file type. On web, choose
`vectorStore: WebSqliteVectorStore()` (`flutter_edge_ai_qdrant` is native-only).

**Common settings:**
- `huggingFaceToken`: Authentication token for gated models (Gemma3n, EmbeddingGemma)
- `maxDownloadRetries`: Number of retry attempts for failed downloads (default: 10)
- `webStorageMode`: **(Web only)** Storage strategy for model files (default: `cacheApi`)
  - `WebStorageMode.cacheApi`: Cache API with Blob URLs (for models <2GB)
  - `WebStorageMode.streaming`: OPFS streaming (for large models >2GB like E4B, 7B)
  - `WebStorageMode.none`: No caching (ephemeral mode for testing)

> Use `WebStorageMode.streaming` when shipping `.litertlm` web models — the
> `@litert-lm/core` engine consumes an OPFS ReadableStream and avoids Chrome's
> ~2 GB blob-fetch limit on Gemma 4 E2B/E4B web builds.

**Next Steps:**
- 📖 [Authentication Setup](#huggingface-authentication) - Configure tokens for gated models
- 📦 [Model Sources](#model-sources) - Learn about different model sources
- 🌐 [Platform Support](#platform-support-details) - Web vs Mobile differences
- 🔄 [Migration Guide](#migration-from-legacy-to-modern-api) - Upgrade from Legacy API
- 📚 [Legacy API Documentation](#usage-legacy-api) - For backwards compatibility

## Logging

The plugin's internal logs are **silent in release builds** — model output, prompts, and conversation history are never written to logcat / syslog. In debug builds they're shown according to `FlutterEdgeAi.logLevel`:

| Level | What it prints (debug only) |
|-------|------------------------------|
| `EdgeAiLogLevel.none` | Nothing — fully silent. |
| `EdgeAiLogLevel.info` *(default)* | Lifecycle, errors, diagnostics. **No** model output / prompts. |
| `EdgeAiLogLevel.verbose` | Everything above **plus** model output, prompts, and conversation history. |

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// See the model's generated tokens and prompts while debugging:
FlutterEdgeAi.logLevel = EdgeAiLogLevel.verbose;

// Or silence the plugin entirely:
FlutterEdgeAi.logLevel = EdgeAiLogLevel.none;
```

Notes:
- Release builds are always silent regardless of this setting — there is no way to leak PII into a production log.
- The level is process-global and per-isolate; set it once at startup. Background isolates (the LiteRT-LM engine-create isolate and the `flutter_edge_ai_embeddings` worker) snapshot the value when they start, so they honour it too.
- `EdgeAiLogLevel` is exported from `package:flutter_edge_ai/flutter_edge_ai.dart` — no extra import needed.

## HuggingFace Authentication 🔐

Many models require authentication to download from HuggingFace. **Never commit tokens to version control.**

### ✅ Recommended: config.json Pattern

This is the **most secure** way to handle tokens in development and production.

**Step 1:** Create config template file `config.json.example`:
```json
{
  "HUGGINGFACE_TOKEN": ""
}
```

**Step 2:** Copy and add your token:
```bash
cp config.json.example config.json
# Edit config.json and add your token from https://huggingface.co/settings/tokens
```

**Step 3:** Add to `.gitignore`:
```gitignore
# Never commit tokens!
config.json
```

**Step 4:** Run with config:
```bash
flutter run --dart-define-from-file=config.json
```

**Step 5:** Access in code:
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read from environment (populated by --dart-define-from-file)
  const token = String.fromEnvironment('HUGGINGFACE_TOKEN');

  // Initialize with token (optional if all models are public)
  await FlutterEdgeAi.initialize(
    huggingFaceToken: token.isNotEmpty ? token : null,
  );

  runApp(MyApp());
}
```

### Alternative: Environment Variables

```bash
export HUGGINGFACE_TOKEN=hf_your_token_here
flutter run --dart-define=HUGGINGFACE_TOKEN=$HUGGINGFACE_TOKEN
```

### Alternative: Per-Download Token

```dart
// Pass token directly for specific downloads
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromNetwork(
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4.litertlm',
    token: 'hf_your_token_here',  // ⚠️ Not recommended - use config.json
  )
  .install();
```

### Which Models Require Authentication?

**Common gated models:**
- ✅ **Gemma3n** (E2B, E4B) - `google/` repos are gated
- ✅ **Gemma 3 1B** - `litert-community/` requires access
- ✅ **Gemma 3 270M** - `litert-community/` requires access
- ✅ **EmbeddingGemma** - `litert-community/` requires access

**Public models (no auth needed):**
- ❌ **DeepSeek, Qwen3, Qwen 2.5, SmolLM, SmolLM3, Phi-4, FastVLM, Qwen2-VL, SmolVLM2, LLaVA-OneVision** - Public repos

**Get your token:** https://huggingface.co/settings/tokens

**Grant access to gated repos:** Visit model page → "Request Access" button

## Model Sources 📦

Flutter Edge AI supports multiple model sources with different capabilities:

| Source Type | Platform | Progress | Resume | Authentication | Use Case |
|-------------|----------|----------|--------|----------------|----------|
| **NetworkSource** | All | ✅ Detailed | ⚠️ Server-dependent | ✅ Supported | HuggingFace, CDNs, private servers |
| **AssetSource** | All | ⚠️ End only | ❌ No | ❌ N/A | Models bundled in app assets |
| **BundledSource** | All | ⚠️ End only | ❌ No | ❌ N/A | Native platform resources |
| **FileSource** | Native (no Web) | ⚠️ End only | ❌ No | ❌ N/A | User-selected files (file picker) |

### NetworkSource - Internet Downloads

Downloads models from HTTP/HTTPS URLs with full progress tracking and authentication.

**Features:**
- ✅ Progress tracking (0-100%)
- ⚠️ Resume after interruption (server-dependent, not supported by HuggingFace CDN)
- ✅ HuggingFace authentication
- ✅ Smart retry logic with exponential backoff
- ✅ Background downloads on mobile
- ✅ Cancellable downloads with CancelToken
- ✅ **Android foreground service** for large downloads (opt in with `foreground: true`)
- ✅ **Coexists with your own `background_downloader` usage** (see below)

**Sharing `background_downloader` with your app.** flutter_edge_ai downloads
through `background_downloader`, but it does **not** listen to
`FileDownloader().updates` — that is a single-subscription stream, and claiming
it would make every later `FileDownloader().updates.listen(...)` in your app
throw *"Stream has already been listened to"*. Instead it registers callbacks
scoped to its own task group, so the stream stays yours:

```dart
// Yours — unaffected by flutter_edge_ai, and unaffected by it in reverse.
FileDownloader().updates.listen((update) { /* your own tasks */ });
```

**Download priority** used to be `10` — the *lowest* in `background_downloader`,
whose range is `0..10` with 0 best. On iOS that mapped to a raw URLSession
priority of `0.0`, below `URLSessionTask.lowPriority`, for a multi-gigabyte
download the user is watching; it is now `0`.

On Android it is now `5`, the package default, rather than `10` — a change with
no observable effect there, which is the point. Android uses priority only for
the holding queue (which this package does not enable) and for
`expedited = priority < 5`, and expedited is the wrong trade for a
multi-gigabyte transfer twice over:

- it **shortens** the OS execution guarantee — `JobSchedulerService` gives a
  regular job 10 minutes and an expedited one 3, and AOSP's own comment says
  expedited jobs "shouldn't be used for long pieces of work";
- and it currently hangs the download: `background_downloader` survives
  WorkManager's 9-minute cap by re-enqueuing with a 1-second delay, and an
  expedited request cannot carry a delay — `WorkRequest.Builder.build()` throws,
  the throw is logged and swallowed, and the download stops at nine minutes with
  no error. That is the package's own open PR #709.

**Example:**
```dart
// Public model
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromNetwork('https://example.com/model.litertlm')
  .withProgress((progress) => print('$progress%'))
  .install();

// Private model with authentication
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromNetwork(
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4.litertlm',
    token: 'hf_...',  // Or use await FlutterEdgeAi.initialize(huggingFaceToken: ...)
  )
  .withProgress((progress) => setState(() => _progress = progress))
  .install();
```

**Android Foreground Service (Large Downloads):**

Android has a 9-minute background execution limit. For large models you can opt into foreground service mode, which shows a notification and exempts the download from battery-optimization kills (note: it does not raise WorkManager's own 9-minute task timeout — see `DOWNLOAD_TESTING.md`):

```dart
// DEFAULT - no foreground service; pass foreground: true to get one
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url)  // foreground: null
  .install();

// Force foreground mode (always show notification)
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url, foreground: true)
  .install();

// Force background mode (may fail for large files)
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url, foreground: false)
  .install();
```

**Foreground Parameter:**
- `null` (default): **no foreground service.** This branch configures no notification, and `background_downloader` only calls `setForeground()` once a running notification exists — so the size threshold alone never starts one. As of 1.6.3 this branch also no longer writes `runInForegroundIfFileLargerThan`, which is a process-wide, reboot-surviving setting shared with your own downloads.
- `true`: Always use foreground service (shows notification)
- `false`: Never use foreground service

**Note:** iOS uses native URLSession which handles long downloads automatically - no foreground service needed.

**Note:** Foreground downloads (`foreground: true`) show a progress notification and request the `POST_NOTIFICATIONS` runtime permission automatically before the download starts. On Android 13+ the permission must ALSO be granted at runtime for the foreground service itself to activate — a manifest declaration alone is not enough. The host app must still declare `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` in `AndroidManifest.xml`; flutter_edge_ai requests the runtime grant for you.

**Note:** If the user denies `POST_NOTIFICATIONS` (or the request times out/errors), foreground mode does not activate and the download silently falls back to background — the download still proceeds, just without the Doze/battery-optimization exemption. Host apps with long/large downloads should pre-request `POST_NOTIFICATIONS` before starting one.

**Required on Android 14+ (API 34+): host app manifest setup.** `background_downloader`'s foreground path runs through WorkManager's shared `SystemForegroundService`. On API 34+, `startForeground()` throws `IllegalArgumentException: foregroundServiceType ... is not a subset of ...` unless the host app declares a matching `FOREGROUND_SERVICE_DATA_SYNC` permission **and** overrides that service's `foregroundServiceType` in its own `AndroidManifest.xml`. This is host-app responsibility — flutter_edge_ai does not add `FOREGROUND_SERVICE_DATA_SYNC` for you, since it's a Play-sensitive permission that shouldn't be imposed on every consumer. Add to your app's `AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

    <application>
        <!-- ... -->
        <service
            android:name="androidx.work.impl.foreground.SystemForegroundService"
            android:foregroundServiceType="dataSync"
            tools:node="merge" />
    </application>
</manifest>
```

Without this, `foreground: true` downloads crash on API 34+ devices. See `packages/flutter_edge_ai/example/android/app/src/main/AndroidManifest.xml` for a working example.

**Cancelling Downloads:**

Use `CancelToken` to cancel downloads in progress:

```dart
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';

// Create cancel token
final cancelToken = CancelToken();

// Start download with cancel token
final future = FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromNetwork(url)
  .withCancelToken(cancelToken)  // ← Pass cancel token via builder
  .withProgress((progress) => print('Progress: $progress%'))
  .install();

// Cancel download from another part of your code
// (e.g., user pressed cancel button)
cancelToken.cancel('User cancelled download');

// Handle cancellation
try {
  await future;
  print('Download completed');
} catch (e) {
  if (CancelToken.isCancel(e)) {
    print('Download was cancelled by user');
  } else {
    print('Download failed: $e');
  }
}

// Check if cancelled
if (cancelToken.isCancelled) {
  print('Reason: ${cancelToken.cancelReason}');
}
```

**CancelToken Features:**
- ✅ Non-breaking: Optional parameter, existing code works without changes
- ✅ Works with network downloads (inference + embedding models)
- ✅ Cancels ALL files in multi-file downloads (embedding: model + tokenizer)
- ✅ Platform-independent (Mobile + Web)
- ✅ Throws `DownloadCancelledException` for proper error handling
- ✅ Thread-safe cancellation

### AssetSource - Flutter Assets

Copies models from Flutter assets (declared in `pubspec.yaml`).

**Features:**
- ✅ No network required
- ✅ Fast installation (local copy)
- ⚠️ Increases app size significantly
- ✅ Works offline

**Example:**
```dart
// 1. Add to pubspec.yaml
// assets:
//   - models/gemma3-1b-it.litertlm

// 2. Install from asset
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromAsset('models/gemma3-1b-it.litertlm')
  .install();
```

### BundledSource - Native Resources

**Production-Ready Offline Models**: Include small models directly in your app bundle for instant availability without downloads.

**Use Cases:**
- ✅ Offline-first applications (works without internet from first launch)
- ✅ Small models (Gemma 3 270M ~300MB)
- ✅ Core features requiring guaranteed availability
- ⚠️ **Not for large models** (increases app size significantly)

**Platform Setup:**

**Android** (`android/app/src/main/assets/models/`)

```bash
# Place your model file. .litertlm works for both Android and Desktop,
# .task is MediaPipe-only and won't load on Desktop.
android/app/src/main/assets/models/gemma3-270m-it-q8.litertlm
```

**iOS** (Add to Xcode project)
1. Drag model file into Xcode project (`.litertlm` for FFI; `.task` for MediaPipe)
2. Check "Copy items if needed"
3. Add to target membership

**Web** (Static files in `web/` directory) — a `-web.task` build for MediaPipe, or a web `.litertlm` build for LiteRT-LM (early preview):
```bash
# Place model files in web/ directory
example/web/gemma3-270m-it.task

# Files are automatically copied to build/web/ during production build
flutter build web
```

⚠️ **Web Platform Limitation:**
- **Production only**: Bundled resources work ONLY in production builds (`flutter build web`)
- **Debug mode**: Files in `web/` are NOT served by `flutter run` dev server
- **For development**: Use `NetworkSource` or `AssetSource` instead

**Features:**
- ✅ Zero network dependency
- ✅ No installation delay
- ✅ No storage permission needed
- ✅ Direct path usage (no file copying)

**Example:**
```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromBundled('gemma3-270m-it-q8.litertlm')
  .install();
```

**App Size Impact:**
- SmolLM 135M: ~135MB
- Gemma 3 270M: ~300MB
- Qwen3 0.6B: ~586MB
- Consider hosting large models for download instead

### FileSource - External Files (Native)

References external files (e.g., user-selected via file picker). Works on Android, iOS, macOS, Linux, Windows. Not available on Web (no local file system).

**Features:**
- ✅ No copying (references original file)
- ✅ Protected from cleanup
- ❌ **Web not supported** (no local file system)

**Example:**
```dart
// Native only - after user selects file with file_picker
final path = '/data/user/0/com.app/files/model.litertlm';
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromFile(path)
  .install();
```

**Important:** On web, FileSource only works with URLs or asset paths, not local file system paths.

## Migration from Legacy to Modern API 🔄

If you're upgrading from the Legacy API, here are common migration patterns:

### Installing Models

<table>
<tr>
<th>Legacy API</th>
<th>Modern API</th>
</tr>
<tr>
<td>

```dart
// Network download
final spec = MobileModelManager.createInferenceSpec(
  name: 'model.bin',
  modelUrl: 'https://example.com/model.bin',
);

await FlutterEdgeAiPlugin.instance.modelManager
  .downloadModelWithProgress(spec, token: token)
  .listen((progress) {
    print('${progress.overallProgress}%');
  });
```

</td>
<td>

```dart
// Network download
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromNetwork(
    'https://example.com/model.bin',
    token: token,
  )
  .withProgress((progress) {
    print('$progress%');
  })
  .install();
```

</td>
</tr>
<tr>
<td>

```dart
// From assets
await modelManager.installModelFromAssetWithProgress(
  'model.bin',
  loraPath: 'lora.bin',
).listen((progress) {
  print('$progress%');
});
```

</td>
<td>

```dart
// From assets
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromAsset('model.bin')
  .withProgress((progress) {
    print('$progress%');
  })
  .install();

// LoRA weights can be installed with the model
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromAsset('model.bin')
  .withLoraFromAsset('lora.bin')
  .install();
```

</td>
</tr>
</table>

### Checking Model Installation

<table>
<tr>
<th>Legacy API</th>
<th>Modern API</th>
</tr>
<tr>
<td>

```dart
final spec = MobileModelManager.createInferenceSpec(
  name: 'model.bin',
  modelUrl: url,
);

final isInstalled = await FlutterEdgeAiPlugin
  .instance.modelManager
  .isModelInstalled(spec);
```

</td>
<td>

```dart
final isInstalled = await FlutterEdgeAi
  .isModelInstalled('model.bin');
```

</td>
</tr>
</table>

### Key Migration Notes

- ✅ **Simpler imports**: Use `package:flutter_edge_ai/core/api/flutter_edge_ai.dart`
- ✅ **Builder pattern**: Chain methods for cleaner code
- ✅ **Callback-based progress**: Simpler than streams for most cases
- ✅ **Type-safe sources**: Compile-time validation of source types
- ⚠️ **Breaking change**: Progress values are now `int` (0-100) instead of `DownloadProgress` object
- ⚠️ **Separate files**: Model and LoRA weights installed independently

### Model Creation and Inference

**Modern API (Recommended):**

```dart
// Create model with runtime configuration
final inferenceModel = await FlutterEdgeAi.getActiveModel(
  maxTokens: 2048,
  preferredBackend: PreferredBackend.gpu,
);

final chat = await inferenceModel.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
final response = await chat.generateChatResponse();
```

**Legacy API (Still supported):**

```dart
// Works with both Legacy and Modern installation methods
final inferenceModel = await FlutterEdgeAiPlugin.instance.createModel(
  modelType: ModelType.gemmaIt,
  preferredBackend: PreferredBackend.gpu,
  maxTokens: 2048,
);

final chat = await inferenceModel.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
final response = await chat.generateChatResponse();
```

## Usage (Legacy API) ⚠️ DEPRECATED

The pre-Modern stream-based API (`FlutterEdgeAiPlugin.instance.modelManager`, `installModelFromAsset`, `downloadModelFromNetworkWithProgress`, etc.) is still supported but deprecated. New projects should use the [Modern API](#quick-start) above.

📚 **Full Legacy API reference:** [docs/LEGACY_API.md](https://github.com/DenisovAV/flutter_edge_ai/blob/main/docs/LEGACY_API.md)

## 🖼️ Message Types

The plugin now supports different types of messages:

```dart
// Text only
final textMessage = Message.text(text: "Hello!", isUser: true);

// Text + Image
final multimodalMessage = Message.withImages(
  text: "What's in this image?",
  imageBytes: [imageBytes],
  isUser: true,
);

// Image only
final imageMessage = Message.imagesOnly(imageBytes: [imageBytes], isUser: true);

// Tool response (for function calling)
final toolMessage = Message.toolResponse(
  toolName: 'change_background_color',
  response: {'status': 'success', 'color': 'blue'},
);

// System information message
final systemMessage = Message.systemInfo(text: "Function completed successfully");

// Thinking content (for DeepSeek models)
final thinkingMessage = Message.thinking(text: "Let me analyze this problem...");

// Check if message contains image
if (message.hasImage) {
  print('This message contains an image');
}

// Create a copy of message
final copiedMessage = message.copyWith(text: "Updated text");
```

## 💬 Response Types

The model can return different types of responses depending on capabilities:

```dart
// Handle different response types
chat.generateChatResponseAsync().listen((response) {
  if (response is TextResponse) {
    // Regular text token from the model
    print('Text token: ${response.token}');
    // Use response.token to update your UI incrementally
    
  } else if (response is FunctionCallResponse) {
    // Model wants to call a function (Gemma 4, downloadable Gemma3n E4B .litertlm,
    // FunctionGemma, DeepSeek, Qwen3, Qwen 2.5, Phi-4 Mini)
    print('Function: ${response.name}');
    print('Arguments: ${response.args}');
    
    // Execute the function and send response back
    _handleFunctionCall(response);
  } else if (response is ThinkingResponse) {
    // Model reasoning (Gemma 4 / DeepSeek on supported native engines;
    // Qwen3 tags are also parsed on Web when the model emits them)
    print('Thinking: ${response.content}');
    
    // Show thinking process in UI
    _showThinkingBubble(response.content);
  }
});
```

**Response Types:**
- **`TextResponse`**: Contains a text token (`response.token`) for regular model output
- **`FunctionCallResponse`**: Contains function name (`response.name`) and arguments (`response.args`) when the model wants to call a function
- **`ThinkingResponse`**: Contains reasoning (`response.content`) on supported thinking paths, including emitted Qwen3 tags on Web

### What happens after you send a tool result

On a `.litertlm`, both Gemma 4 and FunctionGemma go through LiteRT-LM's own tool path: the
declarations travel to the runtime as structured data, the call comes back parsed, and your
`Message.toolResponse(...)` goes back as one role-`tool` message that continues the same model
turn. Since **1.8.4** (with `flutter_gemma_litertlm` 1.7.1) that holds for FunctionGemma too —
before it, its tool results were sent as an ordinary user message, and the model answered them by
repeating the call it had just made.

Where a call comes back as text rather than structured `tool_calls` — the web SDK, or a
`.litertlm` exported without the FunctionGemma model type, whose runtime opens no tool-call
channel — flutter_edge_ai parses that text itself, so your code still receives a
`FunctionCallResponse`.

Nothing in your own code changes: the wire format is chosen from the model type and the file type
together. Three things are worth knowing:

- `ToolChoice.none` cannot take the declarations back out on a `.litertlm`, because the runtime
  holds them.
- FunctionGemma is an action model — it often ends its turn at the call rather than narrating the
  result. Render the tool's own result in your UI, and reach for Gemma 4 when you want the model to
  talk about what came back.
- `.task` models through MediaPipe have no native tool path, so they keep the text wire format
  flutter_edge_ai renders itself.


## 🎯 Supported Models

### Platform Support

| Model | Size | Desktop | Mobile | Web |
|-------|------|:-------:|:------:|:---:|
| [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) | 2.4GB | ✅ | ✅ | ✅ |
| [Gemma 4 E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | 4.3GB | ✅ | ✅ | ✅ |
| [Gemma3n E2B](https://huggingface.co/google/gemma-3n-E2B-it-litert-preview) | 3.1GB | ✅ | ✅ | ✅ |
| [Gemma3n E4B](https://huggingface.co/google/gemma-3n-E4B-it-litert-preview) | 6.5GB | ✅ | ✅ | ✅ |
| [FastVLM 0.5B](https://huggingface.co/litert-community/FastVLM-0.5B) | 0.5GB | ✅ | ❌ | ❌ |
| [Qwen2-VL 2B](https://huggingface.co/litert-community/Qwen2-VL-2B) | 1.8GB | ✅ | ✅ | ❌ |
| [SmolVLM2 500M](https://huggingface.co/litert-community/SmolVLM2-500M) | 0.36GB | ✅ | ✅ | ❌ |
| [LLaVA-OneVision 0.5B](https://huggingface.co/litert-community/LLaVA-OneVision-0.5B) | 0.83GB | ✅ | ✅ | ❌ |
| [Gemma-3 1B](https://huggingface.co/litert-community/Gemma3-1B-IT) | 0.5GB | ✅ | ✅ | ✅ |
| [Gemma 3 270M](https://huggingface.co/litert-community/gemma-3-270m-it) | 0.3GB | ✅ | ✅ | ✅ |
| [FunctionGemma 270M](https://huggingface.co/sasha-denisov/function-gemma-270M-it) | 284MB | ✅ | ✅ | ✅ |
| [Qwen3 0.6B](https://huggingface.co/litert-community/Qwen3-0.6B) | 586MB | ✅ | ✅ | ✅ |
| [Qwen 2.5 1.5B](https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct) | 1.6GB | ✅ | ✅ | ❌ |
| [Qwen 2.5 0.5B](https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct) | 0.5GB | ❌ | ✅ | ❌ |
| [SmolLM 135M](https://huggingface.co/litert-community/SmolLM-135M-Instruct) | 135MB | ❌ | ✅ | ❌ |
| [LFM2.5 230M](https://huggingface.co/litert-community/LFM2.5-230M) | 168MB | ✅ | ✅ | ❌ |
| [SmolLM3 3B](https://huggingface.co/litert-community/SmolLM3-3B) | 2.0GB | ✅ | ✅ | ❌ |
| [Phi-4 Mini](https://huggingface.co/litert-community/Phi-4-mini-instruct) | 3.9GB | ✅ | ✅ | ✅ |
| [Phi-4 Mini Reasoning](https://huggingface.co/litert-community/Phi-4-mini-reasoning) | 2.8GB | ✅ | ✅ | ❌ |
| [DeepSeek R1](https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B) | 1.7GB | ❌ | ✅ | ❌ |
| [TranslateGemma 4B](https://huggingface.co/google/translategemma-4b-it) † | 2-4GB | ✅ | ✅ | ❌ |

† **TranslateGemma is CPU-only.** Google ships no bundle of its own; the community repo ([`barakplasma/translategemma-4b-it-android-task-quantized`](https://huggingface.co/barakplasma/translategemma-4b-it-android-task-quantized)) publishes `.litertlm` artifacts that load and translate on desktop CPU, but return only padding on the GPU. See the [Model Capabilities](#model-capabilities) note for the measurements.

### 📊 Text Embedding Models

All embedding models generate **768-dimensional vectors**. The numbers in names (64/256/512/1024/2048) indicate **maximum input sequence length in tokens**, not embedding dimension.

| Model | Parameters | Dimensions | Max Seq Length | Size | Best For | Auth Required |
|-------|-----------|------------|----------------|------|----------|---------------|
| **[Gecko 64](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 64 tokens | 110MB | Short queries, real-time search | ❌ |
| **[Gecko 256](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 256 tokens | 114MB | Balanced speed/accuracy | ❌ |
| **[Gecko 512](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 512 tokens | 116MB | Medium context documents | ❌ |
| **[EmbeddingGemma 256](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 256 tokens | 179MB | High accuracy, short context | ✅ |
| **[EmbeddingGemma 512](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 512 tokens | 179MB | High accuracy, medium context | ✅ |
| **[EmbeddingGemma 1024](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 1024 tokens | 183MB | Long documents, detailed content | ✅ |
| **[EmbeddingGemma 2048](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 2048 tokens | 196MB | Very long documents | ✅ |

**Performance Comparison (Android Pixel 8):**
- **Gecko 64**: ~109ms/doc embedding, 130ms search (⚡ **fastest** - 2.6x faster than EmbeddingGemma)
- **EmbeddingGemma 256**: ~286ms/doc embedding, 342ms search (🎯 **more accurate** - 300M vs 110M params)

**Use Cases:**
- ✅ **Gecko 64**: Real-time search, mobile apps, short queries (≤64 tokens), fast inference
- ✅ **Gecko 256/512**: Balanced use cases, general-purpose embeddings, good speed/quality tradeoff
- ✅ **EmbeddingGemma 256/512**: High-quality embeddings, semantic search, better accuracy
- ✅ **EmbeddingGemma 1024/2048**: Long documents, detailed content, research papers, articles

## 🔎 On-device RAG / Vector Store

Two vector-store packages implement the same Dart API: `flutter_edge_ai_qdrant` (qdrant-edge, native — fastest on Android/iOS/desktop) and `flutter_edge_ai_sqlite` (in-SQLite `sqlite-vec`/`vec0` KNN, portable across all six platforms incl. Web, since qdrant-edge can't target WASM). Code is the same on both.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// 1. Install an embedding model (any of Gecko / EmbeddingGemma)
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite',
      token: 'hf_...',
    )
    .tokenizerFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
      token: 'hf_...',
    )
    .install();

// 2. Initialize the vector store (one shard per database path). On native pass
//    an absolute path: a bare name resolves against the process working
//    directory, which is not writable on Android or iOS. On web a name is enough.
final dir = await getApplicationDocumentsDirectory(); // package:path_provider
await FlutterEdgeAiPlugin.instance.initializeVectorStore('${dir.path}/rag_store');

// 3. Add documents — let the plugin compute embeddings for you
for (final doc in docs) {
  await FlutterEdgeAiPlugin.instance.addDocument(
    id: doc.id,
    content: doc.content,
    metadata: '{"category":"science","lang":"en"}',
  );
}

// 3b. Or batch-embed yourself and feed pre-computed vectors via
//     addDocumentWithEmbedding(...) for higher throughput.
final embedder = FlutterEdgeAiPlugin.instance.initializedEmbeddingModel!;
final embeddings = await embedder.generateEmbeddings(
  docs.map((d) => d.content).toList(),
  taskType: TaskType.retrievalDocument,
);
for (var i = 0; i < docs.length; i++) {
  await FlutterEdgeAiPlugin.instance.addDocumentWithEmbedding(
    id: docs[i].id,
    content: docs[i].content,
    embedding: embeddings[i],
    metadata: '{"category":"science","lang":"en"}',
  );
}

// 4. Semantic search, with optional payload-aware Filter (all backends + platforms)
final results = await FlutterEdgeAiPlugin.instance.searchSimilar(
  query: 'quantum entanglement',
  topK: 10,
  threshold: 0.0,
  filter: Filter(
    must: [FieldEquals(key: 'category', value: 'science')],
    mustNot: [FieldEquals(key: 'lang', value: 'fr')],
  ),
);

// 5. Persist the index while the store stays open (see below)
await FlutterEdgeAiPlugin.instance.flushVectorStore(); // or FlutterEdgeAi.rag.flush()
```

**Which backend embeddings run on.** `getActiveEmbedder(preferredBackend:)` is accepted and not applied: native embeddings run on CPU — LiteRT's GPU delegate returns all-zero vectors for EmbeddingGemma's int4 weights, and the ONNX client appends no execution provider. Read `EmbeddingModel.activeBackend` for the answer; it survives a release build. It is `cpu` on native and `null` on web, where the runtime picks WebGPU or WASM (see `flutter_edge_ai_litertlm`'s README for the web getters). Since 1.11.0 a class that `implements EmbeddingModel` must add `activeBackend` and `isClosed`; `extends` inherits defaults.

**Call `flush()` after indexing.** `flutter_edge_ai_qdrant` keeps new documents in memory until the store is flushed or closed, so an index built without either is lost when the process ends — an Android app killed in the background is the ordinary case ([#492](https://github.com/DenisovAV/flutter_edge_ai/issues/492)). On native `flutter_edge_ai_sqlite` it is a no-op; on web it drains the IndexedDB storage. A store that cannot persist at all throws `VectorStoreException` instead of returning. Custom `VectorStoreRepository` implementations must declare `flush()`.

A field name is checked by the store, in `configure()`. `SqliteVectorStore` is
the strict one — `^[A-Za-z][A-Za-z0-9_]*$`, and not a name `vec0` already uses
(`id`, `embedding`, `content`, `metadata`, `distance`, `k`) — because the name
becomes a real column in a DDL with no quoted-identifier form.
`QdrantVectorStore` takes free-form UTF-8 keys, minus `.` which it reads as a
nested path. So the portable set is sqlite's; a duplicate or empty name is
rejected on any store.

`Filter` supports `must` / `should` / `mustNot` lists of `FieldEquals`, `FieldRange`, `FieldMatchAny` conditions. Both backends honor it: qdrant-edge natively, and the `sqlite-vec`/`vec0` store on all platforms incl. Web (one `Filter` → vec0 declared-column `WHERE`). Filterable fields must be declared as vec0 columns.

**Benchmarks** comparing qdrant-edge to the legacy sqlite + local_hnsw backend across 5 platforms (5 000 documents, EmbeddingGemma 300M, 768-dim): see [example/integration_test/benchmarks/comparison.md](example/integration_test/benchmarks/comparison.md).

## 🛠️ Model Function Calling Support

Function calling is currently supported by the following models:

### ✅ Models with Function Calling Support
- **Gemma 4** (E2B, E4B) - Full function calling support
- **Gemma3n E4B `.litertlm`** - The downloadable/network catalog entry with function calling; an intentional local E2B `.task` fixture also enables it
- **FunctionGemma 270M** - Google's specialized function calling model
- **DeepSeek R1** - Function calling + thinking mode support
- **Qwen** models (0.5B, 0.6B, 1.5B) - Full function calling support
- **Phi-4 Mini** - Advanced reasoning with function calling support

### ❌ Models WITHOUT Function Calling Support
- **Gemma 3 270M** - Text generation only
- **Gemma 3 1B** - Text generation only in the current example configuration
- **SmolLM 135M** - Text generation only
- **FastVLM 0.5B** - Vision model, no function calling
- **SmolLM3 3B** - Text generation with reasoning, no function calling
- **Phi-4 Mini Reasoning** - Reasoning model, no function calling
- **Qwen2-VL 2B** - Vision model, no function calling
- **SmolVLM2 500M** - Vision model, no function calling
- **LLaVA-OneVision 0.5B** - Vision model, no function calling

**Important Notes:**
- When using unsupported models with tools, the plugin will log a warning and ignore the tools
- Models will work normally for text generation even if function calling is not supported
- Check the `supportsFunctionCalls` property in your model configuration

## Platform Support Details 🌐

### Feature Comparison

| Feature | Android | iOS | Web | Desktop | Notes |
|---------|---------|-----|-----|---------|-------|
| **Text Generation** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | Model and format availability varies; see the platform table above |
| **Image Input (Multimodal)** | ✅ Full | ✅ Full | ✅ MediaPipe | ✅ Full | Web `.litertlm` is text-only; native Gemma 4/Gemma3n verified on desktop GPU |
| **Audio Input** | ✅ Full | ✅ Full ¹ | ❌ Not supported | ✅ `.litertlm` only | Gemma3n E2B/E4B + Gemma 4; iOS device-only; Desktop via FFI |
| **Speech-to-Text** | ✅ Full | ✅ Full | ❌ Not supported | ✅ Full | `flutter_edge_ai_speech` (moonshine / Whisper / Parakeet); native only, arm64 on Android |
| **Text-to-Speech** | ✅ Full | ✅ Full | ❌ Not supported | ✅ Full | `flutter_edge_ai_speech` (Matcha); native only, arm64 on Android |
| **Function Calling** | ✅ Select models | ✅ Select models | ✅ Select models | ✅ Select models | Availability depends on the model configuration above |
| **Thinking Mode** | ✅ Full | ✅ Full | ⚠️ Qwen3 tags | ✅ Full | Core parses emitted Qwen3 `<think>` tags on Web; measured Gemma 4 `.litertlm` Web produces no thinking channel |
| **Stop Generation** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | Cancel mid-process |
| **GPU Acceleration** | ✅ Full | ✅ Full | ✅ Full | ✅ Full ² | Metal/WebGPU/Vulkan/DX12 |
| **NPU Acceleration** | ✅ Full | ❌ Not supported | ❌ Not supported | ✅ Windows ³ | Android Qualcomm only (.litertlm) + Windows Intel LunarLake/PantherLake |
| **CPU Backend** | ✅ Full | ✅ Full | ✅ ONNX/WASM | ✅ Full | MediaPipe and LiteRT-LM Web require WebGPU |
| **Streaming Responses** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | Real-time generation |
| **LoRA Support** | ✅ MediaPipe | ✅ MediaPipe | ✅ MediaPipe | ❌ Not supported | LiteRT-LM does not expose LoRA on native or Web |
| **Text Embeddings** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | EmbeddingGemma, Gecko |
| **VectorStore (RAG)** | ✅ qdrant-edge / vec0 | ✅ qdrant-edge / vec0 | ✅ vec0 (WASM) | ✅ qdrant-edge / vec0 | Semantic search + payload `Filter` (all platforms) |
| **File Downloads** | ✅ Background | ✅ Background | ✅ In-memory | ✅ Background | Platform-specific |
| **Asset Loading** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | Desktop falls back to Flutter's `rootBundle` |
| **Bundled Resources** | ✅ Full | ✅ Full | ✅ Full | ❌ Not supported | Native bundles only |
| **External Files (FileSource)** | ✅ Full | ✅ Full | ❌ Not supported | ✅ Full | No local FS on web |

> **Web column note:** the Web image-input and LoRA marks above describe the
> MediaPipe `.task` path; ONNX separately provides CPU/WASM inference.
> On Web, Qwen3's emitted `<think>` tags are parsed by core into
> `ThinkingResponse`. Gemma 4 is different: MediaPipe has no thinking API, and
> the measured **web `.litertlm`** test receives text but no thinking events
> despite passing `extra_context` and filter config. See
> [Web `.litertlm` early-preview feature matrix](#web-litert-lm-early-preview-feature-matrix).
>
> ² **Desktop GPU on Windows:** discrete GPUs crash on `PreferredBackend.gpu`
> in litertlm 1.2.0–1.3.1. Fixed in 1.4.0; on the affected versions use
> `PreferredBackend.cpu` or `.npu`. macOS/Linux GPU and Windows CPU/NPU were
> never affected.
>
> ³ **NPU on Windows:** `npu` is offered per OS, so a PC without an Intel NPU
> can report `activeBackend == npu` while the model runs elsewhere.

### Web Platform Specifics

#### Authentication
- **Required for gated models:** Gemma3n, Gemma 3 1B/270M, EmbeddingGemma
- **Configuration:** Use `await FlutterEdgeAi.initialize(huggingFaceToken: '...')` or pass token per-download
- **Storage:** Tokens stored in browser memory (not localStorage)

#### File Handling
- **Downloads:** Cache/ephemeral modes expose blob URLs; streaming mode writes the model to OPFS
- **Storage:** IndexedDB via `WebFileSystemService`
- **FileSource:** Only works with HTTP/HTTPS URLs or `assets/` paths
- **Local file paths:** ❌ Not supported (browser security restriction)

#### Web Storage Modes

**Three Storage Modes:**

**1. Cache API Mode (default, `WebStorageMode.cacheApi`):**
- Uses browser Cache API with Blob URLs
- Models persist across browser restarts
- Best for models <2GB

**2. Streaming Mode (`WebStorageMode.streaming`):**
- Uses OPFS with ReadableStream
- Bypasses browser 2GB ArrayBuffer limit
- Required for large models (E4B 4GB+, 7B, 27B)
- Requires Chrome 86+, Edge 86+, Safari 15.2+

**3. Ephemeral Mode (`WebStorageMode.none`):**
- Models stored in memory only
- Cleared when browser closes
- For testing/demos

```dart
// Default: Cache API for small models
await FlutterEdgeAi.initialize(webStorageMode: WebStorageMode.cacheApi);

// Streaming for large models (>2GB)
await FlutterEdgeAi.initialize(webStorageMode: WebStorageMode.streaming);

// Check if streaming is supported
final supported = await FlutterEdgeAi.isStreamingSupported();
```

#### Backend Support
- **GPU only on Web (MediaPipe)** — the MediaPipe web engine ignores `preferredBackend` and always runs on the browser's GPU (WebGPU). ONNX on web pins WASM for `PreferredBackend.cpu`.

#### CORS Configuration
- **Required for custom servers:** Enable CORS headers on your model hosting server
- **Firebase Storage:** See [CORS configuration docs](https://firebase.google.com/docs/storage/web/download-files#cors_configuration)
- **HuggingFace:** CORS already configured correctly

#### Memory Limitations
- **Large models:** May hit browser memory limits (2GB typical)
- **Recommended:** Use smaller models (1B-2B) for web platform
- **Best models for web:**
  - Gemma 3 270M (300MB)
  - Gemma 3 1B (500MB-1GB)
  - Gemma3n E2B (3GB) - requires 6GB+ device RAM

#### Browser Cache Storage Limits

| Browser | In-memory blob limit | Persistent storage |
|---------|----------------------|--------------------|
| **Chrome/Firefox** | ~2 GB practical ArrayBuffer limit | Larger models can use OPFS streaming |
| **Safari 17+** | Runtime- and device-dependent | Origin quota can reach 60% of disk; handle `QuotaExceededError` |

#### Web LiteRT-LM early-preview feature matrix

Web `.litertlm` inference (added in 0.16.2) runs Gemma `.litertlm` models
(verified on Gemma 4 E2B/E4B web variants) in the browser through the upstream
[`@litert-lm/core`](https://www.npmjs.com/package/@litert-lm/core) package
(WebGPU + WASM). It is an **early preview** and is intentionally a subset of
the native `.litertlm` path. MediaPipe `.task` on web is unaffected and remains
fully supported.

**Works on web `.litertlm`:**
- ✅ Text generation (sync `getResponse()` and streaming `getResponseAsync()`)
- ✅ Multi-turn chat with history (`createChat` / `openChat`)
- ✅ System instruction (via the conversation preface)
- ✅ Concurrent sessions (`openSession`) — serialized inference (see [Concurrent sessions](#concurrent-sessions-opensession))
- ✅ Large models via OPFS streaming (`WebStorageMode.streaming`) — bypasses Chrome's ~2 GB blob limit
- ✅ GPU only (WebGPU is required; there is no CPU backend on web)

**Web `.litertlm` limitations:**
- ❌ **Vision / image input** — `@litert-lm/core` does not expose the Vision executor config; image inputs are dropped with a debug warning
- ❌ **Audio input** — same reason (no Audio executor config in the JS API)
- ⚠️ **Thinking mode** — Qwen3's emitted `<think>` tags are parsed by core, but the measured Gemma 4 path produces no `ThinkingResponse` even though `extra_context` and filter config are passed
- ❌ **LoRA weights** — `loraPath` throws `UnsupportedError`
- ⚠️ **`stopGeneration()`** — closes the local Dart stream **and** calls the upstream `conversation.cancel()` to abort generation; the cancel is best-effort (the early-preview JS API may throw if nothing is in flight, which is swallowed)
- ⚠️ **`WebStorageMode.none` + model > 2 GB** — the engine `fetch()`es the in-memory blob and trips Chrome's `ERR_BLOB_OUT_OF_MEMORY`; use `WebStorageMode.streaming` for large models

> These limits track the upstream `@litert-lm/core` early-preview API and
> will lift as Google extends the JS executor surface. For vision on Web today,
> use a compatible MediaPipe `.task` build. Audio is unavailable through either
> Web engine. Qwen3 tag-based reasoning can surface on Web; Gemma 4's thinking
> channel cannot.

### Mobile Platform Specifics

#### Android
- **GPU Support:** nothing to add — the OpenCL `<uses-native-library>` entries come from `flutter_edge_ai`'s own manifest through the manifest merger
- **ProGuard:** Automatic rules included for release builds
- **Storage:** Local file system in app documents directory

#### iOS
- **Minimum version:** iOS 15.0; iOS 16.0 only if you use `flutter_edge_ai_mediapipe` (MediaPipe GenAI)
- **Memory entitlements:** Required for large models (see Setup section)
- **Linking:** Static linking required (`use_frameworks! :linkage => :static`)
- **Storage:** Local file system in app documents directory

### Desktop Platform Specifics

#### Storage Locations

Desktop builds store downloaded models outside the user's `Documents/` folder to avoid OneDrive / iCloud / Domain-Roaming sync corrupting FFI mmap of large `.litertlm` files (since 0.15.1):

- **Windows:** `%LOCALAPPDATA%\flutter_gemma\` (never OneDrive-synced; the name predates the rename and is kept so installed models stay found)
- **macOS:** `~/Library/Application Support/<bundle>/flutter_gemma/`
- **Linux:** `~/.local/share/<app>/flutter_gemma/`

Models installed by 0.14.x / 0.15.0 builds that still live under `Documents/` keep working via a fallback read (a debug log nudges users to re-install once for migration).

The full and complete example you can find in `example` folder

## **Important Considerations**

* **Model Size:** Larger models (such as 7b and 7b-it) might be too resource-intensive for on-device inference.
* **Function Calling Support:** Gemma 4, downloadable Gemma3n E4B `.litertlm`, FunctionGemma, DeepSeek, Qwen3, Qwen 2.5, and Phi-4 Mini support function calling in the current network catalog; the intentional local Gemma3n E2B `.task` fixture also enables it. Other models will ignore tools and show a warning. See [Model Function Calling Support](#%EF%B8%8F-model-function-calling-support).
* **Thinking Mode:** Gemma 4, DeepSeek, and Qwen3 can emit structured `ThinkingResponse` events on their supported engines; enable them with `isThinking: true` and the matching `ModelType`. SmolLM3 and Phi-4 Mini Reasoning use `ModelType.general`, so their reasoning remains ordinary text and `isThinking` does not structure it.
* **Multimodal Models:** Gemma3n models with vision support require more memory and are recommended for devices with 8GB+ RAM.
* **iOS Memory Requirements:** Large models require memory entitlements in `Runner.entitlements`.
* **LoRA Weights:** They provide efficient customization without the need for full model retraining.
* **Development vs. Production:** For production apps, do not embed the model or LoRA weights within your assets. Instead, load them once and store them securely on the device or via a network drive.
* **Web Models:** MediaPipe and LiteRT-LM use WebGPU, while ONNX can use CPU/WASM. Multimodal input is available through compatible MediaPipe `.task` builds; the early-preview `.litertlm` Web path is text-only.
* **Image Formats:** The plugin automatically handles common image formats (JPEG, PNG, etc.) when using `Message.withImages()` or `Message.withImage()`.

## **🛟 Troubleshooting**

**Multimodal Issues:**
- Ensure you're using a multimodal model (Gemma 4 E2B/E4B, Gemma3n E2B/E4B, FastVLM, Qwen2-VL, SmolVLM2, or LLaVA-OneVision)
- Set `supportImage: true` when creating model and chat
- Check device memory - multimodal models require more RAM

**Performance:**
- Use GPU backend for better performance with multimodal models
- Consider using CPU backend for text-only models on lower-end devices

**Wrong numbers on GPU (`.litertlm`):**
- Gemma 4 on some GPUs copies digits wrongly from long prompts — `2026/06/23` becomes `20226/12/17`, the same way on every run (LiteRT-LM [#3012](https://github.com/google-ai-edge/LiteRT-LM/issues/3012) on Adreno, [#2814](https://github.com/google-ai-edge/LiteRT-LM/issues/2814) on Metal)
- Pass `activationDataType: ActivationDataType.float32` to `getActiveModel`. Prefill is slower (about 3× on a Snapdragon 8 Elite and an iPhone 11, under 1.5× on an Apple M3 Max); decode speed barely changes
- Native `.litertlm` only — **not on web**. The web engine ignores the value, and so do MediaPipe, ONNX and built-in AI. It reaches the text decoder; the vision and audio encoders keep what the model file asks for
- `float32` activations need more GPU memory, and when the GPU engine cannot be created the model falls back to CPU without an error. Read `model.activeBackend == PreferredBackend.gpu` after loading instead of assuming the GPU ran
- On Android the GPU shares system memory, so on a 4–6 GB phone running out of it at `float32` can end the app rather than fall back to CPU. Both precisions share one compiled GPU program cache per model, so switching recompiles the GPU programs (about 600 MB for Gemma 4 E2B): pick one precision per install rather than per request.
- Every `flutter_edge_ai_litertlm` release applies it (it arrived in `flutter_gemma_litertlm` 1.8.3; older versions ignore it)

**Memory Issues:**
- **iOS**: Ensure `Runner.entitlements` contains memory entitlements (see iOS setup)
- Reduce `maxTokens` if experiencing memory issues
- Use smaller models (1B-2B parameters) for devices with <6GB RAM
- Close sessions and models when not needed
- Monitor token usage with `sizeInTokens()`

**iOS Build Issues:**
- Ensure the minimum iOS version is at least 15.0, or 16.0 when using `flutter_edge_ai_mediapipe` — on the Runner target in Xcode under SPM, or in the `Podfile` when the app has one
- Use static linking: `use_frameworks! :linkage => :static`
- Clean and reinstall pods: `cd ios && pod install --repo-update`
- Check that all required entitlements are in `Runner.entitlements`

## Advanced Usage

### ModelThinkingFilter (Advanced)

For advanced users who need to manually process model responses, the `ModelThinkingFilter` class provides utilities for cleaning model outputs:

```dart
import 'package:flutter_edge_ai/core/extensions.dart';

// Clean response based on model type
String cleanedResponse = ModelThinkingFilter.cleanResponse(
  rawResponse,
  isThinking: false,
  modelType: ModelType.deepSeek,
  fileType: ModelFileType.litertlm,
);

// It removes the reasoning blocks (for these model types even when
// isThinking is false):
// - <think>...</think> (DeepSeek, Qwen, Qwen3)
// - <|channel>thought\n...<channel|> (Gemma 3 / Gemma 4 types)
// and trims whitespace. Turn markers (<end_of_turn>, <|im_end|>) are stripped
// only for .bin / .tflite files — on .task and .litertlm the runtime already
// ends the turn.
```

This is automatically handled by the chat API, but can be useful for custom inference implementations.
