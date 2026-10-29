---
title: Models
description: Supported models, file formats, capabilities, ModelType reference, and download URLs.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai runs any model a registered engine runs: `.litertlm`
(LiteRT-LM), `.task`/`.bin` (MediaPipe), ONNX (ORT-GenAI natively,
Transformers.js on web), GGUF (llama.cpp), or the OS model (built-in AI). The tables below list the
models we have run. On desktop (macOS, Windows, Linux) LiteRT-LM models must be
`.litertlm` — there is no MediaPipe engine there; ONNX models and the OS
built-in model also run on desktop.

For a small custom model, [LiteTune](https://litetune.dev) provides the easier
end-to-end path from Hugging Face data/checkpoints through fine-tuning,
`.litertlm` conversion, verification, and bundling. It is alpha software, so
verify the converted model on the devices and backends you plan to ship.

## Model file types

Flutter Edge AI supports different model file formats, grouped into **three types**
based on how chat templates are handled.

### Type 1: SDK-managed templates

- **`.gguf` files:** llama.cpp through the optional [llama engine](/docs/llama);
  the GGUF supplies its own chat template.
- **`.task` files:** MediaPipe-optimized format for mobile (Android/iOS) and web.
- **`.litertlm` files:** LiteRT-LM format for Android, iOS, Desktop, and web
  (early preview). Never handled by MediaPipe — the two formats go to different
  engines.
- **ONNX models (`ModelFileType.onnx`):** an ORT-GenAI model directory on
  native platforms, a Hugging Face repo through Transformers.js on web.

Chat templates are applied by the runtime rather than by your code — MediaPipe
for `.task`, LiteRT-LM for `.litertlm`, ORT-GenAI or Transformers.js for ONNX —
on every platform, iOS included.

### Type 2: Template from the model type

- **`.bin` files:** standard binary format.
- **`.tflite` files:** LiteRT format (formerly TensorFlow Lite).

The runtime applies no template to these. Core wraps each message in the turn
markers of the `ModelType` you install with, so declare the right one (see the
[ModelType reference](#modeltype-reference)).

### Type 3: System OS models (no file)

**Gemini Nano** (Android, via AICore / ML Kit GenAI), **Apple Foundation Models**
(iOS 26+/macOS), **Windows AI Foundry / Phi Silica** (Windows), and **Gemini Nano
via the browser Prompt API** (Web — Gemini Nano in Chrome, Phi-4-mini in Edge) are **built into the
OS/browser** — there is no model file to bundle or download; the platform owns the
weights. Add [`flutter_edge_ai_builtin_ai`](/docs/packages), register
`BuiltInAiEngine()`, and use `ModelFileType.builtIn`. Availability is
device-gated — Gemini Nano needs a phone on [Google's Prompt API device list](https://developers.google.com/ml-kit/genai#prompt-device), Apple FM needs Apple
Intelligence enabled on iPhone 15 Pro+/M-series, and Windows needs Windows 11
25H2+ on Copilot+-class hardware and a packaged app (nothing to configure to
build — `flutter_local_ai` resolves the Windows App SDK projection itself). On Android
the package requires **`minSdk 26`** and Kotlin 2.3.21.

👉 See **[Built-in AI](/docs/builtin-ai)** for the full setup, the availability
probe (`BuiltInAi.availability()` / `BuiltInAi.ensureReady()`), and fallback
guidance.

<Info>

`ModelFileType` is what selects the engine — it is **not** inferred from the file
name. `installModel` defaults it to `ModelFileType.task`, so declare it
explicitly: `ModelFileType.litertlm` for `.litertlm` files (omitting it routes the
model to MediaPipe, which cannot read that format), `ModelFileType.task` for
`.task`, `ModelFileType.binary` for `.bin` and `.tflite`, `ModelFileType.onnx`
for ONNX models ([`flutter_edge_ai_onnx`](/docs/onnx)), and
`ModelFileType.builtIn` for OS-provided models. `ModelFileType.gguf` (core
2.3.2) selects the optional [llama.cpp engine](/docs/llama),
`flutter_edge_ai_llama`.

</Info>

### Format by platform

| Format | Android | iOS | Web | Desktop | Use Case |
|---|:---:|:---:|:---:|:---:|---|
| `.gguf` | ✅ | ✅ | ✅ | ✅ | Optional llama.cpp engine; model-provided templates, [qualification limits](/docs/llama) |
| `.task` | ✅ | ✅ ⁴ | ✅ | ❌ | Every model shipped as `.task` (see the tables below). MediaPipe is maintenance-only — new apps should use `.litertlm` |
| `.litertlm` | ✅ | ✅ ¹ | ⚠️ ² | ✅ | Every model shipped as `.litertlm` (see the tables below); EmbeddingGemma 2 embeddings (every platform; web from litertlm 1.13.1) |
| `-web.task` | ❌ | ❌ | ✅ | ❌ | Web-specific MediaPipe builds (Gemma 4, Gemma 3 1B and Gemma 3 270M in the current catalog) |
| `.bin` | ✅ | ✅ | ✅ | ❌ | Core formats the prompt from the `ModelType` |
| `.tflite` | ✅ | ✅ | ✅ | ✅ | LLM via `ModelFileType.binary` (MediaPipe, mobile and web), and LiteRT embedding models (EmbeddingGemma, Gecko) on every platform |
| `onnx` | ✅ | ✅ | ✅ | ✅ | ONNX models — an ORT-GenAI model directory on native, a Hugging Face repo via Transformers.js on Web — [ONNX](/docs/onnx) |
| `builtIn` (no file) | ✅ | ✅ | ✅ | ⚠️ ³ | OS/browser model — [Built-in AI](/docs/builtin-ai) |

¹ iOS `.litertlm` runs on the FFI engine — vision and audio supported on physical
devices. The Simulator stays CPU-only because Metal sim has a 256 MB
single-allocation cap.

² Web `.litertlm` is an **early preview** via `@litert-lm/core`. A language
model gets text, function calling and thinking, and only from a dedicated web
export (`-web.litertlm`) — Gemma 4 and Gemma 3n today; a native language-model
`.litertlm` installs on web and then fails at the first generation, and no
`.litertlm` language model takes images or audio on web. EmbeddingGemma 2 is
the exception: its generic `.litertlm` bundles embed text and images on web
through WebGPU, and the 740m audio from litertlm 1.13.2 (see
[Embedding models](#embedding-models)). See the feature matrix in
[Troubleshooting](/docs/troubleshooting). For image input to a chat model on
web use a MediaPipe `-web.task` build. LoRA works only on MediaPipe `.task`.

³ On desktop the OS model exists on **macOS** (Apple Foundation Models) and
**Windows** (AI Foundry; Windows 11 25H2+ on Copilot+-class hardware, packaged
app) — not on Linux. Every platform still gates it at
runtime: probe with `BuiltInAi.availability()`.

⁴ On iOS run `.task` models on `PreferredBackend.cpu`: on the GPU, MediaPipe is
killed for memory while loading even Gemma 3 1B. See
[MediaPipe → Backends](/docs/mediapipe#backends).

## Model capabilities

| Model Family | Best For | Function Calling | Thinking Mode | Vision | Languages | Size |
|---|---|:---:|:---:|:---:|---|---|
| **Gemma 4 E2B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ ⁵ | ✅ | Multilingual | 2.6GB |
| **Gemma 4 E4B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ ⁵ | ✅ | Multilingual | 3.7GB |
| **Gemma3n** | On-device multimodal chat and image analysis | ⚠️ ⁶ | ❌ | ✅ | Multilingual | 3.1-4.9GB |
| **FastVLM 0.5B** | Fast vision-language inference | ❌ | ❌ | ✅ | Multilingual | 1.2GB |
| **Qwen2-VL 2B** | Vision-language chat (image + text) | ❌ | ❌ | ✅ | Multilingual | 1.8GB |
| **SmolVLM2 500M** | Compact vision-language model | ❌ | ❌ | ✅ | Multilingual | 0.36GB |
| **LLaVA-OneVision 0.5B** | Compact vision-language model | ❌ | ❌ | ✅ | Multilingual | 0.83GB |
| **VibeVoice-ASR 2.2B (BitNet)** | Speech to text: a spoken clip in, its transcript out | ❌ | ❌ | ❌ | en, zh, fr, it, ko, pt, vi | 2.0GB |
| **Phi-4 Mini** | Advanced reasoning and instruction following | ✅ | ❌ | ❌ | Multilingual | 3.9GB |
| **Phi-4 Mini Reasoning** | Step-by-step reasoning | ❌ | ⚠️ ‡ | ❌ | Multilingual | 2.8GB |
| **DeepSeek R1** | High-performance reasoning and code generation | ✅ | ✅ | ❌ | Multilingual | 1.8–1.9GB |
| **Qwen3 0.6B** | Compact multilingual chat with function calling | ✅ | ✅ | ❌ | Multilingual | 345MB |
| **Qwen 2.5** | Strong multilingual chat and instruction following | ✅ | ❌ | ❌ | Multilingual | 0.5-1.6GB |
| **Gemma 3 1B** | Balanced and efficient text generation | ❌ | ❌ | ❌ | Multilingual | 0.6GB |
| **Gemma 3 270M** | Ideal for fine-tuning (LoRA on the `.task` build) for specific tasks | ❌ | ❌ | ❌ | Multilingual | 0.3GB |
| **FunctionGemma 270M** | Specialized for function calling on-device | ✅ | ❌ | ❌ | Multilingual | 284MB |
| **SmolLM 135M** | Ultra-compact, resource-constrained devices | ❌ | ❌ | ❌ | English | 167MB |
| **LFM2.5 230M (Liquid AI)** | Smallest desktop entry; no HF token needed | ❌ | ❌ | ❌ | Multilingual | 177MB |
| **SmolLM3 3B** | Multilingual small LLM with reasoning mode | ❌ | ⚠️ ‡ | ❌ | Multilingual | 2.0GB |
| **TranslateGemma 4B** † | Single-shot 55-language translation | ❌ | ❌ | ❌ | 55 languages | 2.0–3.9GB |
| **Phi-3.5 Mini (ONNX)** | Text chat through ORT-GenAI on native platforms | — | ❌ | ❌ | Multilingual | 2.8GB |
| **Qwen 2.5 0.5B (ONNX)** | Text chat in the browser through Transformers.js | — | ❌ | ❌ | Multilingual | 0.5GB |
| **Gemini Nano** (built-in) | The OS model on Android, and in Chrome | ✅ prompt-based | ❌ | ✅ Android | varies | system |
| **Apple Foundation Models** (built-in) | The OS model on iOS and macOS | ✅ prompt-based | ❌ | ⚠️ OS 27 | varies | system |
| **Phi Silica** (built-in) | The OS model on Windows | ✅ prompt-based | ❌ | ❌ | varies | system |

⁵ Gemma 4 **Thinking Mode** needs LiteRT-LM (`.litertlm`): Android, iOS, Desktop
and Web (measured on Gemma 4 E2B in Chrome). MediaPipe Web cannot enable it and
ONNX Web ignores it.
Qwen3 is different: core parses its emitted `<think>` tags on every platform,
including Web.

⁶ Gemma3n function calling: the downloadable catalog enables it only on the E4B
`.litertlm` build.

— not run. The ONNX engine is text-only and ignores `enableThinking`; see
[ONNX](/docs/onnx). Built-in AI calls functions through the prompt; Apple
Foundation Models takes images only on OS 27 with an OS 27 SDK (not verified on
a device yet), and the Chrome Prompt API and Phi Silica are text-only — see
[Built-in AI](/docs/builtin-ai), which also covers Phi-4-mini in Edge.

‡ SmolLM3 runs as `ModelType.general`, Phi-4 Mini Reasoning as
`ModelType.phi`. These `.litertlm` bundles stream their reasoning
on a thought channel, which arrives as `ThinkingResponse`; a model without such a
channel keeps its raw thinking text inside the answer. See
[Thinking Mode](/docs/thinking-mode).

<Warning>

† **TranslateGemma is CPU-only for now.** Google hasn't released a
mobile/desktop `.litertlm` bundle
([HF discussion #5](https://huggingface.co/google/translategemma-4b-it/discussions/5)).
The community-converted bundle from
[`barakplasma/translategemma-4b-it-android-task-quantized`](https://huggingface.co/barakplasma/translategemma-4b-it-android-task-quantized)
runs correctly on the **CPU** and returns only padding on the **GPU**.

Measured here on an M4 Pro (macOS, Metal), both published artifacts, same
prompt and the same session code, backend the only variable:

| artifact | `PreferredBackend.cpu` | `PreferredBackend.gpu` |
|---|---|---|
| `int4-generic` (2.0 GB, INT4 blockwise) | `Guten Morgen` | 997 `<pad>` tokens, nothing else |
| `dynamic_int8-generic` (3.9 GB, INT8 channelwise) | `Guten Morgen` | 997 `<pad>` tokens, nothing else |

Nothing fails: the Metal engine is created, `activeBackend` reports `gpu` (so it
is not a silent fallback), generation runs and emits padding until it reaches the
context limit. A `gemma-4-E2B-it.litertlm` bundle on the same machine, the same code path and the same backend answers correctly with no padding, so this is not the Metal path in general. Earlier revisions of this page said the bundle crashed the LiteRT
GPU partitioner because its `EMBEDDING_LOOKUP` weights stay float32. Nothing in
the runs above crashes, so that description does not hold; the repository has
published these `.litertlm` artifacts since 2026-03-31, so it did not describe a
later change either. Reproducing across two different quantization recipes also
rules the bit width out.

Tracked at
[LiteRT-LM#1748](https://github.com/google-ai-edge/LiteRT-LM/issues/1748).
Use `PreferredBackend.cpu` for this model (≈90 s prefill on a 4 B int4 bundle on
M-series Macs). If you are converting it yourself, **AI Edge Quantizer** is the
supported route today — the `litert-lm` quantization CLI announced in that thread
never shipped — with published recipes and Model Explorer for the layer regexes
([maintainer's pointers](https://github.com/google-ai-edge/LiteRT-LM/issues/1748#issuecomment-4475268373)).

</Warning>

## ModelType reference

When installing models, specify the correct `ModelType`:

| Model Family | ModelType | Examples |
|---|---|---|
| **Gemma 4** | `ModelType.gemma4` | Gemma 4 E2B, Gemma 4 E4B (native function-call tokens) |
| **Gemma 3 / Gemma3n** | `ModelType.gemmaIt` | Gemma 3 1B, Gemma 3 270M, Gemma3n E2B/E4B, TranslateGemma 4B |
| **DeepSeek** | `ModelType.deepSeek` | DeepSeek R1 |
| **Qwen 2.5, Qwen3-2507** | `ModelType.qwen` | Qwen 2.5 1.5B, Qwen 2.5 0.5B, Qwen3 4B Instruct/Thinking 2507 (installed from a Hugging Face manifest, 2507 still resolves to `qwen3`; pass `qwen` yourself) |
| **Qwen 3** (the original hybrid) | `ModelType.qwen3` | Qwen3 0.6B |
| **Qwen 3.5 / 3.6 / 3.8** | `ModelType.qwen35` | Qwen3.5 0.8B, 2B, 4B |
| **Phi-4** | `ModelType.phi` | Phi-4 Mini (parses Phi's own tool-call markers), Phi-4 Mini Reasoning |
| **Llama** | `ModelType.llama` | Llama 3.2 Instruct (its sampling defaults; not in the tables above) |
| **Hammer** | `ModelType.hammer` | Hammer 2.1 (its sampling defaults; not in the tables above) |
| **FunctionGemma** | `ModelType.functionGemma` | FunctionGemma 270M IT |
| **General** | `ModelType.general` | FastVLM 0.5B, SmolLM 135M, LFM2.5 230M (Liquid AI), SmolLM3 3B, Qwen2-VL 2B, SmolVLM2 500M, LLaVA-OneVision 0.5B, VibeVoice-ASR, Phi-3.5 Mini (ONNX), the built-in OS models |

<Info>

Gemma 4 (`ModelType.gemma4`) and FunctionGemma on a `.litertlm` route their native
tool-call tokens through the LiteRT-LM SDK's chat-template path. For Gemma 3 and
earlier, keep `ModelType.gemmaIt`; a `.task` FunctionGemma keeps the text format
flutter_edge_ai renders itself.

</Info>

**Usage example:**

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

## Supported models & platforms

The LiteRT-LM (`.litertlm`) language models come from the
[Model Registry](/docs/registry), the same files the catalog installs
installs. A cell shows, per backend, the best that any build of the model has
on that platform: 📝 documented to work, ⚪ the package runs it but no run has
been recorded, ❌ known broken (✅ verified once runs are recorded). The
registry page lists every build with its pinned file and the source of each
mark.

<!-- registry:llm-platforms -->

<!-- GENERATED by tool/model_registry from model_registry/. Edit the registry, not this table. -->

| Model | Size | Android | iOS | macOS | Windows x64 | Linux x64 | Linux arm64 | Web | HF token |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| [DeepSeek R1 Distill Qwen 1.5B](/docs/registry#deepseek-r1-distill-qwen-1.5b) | 1.83&nbsp;GB | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [FastVLM 0.5B](/docs/registry#fastvlm-0.5b) | 1.16&nbsp;GB | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪ |  | no |
| [FunctionGemma 270M (Flutter demo fine-tune)](/docs/registry#functiongemma-270m-flutter-demo) | 284&nbsp;MB | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [FunctionGemma 270M](/docs/registry#functiongemma-270m-it) | 284&nbsp;MB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Gemma 3 1B](/docs/registry#gemma-3-1b-it) | 584&nbsp;MB | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪ |  | yes |
| [Gemma 3 270M](/docs/registry#gemma-3-270m-it) | 304&nbsp;MB | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;❌ | GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪ |  | yes |
| [Gemma 3n E2B](/docs/registry#gemma-3n-e2b-it) | 3.04–3.66&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ NPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;📝 | yes |
| [Gemma 3n E4B](/docs/registry#gemma-3n-e4b-it) | 4.28–4.92&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;📝 | yes |
| [Gemma 4 E2B](/docs/registry#gemma-4-e2b-it) | 2.01–2.59&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;📝 NPU&nbsp;📝 | GPU&nbsp;📝 CPU&nbsp;📝 | GPU&nbsp;🕓 CPU&nbsp;🕓 | GPU&nbsp;📝 CPU&nbsp;📝 NPU&nbsp;📝 | GPU&nbsp;📝 CPU&nbsp;📝 | GPU&nbsp;📝 CPU&nbsp;📝 NPU&nbsp;📝 | GPU&nbsp;📝 | no |
| [Gemma 4 E4B](/docs/registry#gemma-4-e4b-it) | 2.97–3.66&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;📝 | no |
| [LFM2.5 230M](/docs/registry#lfm2.5-230m) | 177–266&nbsp;MB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [LLaVA-OneVision 0.5B](/docs/registry#llava-onevision-0.5b) | 829&nbsp;MB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Phi-4 Mini Instruct](/docs/registry#phi-4-mini-instruct) | 3.91&nbsp;GB | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Phi-4 Mini Reasoning](/docs/registry#phi-4-mini-reasoning) | 2.78&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Qwen2-VL 2B](/docs/registry#qwen2-vl-2b) | 1.78&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Qwen 2.5 1.5B Instruct](/docs/registry#qwen2.5-1.5b-instruct) | 1.60–6.18&nbsp;GB | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [Qwen3 0.6B](/docs/registry#qwen3-0.6b) | 345–498&nbsp;MB | GPU&nbsp;⚪ CPU&nbsp;📝 NPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;📝 | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [SmolLM3 3B](/docs/registry#smollm3-3b) | 2.00–3.13&nbsp;GB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [SmolVLM2 500M](/docs/registry#smolvlm2-500m) | 361&nbsp;MB | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;📝 CPU&nbsp;⚪ | GPU&nbsp;⚪ CPU&nbsp;⚪ |  | no |
| [TranslateGemma 4B](/docs/registry#translategemma-4b-it) | 2.01–3.92&nbsp;GB | GPU&nbsp;❌ CPU&nbsp;📝 | GPU&nbsp;❌ CPU&nbsp;📝 | GPU&nbsp;❌ CPU&nbsp;📝 | GPU&nbsp;❌ CPU&nbsp;📝 | GPU&nbsp;❌ CPU&nbsp;📝 | GPU&nbsp;❌ CPU&nbsp;⚪ |  | no |
<!-- /registry:llm-platforms -->

The Qwen3 0.6B build the catalog installs is
`Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` (345 MB). `Qwen3-0.6B.litertlm`
(614 MB) failed to load from `flutter_edge_ai_litertlm` 1.7.0 until the repo
replaced its tokenizer on 2026-10-13 at 15:53 UTC
([#659](https://github.com/DenisovAV/flutter_edge_ai/issues/659), upstream
[LiteRT-LM #3865](https://github.com/google-ai-edge/LiteRT-LM/issues/3865)); a
copy downloaded before that still fails — uninstall it and install it again.

### Other formats

Not in the registry: MediaPipe `.task` files, ONNX models, the OS models, and
VibeVoice.

| Model | Format | Size | Desktop | Mobile | Web | HF token |
|---|---|---|:---:|:---:|:---:|:---:|
| [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) | `.task` | 2.0GB | ❌ | ❌ | ✅ | no |
| [Gemma 4 E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | `.task` | 3.0GB | ❌ | ❌ | ✅ | no |
| [Gemma3n E2B](https://huggingface.co/google/gemma-3n-E2B-it-litert-preview) | `.task` | 3.1GB | ❌ | ✅ | ❌ | yes |
| [Gemma3n E4B](https://huggingface.co/google/gemma-3n-E4B-it-litert-preview) | `.task` | 4.4GB | ❌ | ✅ | ❌ | yes |
| [Gemma 3 1B](https://huggingface.co/litert-community/Gemma3-1B-IT) | `.task` | 0.5GB | ❌ | ✅ | ✅ | yes |
| [Gemma 3 270M](https://huggingface.co/litert-community/gemma-3-270m-it) | `.task` | 0.3GB | ❌ | ✅ | ✅ | yes |
| [DeepSeek R1 Distill Qwen 1.5B](https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B) | `.task` | 1.86GB | ❌ | ✅ | ❌ | no |
| [Qwen 2.5 1.5B](https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct) | `.task` | 1.6GB | ❌ | ✅ | ❌ | no |
| [Qwen 2.5 0.5B](https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct) | `.task` | 0.5GB | ❌ | ✅ | ❌ | no |
| [SmolLM 135M](https://huggingface.co/litert-community/SmolLM-135M-Instruct) | `.task` | 167MB | ❌ | ✅ | ❌ | no |
| [Phi-4 Mini](https://huggingface.co/litert-community/Phi-4-mini-instruct) | `.task` | 3.9GB | ❌ | ✅ | ❌ | no |
| [FunctionGemma 270M](https://huggingface.co/sasha-denisov/function-gemma-270M-it) | `.task` | 284MB | ❌ | ✅ | ❌ | no |
| [VibeVoice-ASR-BitNet](https://huggingface.co/litert-community/VibeVoice-ASR-BitNet) ⁹ | `.litertlm` | 2.0GB | ✅ macOS | ✅ Android | ❌ | no |
| [Phi-3.5 Mini](https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx) ⁸ | ONNX | 2.8GB | ✅ | ✅ | — | no |
| [Qwen 2.5 0.5B](https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct) ⁷ | ONNX | 0.5GB | ❌ | ❌ | ✅ | no |
| [Gemini Nano](/docs/builtin-ai) | built-in | system | ❌ | ✅ Android | ✅ Chrome | — |
| [Apple Foundation Models](/docs/builtin-ai) | built-in | system | ✅ macOS | ✅ iOS | ❌ | — |
| [Phi Silica](/docs/builtin-ai) | built-in | system | ✅ Windows | ❌ | ❌ | — |

`.task` files run through [MediaPipe](/docs/mediapipe), which has no desktop
engine.

⁷ On web, Qwen 2.5 0.5B runs as the ONNX build from `onnx-community`, through
Transformers.js ([`flutter_edge_ai_onnx`](/docs/onnx)). That build is web-only.

⁸ An ORT-GenAI model directory — `fromHuggingFace` installs its CPU folder,
`cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4` — run on macOS arm64,
Linux x64, Windows x64, Android arm64 and iOS arm64. It peaks at about 3.7 GB
of RAM, so plan for a 6 GB+ phone. — means not run.

⁹ Speech recognition, not chat: install it as `ModelType.general` (the
repo's `litertlm_manifest.json` sets `maxTokens: 2048` and audio — pass
`getActiveModel(defaults: r.runtime)`), send the clip as `audioBytes` with the
text `This is a X.XX seconds audio, please transcribe it.` (the clip's length),
and decode greedily (`topK: 1`). Leave `preferredAudioBackend` unset: the audio
encoder has to run on the CPU, and on a GPU delegate it returns an empty
transcript; the language model may run on the GPU. `ModelType.general` sends
the audio before the text, which this model needs
([multimodal order](/docs/multimodal#order-of-images-audio-and-text)).
Measured with the language model on the GPU of a Galaxy S24, 80 synthesized
clips of 0.8–3.9 s: word error rate 0.32 under 1.5 s, 0.18 at 1.5–2.5 s and
0.07 from 2.5 s, with 9–11 s to the first token whatever the length, because
the audio encoder always processes a 30 s window on the CPU. On macOS, with
the language model on Metal, 8 of those clips were transcribed the same way.
Web cannot send audio to an LLM.

The built-in models download nothing and need no token; availability is
decided by the device at run time, and Edge runs Phi-4-mini through the same
Prompt API — see [Built-in AI](/docs/builtin-ai).

## Installation sources

### From the model catalog

`flutter_edge_ai` 2.5.5, with the `flutter_edge_ai_litertlm` and
`flutter_edge_ai_speech` releases that ship the catalog, installs a
[Model Registry](/docs/registry) build by name through the usual installers.
Each build carries its model type, file type, Hugging Face commit, file size
and install file name, so there is no URL to copy and nothing to keep in step:

```dart
// A language model, an embedder, a speech model.
await FlutterEdgeAi.installModelFromCatalog(LiteRtLmModels.gemma4E2bIt.generic)
    .withProgress((percent) => print('downloading: $percent%'))
    .install();
await FlutterEdgeAi.installEmbedder()
    .fromCatalog(
      LiteRtEmbedders.embeddinggemma300m.seq256,
      token: huggingFaceToken, // the repository is gated
    )
    .install();
await FlutterEdgeAi.installStt().fromCatalog(LiteRtSpeechModels.whisperTiny.f32)
    .install();

// Every model the registered packages offer, and the build for this device.
for (final model in FlutterEdgeAi.catalog.models) {
  final variant = model.variantFor(backend: PreferredBackend.gpu);
  print('${model.id}: ${variant?.id ?? 'nothing for the GPU here'}');
}
```

`variantFor` leaves out a build this device cannot run: a build compiled for
another NPU, a web export on a phone. A build compiled for an NPU is picked
only for the SoC the app names (`variantFor(backend: PreferredBackend.npu,
npu: …)`; without `npu:` it throws), because the package does not read the
device's SoC. An install from the catalog refuses a build this device cannot
run before it downloads anything. A build compiled for an NPU names the
context it was compiled for (`requiredMaxTokens`); keep `maxTokens` at or
below it. After the download, and before the model becomes active, each
file's size is checked against the registry: a file of another size stays
installed, is not made active, and `install()` throws
`ModelValidationException`. `withProgress` weights the files by their pinned
sizes. An LLM is installed under the registry's install name (for example
`phi-4-mini-reasoning.litertlm`), which `isModelInstalled`, `getModelPath` and
`uninstallModel` take. `install(activate: false)` installs an LLM without
making it active. A LoRA is not installed through the catalog.

The catalog pins every file to a Hugging Face commit. A model installed
earlier from a `/resolve/main/` URL is a different source, so its first
install from the catalog downloads the file again (once); later installs from
the catalog find it installed.

### From a URL, an asset or a file

```dart
// Network — .litertlm is the cross-platform default (Android/iOS/Desktop).
// For mobile-only or web-only apps you can substitute a .task URL — and drop
// the fileType, which defaults to ModelFileType.task. On iOS, run a .task
// model on PreferredBackend.cpu.
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

// External file (native only)
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromFile('/path/to/model.litertlm')
  .install();
```

### Hugging Face

Install a model straight from a Hugging Face repo. The resolver that reads a repo's deployment manifest ships with the engine, so registering the engine is enough — there is no separate resolver list to maintain.

**One call (manifest-driven)** — omit `file`, and `fromHuggingFace(repo)` resolves the repo's manifest (e.g. `litertlm_manifest.json`) at install time, installs the right revision-pinned variant for the device, and returns the manifest's overridable runtime defaults on the result:

```dart
// The engine carries its resolver — nothing else to register.
await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

final install = await FlutterEdgeAi.installModel(
  modelType: ModelType.qwen,        // a specific type wins over the manifest's
  fileType: ModelFileType.litertlm, // selects the litertlm resolver
)
  // The manifest types this repo `qwen3`; 2507 is a `qwen` model (see the
  // ModelType table). `ModelType.general` would take the manifest's type.
  .fromHuggingFace('litert-community/Qwen3-4B-Thinking-2507')
  .install();

final model = await FlutterEdgeAi.getActiveModel(defaults: install.runtime);
// `minOutputTokens` is a FLOOR, not a cap — leave `maxOutputTokens` unset (or
// keep it >= `install.runtime?.minOutputTokens`). Passing the floor as the cap
// would truncate a reasoning model mid-thought.
final session = await model.createSession(
  enableThinking: install.runtime?.thinkingDeclared ?? false,
);
```

`.onnx` repos install the whole ORT-GenAI **directory** — the ONNX resolver (carried by `OnnxEngine`) lists the repo, picks a CPU execution-provider folder (the bundled runtime is CPU-only; pin one with `OnnxHuggingFaceResolver(variant: …)`) and downloads every file in it; see [ONNX](/docs/onnx). `.builtIn` repos surface that OS models have no Hugging Face file.

**Explicit file** — pass `file`, and `fromHuggingFace(repo, file:)` resolves `…/resolve/<revision>/<file>` and installs it directly, for any `fileType` (no manifest needed; the HF token is applied to `huggingface.co` automatically):

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromHuggingFace('litert-community/Gemma3-1B-IT', file: 'gemma3-1b-it-int4.litertlm', token: 'optional')
  .install();
```

**Inspect first** — `resolveHuggingFace(repo, fileType:)` returns the resolved identity plus overridable runtime defaults WITHOUT installing, so you can inspect the variant, its notes, and defaults before committing:

```dart
final r = await FlutterEdgeAi.resolveHuggingFace(
  'litert-community/Qwen3-4B-Thinking-2507',
  fileType: ModelFileType.litertlm,
);
// … inspect r.file / r.notes / r.runtime …
await FlutterEdgeAi.installModel(
  // 2507 resolves to qwen3; ModelType.qwen is the right type for it.
  modelType: ModelType.qwen,
  fileType: r.fileType,
)
  .fromNetwork(r.url) // r.url pins the resolver's revision
  .install();
```

The resolver lives in the engine package — `LitertlmManifestResolver` in `flutter_edge_ai_litertlm` reads `litertlm_manifest.json` — and rides on the engine via `HuggingFaceResolverSource`, so `initialize(inferenceEngines: […])` auto-registers it. Pass `initialize(huggingFaceResolvers: [...])` only to override an engine's default (e.g. `LitertlmManifestResolver(revision: 'abc123')` to pin a commit).

### Source capabilities

| Source Type | Platform | Progress | Resume | Authentication | Use Case |
|---|---|---|---|---|---|
| **NetworkSource** | All | ✅ Detailed | ⚠️ Server-dependent | ✅ Supported | HuggingFace, CDNs, private servers |
| **AssetSource** | All | ⚠️ End only | ❌ No | ❌ N/A | Models bundled in app assets |
| **BundledSource** | All | ⚠️ End only | ❌ No | ❌ N/A | Native platform resources |
| **FileSource** | Native (no Web) | ⚠️ End only | ❌ No | ❌ N/A | User-selected files (file picker) |

<Info>

Resume after interruption is server-dependent and **not supported by the
HuggingFace CDN** — flutter_edge_ai uses smart retry logic with exponential
backoff and automatic restart instead. See [Troubleshooting](/docs/troubleshooting).

</Info>

### Android foreground service (large downloads)

Android has a 9-minute background execution limit. A foreground service shows a
notification and exempts the download from battery-optimization kills, and you
have to ask for it — the default configures no notification, and the platform
will not start the service without one, so file size alone changes nothing:

```dart
// DEFAULT — no foreground service; pass foreground: true to get one
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url)  // foreground: null
  .install();

// Force foreground mode
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url, foreground: true)
  .install();
```

iOS uses native URLSession which handles long downloads automatically — no
foreground service needed.

### Cancelling downloads

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart'; // exports CancelToken

final cancelToken = CancelToken();

final future = FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
  .fromNetwork(url)
  .withCancelToken(cancelToken)
  .withProgress((progress) => print('Progress: $progress%'))
  .install();

// Cancel from elsewhere (e.g. user pressed a cancel button)
cancelToken.cancel('User cancelled download');

try {
  await future;
} catch (e) {
  if (CancelToken.isCancel(e)) {
    print('Download was cancelled by user');
  }
}
```

`CancelToken` cancels all files in multi-file downloads (e.g. embedding model +
tokenizer), works on mobile + web, and throws `DownloadCancelledException`.

## Speech models

On-device speech via the opt-in [`flutter_edge_ai_speech`](/docs/speech) package —
selectable, profile-driven pipelines (you pick the model with `SttModelType` /
`TtsModelType`). **moonshine-tiny**, **Whisper**, and **Parakeet** (STT) and
**Matcha**, **Qwen3-TTS** (multilingual), and **Inflect-Nano-v2** (fast) TTS work
end-to-end today. `TtsModelType.kokoro` and `TtsModelType.supertonic` have no pipeline: using either throws `UnimplementedError`. Native only (no
Web). See [Speech](/docs/speech) for usage.
A `VoiceSession` also chains STT → LLM → TTS into a push-to-talk voice loop —
see [Speech](/docs/speech).

**Speech-to-text**

| Model | Input | Builds (size) | Documented on (CPU) | Auth |
|---|---|---|---|---|
| **[Moonshine Tiny](/docs/registry#moonshine-tiny)** | raw 16 kHz PCM | f32 109 MB, int8 52 MB | Android, iOS, macOS, Windows x64, Linux x64; f32 also Linux arm64 | ❌ |
| **[Whisper Tiny](/docs/registry#whisper-tiny)** | log-mel | f32 151 MB, int8 41 MB | Android, iOS, macOS, Windows x64, Linux x64 | ❌ |
| **[Whisper Base](/docs/registry#whisper-base)** | log-mel | int8 77 MB | Android, iOS, macOS, Windows x64, Linux x64 | ❌ |
| **[Parakeet CTC 0.6B](/docs/registry#parakeet-ctc-0.6b)** | log-mel | f32 2.35 GB | macOS, Windows x64, Linux x64; not run on phones | ❌ |

Sizes are the model file; the tokenizer adds 0.4–2.5 MB. The registry also
lists Whisper Base f32 (290 MB) and Parakeet CTC int8 (596 MB), which have not
been run, and per-SoC NPU builds, which `flutter_edge_ai_speech` refuses.

Whisper is **multilingual** — the shipped checkpoints are the multilingual ones
(no `.en` suffix), so all 99 of Whisper's languages are available. Set a default
for the recognizer, override it per transcription, or both:

```dart
// Default for every transcription on this recognizer.
final stt = await FlutterEdgeAi.getActiveStt(language: 'de');
final german = await stt.transcribe(germanPcm);

// One call in another language — same recognizer, nothing reloaded.
final french = await stt.transcribe(frenchPcm, language: 'fr');
```

Both are free: the language is one token in the decoder's seed prompt, and that
prompt is rebuilt on every transcription. Switching languages never reloads the
model or invalidates the recognizer you are holding.

The value is Whisper's own language code without the delimiters, and it defaults
to `'en'`. It decides the OUTPUT language only — the weights understand the
audio either way, so asking for `'en'` on German speech returns an English
translation rather than an error.

Moonshine and Parakeet have no language token in their decoder prompt and
**reject** the parameter with an `ArgumentError` rather than ignoring it; both
are English-only.

**Text-to-speech**

| Model | Output | Size | Documented on (CPU) | Auth |
|---|---|---|---|---|
| **[Matcha-TTS](/docs/registry#matcha-tts)** | 16-bit PCM @ 22050 Hz | 94 MB | Android, iOS, macOS, Windows x64, Linux x64, Linux arm64 | ❌ |
| **[Qwen3-TTS 0.6B](/docs/registry#qwen3-tts-0.6b)** (10 languages + `auto`) | 16-bit PCM | 1.89 GB | macOS; not run elsewhere | ❌ |
| **[Inflect-Nano-v2](/docs/registry#inflect-nano-v2)** (fast) | 16-bit PCM @ 24 kHz | 36 MB | Android, iOS, macOS, Windows x64, Linux x64 | ❌ |

## Embedding models

The LiteRT embedding models below generate **768-dimensional vectors**. The
numbers in names (64/256/512/1024/2048) indicate **maximum input sequence length
in tokens**, not embedding dimension. An ONNX model's dimension is its own —
all-MiniLM-L6-v2 is 384-dim. See
[Embeddings & RAG](/docs/embeddings-and-rag) for usage. An input longer than
the maximum is never truncated: it throws `EmbeddingInputTooLongException`.

| Model | Parameters | Dimensions | Max Seq Length | Size | Auth Required |
|---|---|---|---|---|---|
| **[EmbeddingGemma 2 text](/docs/registry#embeddinggemma-2-text-270m)** (`.litertlm`; web from litertlm 1.13.1) | 270M | 768D | 1024 tokens | 165MB + 71MB weight cache (native) | ❌ |
| **[EmbeddingGemma 2 text + vision](/docs/registry#embeddinggemma-2-text-vision-440m)** (`.litertlm`, text and images; web from litertlm 1.13.1) | 440M | 768D | 1024 tokens | 388MB + 71MB + 218MB weight caches (native) | ❌ |
| **[EmbeddingGemma 2 text + vision + audio](/docs/registry#embeddinggemma-2-740m)** (`.litertlm`, text, images and audio, from litertlm 1.13.1; web audio from 1.13.2) | 740M | 768D | 1024 tokens | 485MB + 385MB weight caches (native) | ❌ |
| **[Gecko 64](/docs/registry#gecko-110m-en)** | 110M | 768D | 64 tokens | 112MB | ❌ |
| **[Gecko 256](/docs/registry#gecko-110m-en)** | 110M | 768D | 256 tokens | 114MB | ❌ |
| **[Gecko 512](/docs/registry#gecko-110m-en)** | 110M | 768D | 512 tokens | 120MB | ❌ |
| **[EmbeddingGemma 256](/docs/registry#embeddinggemma-300m)** | 300M | 768D | 256 tokens | 179MB | ✅ |
| **[EmbeddingGemma 512](/docs/registry#embeddinggemma-300m)** | 300M | 768D | 512 tokens | 179MB | ✅ |
| **[EmbeddingGemma 1024](/docs/registry#embeddinggemma-300m)** | 300M | 768D | 1024 tokens | 183MB | ✅ |
| **[EmbeddingGemma 2048](/docs/registry#embeddinggemma-300m)** | 300M | 768D | 2048 tokens | 196MB | ✅ |
| **[EmbeddingGemma 2 GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF)** (`.gguf` Q8_0, text; native, through `flutter_edge_ai_llama`) | text tower of google/embeddinggemma-2 | 768D | 1024 tokens | 310MB | ❌ |
| **[all-MiniLM-L6-v2](https://huggingface.co/Xenova/all-MiniLM-L6-v2)** (ONNX; native and web) | 22M | 384D | the graph's | 90MB (`onnx/model.onnx`) | ❌ |
| **[EmbeddingGemma-300M ONNX](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX)** (ONNX; native only) | 300M | 768D | the graph's | 175MB–1.2GB by variant | ❌ |

EmbeddingGemma 2 is one `.litertlm` file with its own tokenizer (no
`tokenizerFrom…()`) and runs on CPU on Android, iOS, macOS, Linux and Windows,
and in the browser on WebGPU since `flutter_edge_ai_litertlm` 1.13.1 (the
browser needs WebGPU: the CPU path of `@litert-lm/core` 0.18.0 cannot load
these bundles).
All three bundles embed text (`flutter_edge_ai_litertlm` 1.13.0, identical text
vectors); the 440m and the 740m also embed JPEG, PNG, GIF and BMP images
(1.13.1; per image about 0.35 s on an Apple-silicon Mac and about 2 s on an
Android flagship, and about 400–500 MB more RAM from the first image); the 740m
also embeds WAV, MP3 and FLAC audio of up to about 40 seconds, natively (1.13.1;
about 0.2–0.3 s per 3-second clip on an Apple-silicon Mac) and on the web from
1.13.2, and any of them together in one vector. Keep chunks at
512 tokens or fewer, and use the 270m when you embed only text; see
[Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2).
The same repositories hold each bundle compiled for one SoC's NPU
(`…_Qualcomm_SM8850.litertlm`, `…_Qualcomm_SM8650.litertlm`,
`…_Qualcomm_QCS8275.litertlm`, 202–563 MB),
which `flutter_edge_ai_litertlm` 1.13.1 runs on Qualcomm Android and Qualcomm
Linux arm64 with `preferredBackend: PreferredBackend.npu`; see
[EmbeddingGemma 2 on a Qualcomm NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-a-qualcomm-npu).
From 1.13.2 the Intel Panther Lake bundles (`…_Intel_PTL.litertlm`, 317–856 MB)
run on Windows x64 the same way; see
[EmbeddingGemma 2 on an Intel NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-an-intel-npu).
From 1.15.0 the Google Tensor G5/G6 bundles (`…_Google_Tensor_G6.litertlm`,
166–658 MB) run on matching Pixels with `google_tensor_npu: true`; see
[EmbeddingGemma 2 on a Google Tensor NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-a-google-tensor-npu).
From 1.17.0 the MediaTek MT6991/MT6993 bundles (`…_MediaTek_MT6991.litertlm`)
are accepted with `mediatek_npu: true` for phones with that SoC, but not run
on such a phone yet; see [LiteRT-LM](/docs/litertlm).
The Gecko and EmbeddingGemma 1 rows are a `.tflite` model plus a tokenizer
file; the ONNX rows are an `.onnx` model plus its tokenizer file, run by
`OnnxEmbeddingBackend` ([ONNX](/docs/onnx)). An ONNX model's input limit is its
graph's static sequence length, or none for a dynamic-shape graph.

**Performance (Android Pixel 8):**

- **Gecko 64**: ~109 ms/doc embedding, 130 ms search (fastest — 2.6× faster than EmbeddingGemma).
- **EmbeddingGemma 256**: ~286 ms/doc embedding, 342 ms search (more accurate — 300M vs 110M params).

### SigLIP 2 text tower (ONNX, manual wiring)

`flutter_edge_ai_embeddings` ships a **SigLIP 2** text profile, for putting text
into the same space as SigLIP's vision tower — image↔text retrieval rather than
document RAG. It is the only embedding profile here that is **not** installed
through `installEmbedder()`.

**Text in, vectors out — flutter_edge_ai does not run the vision tower.** You embed
the image side elsewhere (or offline) and query it with vectors this profile
produces.

Its convention differs from every model above: no leading BOS, a single trailing
`<eos>`, lowercased text, and a fixed 64-token width that lives in the token ids
because the int8 export carries no `attention_mask`. It also ignores the
`TaskType` prefix — the vision tower encodes an image with no prefix, so adding
one moves the text vector off the space the two towers share.

SigLIP 2 reuses the Gemma BPE vocabulary, so a `tokenizer.json` cannot be told
apart by its vocabulary alone, and the embedding tokenizer router in
`flutter_edge_ai_embeddings` (`GemmaEmbeddingTokenizers`) **refuses** such a file rather than reading it with Gemma's convention and
returning a plausible but wrong vector.

To tell whether an export is the one this profile expects, look at two blocks of
its `tokenizer.json` — the same two the refusal keys on:

- `"padding"` declares a fixed width — `"strategy": {"Fixed": …}`, not `"BatchLongest"`
- `"post_processor"` appends `<eos>` and prepends **no** `<bos>`

The refusal needs **both**, so there are three outcomes rather than two. A file
matching both is SigLIP 2's convention. One that prepends `<bos>` is an
EmbeddingGemma-family file and belongs on the profiles above. A file failing
**either** check — no `padding` block, `"BatchLongest"`, or a `post_processor`
that is missing, empty, or does not end in a special token — is not classified
at all: it is read with Gemma's convention and nothing is raised.

So do not read the absence of an error as approval. A SigLIP 2 export that
declares both blocks is caught, but one that dropped either — a re-export, or a
tool that strips them — reaches the Gemma path and produces exactly the silently
wrong vector this section warns about.

Wire it yourself:

```dart
import 'package:flutter_edge_ai_embeddings/embedding_tokenizer.dart'
    show loadSiglipSentencePieceEmbeddingTokenizer;
```

and pass it as the `tokenizerFactory` of your own `TokenEmbeddingPass` (from
`package:flutter_edge_ai/engine.dart`), which your backend's `describe()`
returns in an `EmbeddingPassDescriptor`. That library is native-only. See the
[`flutter_edge_ai_embeddings` README](https://pub.dev/packages/flutter_edge_ai_embeddings)
for the full profile, and [Embeddings & RAG](/docs/embeddings-and-rag) for why
the tokenizer router declines to guess.
