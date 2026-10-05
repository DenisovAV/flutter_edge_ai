---
title: Models
description: Supported models, file formats, capabilities, ModelType reference, and download URLs.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai supports Gemma 4, Gemma3n, FastVLM, Qwen2-VL, SmolVLM2,
LLaVA-OneVision, Gemma 3, FunctionGemma, Qwen3, Qwen 2.5, Phi-4 (incl. Phi-4 Mini
Reasoning), DeepSeek R1, SmolLM, SmolLM3 and more. On desktop (macOS, Windows,
Linux) LiteRT-LM models must be `.litertlm` — there is no MediaPipe engine there;
ONNX models and the OS built-in model also run on desktop.

For a small custom model, [LiteTune](https://litetune.dev) provides the easier
end-to-end path from Hugging Face data/checkpoints through fine-tuning,
`.litertlm` conversion, verification, and bundling. It is alpha software, so
verify the converted model on the devices and backends you plan to ship.

## Model file types

Flutter Edge AI supports different model file formats, grouped into **three types**
based on how chat templates are handled.

### Type 1: SDK-managed templates

- **`.task` files:** MediaPipe-optimized format for mobile (Android/iOS) and web.
- **`.litertlm` files:** LiteRT-LM format for Android, iOS, Desktop, and web
  (early preview). Never handled by MediaPipe — the two formats go to different
  engines.

Chat templates are applied by the runtime rather than by your code — MediaPipe
for `.task`, LiteRT-LM for `.litertlm` — on every platform, iOS included.

### Type 2: Manual template formatting

- **`.bin` files:** standard binary format.
- **`.tflite` files:** LiteRT format (formerly TensorFlow Lite).

Both formats require **manual chat template formatting** in your code.

### Type 3: System OS models (no file)

**Gemini Nano** (Android, via AICore / ML Kit GenAI), **Apple Foundation Models**
(iOS 26+/macOS), **Windows AI Foundry / Phi Silica** (Windows), and **Gemini Nano
via the browser Prompt API** (Web — Gemini Nano in Chrome, Phi-4-mini in Edge) are **built into the
OS/browser** — there is no model file to bundle or download; the platform owns the
weights. Add [`flutter_edge_ai_builtin_ai`](/docs/packages), register
`BuiltInAiEngine()`, and use `ModelFileType.builtIn`. Availability is
device-gated — Gemini Nano needs Pixel 9+/Galaxy S25+, Apple FM needs Apple
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
`ModelFileType.builtIn` for OS-provided models.

</Info>

### Format by platform

| Format | Android | iOS | Web | Desktop | Use Case |
|---|:---:|:---:|:---:|:---:|---|
| `.task` | ✅ | ✅ | ✅ | ❌ | Older models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4) |
| `.litertlm` | ✅ | ✅ ¹ | ⚠️ ² | ✅ | Newer models (Gemma 4, Qwen3, FastVLM + desktop for all) |
| `-web.task` | ❌ | ❌ | ✅ | ❌ | Web-specific MediaPipe builds (Gemma 4 in the current catalog) |
| `.bin` | ✅ | ✅ | ✅ | ❌ | Manual chat template formatting required |
| `.tflite` | ✅ | ✅ | ✅ | ✅ | Embeddings only (EmbeddingGemma, Gecko) |
| `onnx` | ✅ | ✅ | ✅ | ✅ | ONNX models — an ORT-GenAI model directory on native, a Hugging Face repo via Transformers.js on Web — [ONNX](/docs/onnx) |
| `builtIn` (no file) | ✅ | ✅ | ✅ | ⚠️ ³ | OS/browser model — [Built-in AI](/docs/builtin-ai) |

¹ iOS `.litertlm` runs on the FFI engine — vision and audio supported on physical
devices. The Simulator stays CPU-only because Metal sim has a 256 MB
single-allocation cap.

² Web `.litertlm` is an **early preview** via `@litert-lm/core` — text plus function calling. No
vision, audio, the Gemma 4 thinking channel, or LoRA; Qwen3 reasoning tags are
still parsed when the model emits them. See the feature matrix in
[Troubleshooting](/docs/troubleshooting). For full multimodal on web, use a
MediaPipe `.task` build.

³ On desktop the OS model exists on **macOS** (Apple Foundation Models) and
**Windows** (AI Foundry; Windows 11 25H2+ on Copilot+-class hardware, packaged
app) — not on Linux. Every platform still gates it at
runtime: probe with `BuiltInAi.availability()`.

## Model capabilities

| Model Family | Best For | Function Calling | Thinking Mode | Vision | Languages | Size |
|---|---|:---:|:---:|:---:|---|---|
| **Gemma 4 E2B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ ¹ | ✅ | Multilingual | 2.4GB |
| **Gemma 4 E4B** | Next-gen multimodal chat — text, image, audio | ✅ | ✅ ¹ | ✅ | Multilingual | 4.3GB |
| **Gemma3n** | On-device multimodal chat and image analysis | ⚠️ ² | ❌ | ✅ | Multilingual | 3-6GB |
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

¹ Gemma 4 **Thinking Mode** needs the native `extraContext` channel: Android, iOS
and Desktop only. The measured Web `.litertlm` test receives no Gemma 4
`ThinkingResponse`; MediaPipe Web cannot enable it and ONNX Web ignores it.
Qwen3 is different: core parses its emitted `<think>` tags on every platform,
including Web.

² Gemma3n function calling: on the downloadable E4B `.litertlm` build; not on
E2B or the MediaPipe `.task` builds.

‡ **Reasons, but emits no `ThinkingResponse`.** These models run as
`ModelType.general`, which has no reasoning parser — their thinking blocks
arrive inside the answer as ordinary text and are not stripped. See
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
| **Gemma 3 / Gemma3n** | `ModelType.gemmaIt` | Gemma 3 1B, Gemma 3 270M, Gemma3n E2B/E4B |
| **DeepSeek** | `ModelType.deepSeek` | DeepSeek R1 |
| **Qwen 2.5** | `ModelType.qwen` | Qwen 2.5 1.5B, Qwen 2.5 0.5B |
| **Qwen 3** | `ModelType.qwen3` | Qwen3 0.6B |
| **Phi-4** | `ModelType.phi` | Phi-4 Mini (parses Phi's own tool-call markers) |
| **FunctionGemma** | `ModelType.functionGemma` | FunctionGemma 270M IT |
| **General** | `ModelType.general` | FastVLM 0.5B, SmolLM 135M, LFM2.5 230M, SmolLM3 3B, Phi-4 Mini Reasoning, Qwen2-VL 2B, SmolVLM2 500M, LLaVA-OneVision 0.5B |

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

| Model | Size | Desktop | Mobile | Web |
|---|---|:---:|:---:|:---:|
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

## Installation sources

```dart
// Network — .litertlm is the cross-platform default (Android/iOS/Desktop).
// For mobile-only or web-only apps you can substitute a .task URL — and drop
// the fileType, which defaults to ModelFileType.task.
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
  modelType: ModelType.general,     // fallback — the manifest overrides it
  fileType: ModelFileType.litertlm, // selects the litertlm resolver
)
  .fromHuggingFace('litert-community/Qwen3-4B-Thinking-2507')
  .install();

final model = await FlutterEdgeAi.getActiveModel(defaults: install.runtime);
// `minOutputTokens` is a FLOOR, not a cap — leave `maxOutputTokens` unset (or
// keep it >= `install.runtime?.minOutputTokens`). Passing the floor as the cap
// would truncate a reasoning model mid-thought.
final session = await model.createSession(
  enableThinking: install.runtime?.isThinking ?? false,
);
```

`.onnx` repos install the whole ORT-GenAI **directory** — the ONNX resolver (carried by `OnnxEngine`) lists the repo, picks a CPU execution-provider folder (the bundled runtime is CPU-only; pin one with `OnnxHuggingFaceResolver(variant: …)`) and downloads every file in it; see [ONNX](/docs/onnx). `.builtIn` repos surface that OS models have no Hugging Face file.

**Explicit file** — pass `file`, and `fromHuggingFace(repo, file:)` resolves `…/resolve/<revision>/<file>` and installs it directly, for any `fileType` (no manifest needed; the HF token is applied to `huggingface.co` automatically):

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
  .fromHuggingFace('litert-community/Gemma3-1B-IT', file: 'model.litertlm', token: 'optional')
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
  modelType: r.modelType ?? ModelType.general,
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
end-to-end today; kokoro / supertonic TTS voices are follow-ons. Native only (no
Web). See [Speech](/docs/speech) for usage.
A `VoiceSession` also chains STT → LLM → TTS into a push-to-talk voice loop —
see [Speech](/docs/speech).

**Speech-to-text**

| Model | Input | Size | Status | Auth |
|---|---|---|---|---|
| **[moonshine-tiny](https://huggingface.co/litert-community/moonshine-tiny)** | raw 16 kHz PCM | ~104 MB | ✅ end-to-end | ❌ |
| **[Whisper](https://huggingface.co/litert-community/whisper-tiny)** (tiny / base) | log-mel | — | ✅ end-to-end | ❌ |
| **[Parakeet](https://huggingface.co/litert-community/parakeet-ctc-0.6b)** (CTC 0.6B) | log-mel | — | ✅ end-to-end | ❌ |

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

| Model | Output | Size | Status | Auth |
|---|---|---|---|---|
| **[Matcha](https://huggingface.co/litert-community/Matcha-TTS)** | 16-bit PCM @ 22050 Hz | ~90 MB | ✅ end-to-end | ❌ |
| **[Qwen3-TTS](https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base)** (10 langs + `auto`) | 16-bit PCM | ~1.9 GB | ✅ end-to-end | ❌ |
| **[Inflect-Nano-v2](https://huggingface.co/sasha-denisov/inflect-nano-v2-litert)** (fast) | 16-bit PCM @ 24 kHz | ~36 MB | ✅ end-to-end | ❌ |

## Text embedding models

The LiteRT embedding models below generate **768-dimensional vectors**. The
numbers in names (64/256/512/1024/2048) indicate **maximum input sequence length
in tokens**, not embedding dimension. (With the ONNX backend the dimension is
model-dependent — e.g. all-MiniLM-L6-v2 is 384-dim.) See
[Embeddings & RAG](/docs/embeddings-and-rag) for usage.

| Model | Parameters | Dimensions | Max Seq Length | Size | Auth Required |
|---|---|---|---|---|---|
| **[Gecko 64](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 64 tokens | 110MB | ❌ |
| **[Gecko 256](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 256 tokens | 114MB | ❌ |
| **[Gecko 512](https://huggingface.co/litert-community/Gecko-110m-en)** | 110M | 768D | 512 tokens | 116MB | ❌ |
| **[EmbeddingGemma 256](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 256 tokens | 179MB | ✅ |
| **[EmbeddingGemma 512](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 512 tokens | 179MB | ✅ |
| **[EmbeddingGemma 1024](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 1024 tokens | 183MB | ✅ |
| **[EmbeddingGemma 2048](https://huggingface.co/litert-community/embeddinggemma-300m)** | 300M | 768D | 2048 tokens | 196MB | ✅ |

**Performance (Android Pixel 8):**

- **Gecko 64**: ~109 ms/doc embedding, 130 ms search (fastest — 2.6× faster than EmbeddingGemma).
- **EmbeddingGemma 256**: ~286 ms/doc embedding, 342 ms search (more accurate — 300M vs 110M params).

### SigLIP 2 text tower (ONNX, manual wiring)

`flutter_edge_ai_embeddings` ships a **SigLIP 2** text profile, for putting text
into the same space as SigLIP's vision tower — image↔text retrieval rather than
document RAG. It is the only embedding profile here that is **not** installed
through `installEmbedder()`.

**Text in, vectors out — the plugin does not run the vision tower.** You embed
the image side elsewhere (or offline) and query it with vectors this profile
produces.

Its convention differs from every model above: no leading BOS, a single trailing
`<eos>`, lowercased text, and a fixed 64-token width that lives in the token ids
because the int8 export carries no `attention_mask`. It also ignores the
`TaskType` prefix — the vision tower encodes an image with no prefix, so adding
one moves the text vector off the space the two towers share.

SigLIP 2 reuses the Gemma BPE vocabulary, so a `tokenizer.json` cannot be told
apart by its vocabulary alone, and the [ONNX tokenizer loader](/docs/onnx)
**refuses** such a file rather than reading it with Gemma's convention and
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

and pass that as the tokenizer factory of the `ForwardPassDescriptor` you give
to `CommonEmbeddingModel.create`. That library is native-only. See the
[`flutter_edge_ai_embeddings` README](https://pub.dev/packages/flutter_edge_ai_embeddings)
for the full profile, and [ONNX Runtime](/docs/onnx) for why the factory
declines to guess.
