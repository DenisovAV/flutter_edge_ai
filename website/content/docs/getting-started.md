---
title: Getting Started
description: On-device AI for Flutter on Android, iOS, Web, macOS, Windows and Linux — open models or the one the OS ships, no server.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

**flutter_edge_ai** is on-device AI for Flutter on Android, iOS, Web, macOS,
Windows and Linux. Run any open model a registered engine runs — see
[Models](/docs/models) — or the model the operating system already ships, with
text, vision, audio, function calling, embeddings, RAG and speech. No server,
no cloud.

The core is small: it installs models and dispatches to engines, and you add
only the engines, stores and features your app uses — see
[Packages](/docs/packages).

## Features

- **Local Execution:** Run any model a registered engine runs (see [Models](/docs/models)) directly on user devices for enhanced privacy and offline functionality.
- **Platform Support:** Compatible with iOS, Android, Web, macOS, Windows, and Linux.
- **Desktop Support:** Native desktop apps with GPU acceleration via LiteRT-LM, called directly from Dart through `dart:ffi` — no JVM/JRE bundling. See [Desktop Support](/docs/desktop).
- **Built-in / System AI:** Use the OS's own on-device model, no download — Gemini Nano (Android + Chrome), Apple Foundation Models (iOS/macOS) and Windows AI Foundry. See [Built-in AI](/docs/builtin-ai).
- **Pluggable Engines:** Opt-in engine packages — LiteRT-LM, MediaPipe, ONNX Runtime, llama.cpp (GGUF), built-in OS AI — registered via `FlutterEdgeAi.initialize(...)`. See [Packages](/docs/packages).
- **Multimodal Support:** Text + image input with vision models (the Vision column on [Models](/docs/models)), including Gemini Nano on Android through built-in AI. See [Multimodal](/docs/multimodal).
- **Audio Input:** Record and send audio messages with Gemma 4 and Gemma3n models (Android, iOS device, Desktop).
- **Function Calling:** Let models call external functions and integrate with other services. See [Function Calling](/docs/function-calling).
- **Agent Skills:** Give the model a catalog of `SKILL.md` skills it picks and runs itself — text, JS, native intents, or MCP tools. See [Agent Skills](/docs/agent).
- **Speech & Voice (STT + TTS + voice loop):** Transcribe audio, synthesize speech, and run a full on-device speech-to-speech voice loop (`VoiceSession`) via `flutter_edge_ai_speech` — STT (moonshine/Whisper/Parakeet) + TTS (Matcha/Qwen3/Inflect) today. See [Speech](/docs/speech).
- **Thinking Mode:** View the reasoning process of thinking models — see [Thinking Mode](/docs/thinking-mode).
- **Stop Generation:** Cancel text generation mid-process on Android, iOS, Web, and Desktop.
- **Backend Switching:** Choose CPU or GPU where supported, plus NPU for
  `.litertlm` on Qualcomm Android devices, Qualcomm Linux arm64 boards, Google
  Tensor G5/G6 Pixels and MediaTek Android devices (opt-in, see
  [LiteRT-LM](/docs/litertlm)) and on Intel LunarLake/PantherLake Windows PCs.
- **LoRA (MediaPipe `.task`):** Efficient fine-tuning and integration of LoRA (Low-Rank Adaptation) weights.
- **Enhanced Downloads:** Smart retry logic with exponential backoff and automatic restart of interrupted downloads.
- **Android Foreground Service:** opt in with `foreground: true` for large downloads to bypass the 9-minute timeout.
- **Embeddings (text, images, audio) & RAG:** Generate vectors with pluggable embedding runtimes,
  then use independent `flutter_edge_ai_rag` indexes with Qdrant or SQLite
  storage. See [Embeddings & RAG](/docs/embeddings-and-rag).
- **Web Persistent Caching:** Models persist across browser restarts using the Cache API (Web only).

## What's new in 2.5

- **Several open models** (`flutter_edge_ai` 2.5.0, `flutter_edge_ai_litertlm`
  1.16.0): `FlutterEdgeAi.openModel(spec)` builds a caller-owned model on every
  call, so one file can be open on CPU and GPU, or two files at once. See
  [Desktop](/docs/desktop#several-models-at-once).
- **Deciders from a language model** (experimental, `flutter_edge_ai` 2.5.0 with
  `flutter_edge_ai_litertlm` 1.16.0, native, `PreferredBackend.cpu` only):
  `InferenceModel.createDecider` scores the options on a `.litertlm` trained on
  the decision with LiteTune. See
  [Decisions](/docs/decisions#deciders-from-a-language-model).
- **MediaTek NPU** (`flutter_edge_ai_litertlm` 1.17.0): `PreferredBackend.npu`
  on MediaTek Android devices, opt-in with `mediatek_npu: true`. See
  [LiteRT-LM](/docs/litertlm).
- **Intel's Gemma 4 12B on the Windows NPU** (`flutter_edge_ai_litertlm`
  1.17.0): OpenVINO 2026.4.1, and the next NPU load deletes the `%TEMP%` weight
  banks a killed 1.17.0 app left (older ones after a restart). See
  [Desktop](/docs/desktop).
- **GGUF embeddings** (`flutter_edge_ai_llama` 0.0.3): `LlamaEmbeddingBackend`
  runs EmbeddingGemma 2 `.gguf` text embeddings natively. See
  [llama.cpp](/docs/llama).

## What's new in 2.4

- **Decider** (experimental, `flutter_edge_ai` 2.4.0):
  `EmbeddingModel.createDecider` picks one of N options for an input — an
  intent, an action, a route, a tool — or says "none of these". See
  [Decisions](/docs/decisions).
- **Order of images, audio and text** (`flutter_edge_ai_litertlm` 1.14.0):
  Gemma 4 gets its audio after the text, as its model card asks, and
  `getActiveModel(multimodalOrder:)` sets another order. See
  [Multimodal](/docs/multimodal#order-of-images-audio-and-text).
- **Structured tool calls** (`flutter_edge_ai` 2.4.0): `Message.toolCall(calls:)`
  keeps the calls with their ids, `Message.toolResponse(toolCallId:)` names the
  call a result answers, and a sentence Gemma 4 writes before a call no longer
  streams the call's JSON as text. See
  [Function Calling](/docs/function-calling#tool-calls-in-a-saved-history).
- **Backends from the model file** (`flutter_edge_ai_litertlm` 1.14.0): the
  engine reads a `.litertlm` before it loads it — a bundle compiled for an NPU
  runs there, each encoder runs where its section says (`activeVisionBackend`,
  `activeAudioBackend`), and a file that cannot run as asked is refused with
  the reason. `readLiteRtLmBundleInfo(path)` shows what it reads, and
  `LiteRtLmEngine(backendFallback: false)` makes one attempt that fails with
  LiteRT-LM's own reason. See [LiteRT-LM](/docs/litertlm#where-a-model-runs).
- **requireWeightCache** (`flutter_edge_ai_litertlm` 1.14.0):
  `LiteRtEmbeddingBackend(requireWeightCache: true)` fails an EmbeddingGemma 2
  load that wrote no weight cache instead of running it slower and larger. See
  [Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2).
- **Agent skills 0.3.0** (`flutter_edge_ai_agent`): an empty answer right after
  `loadSkill` is asked again (`EmptyAnswerRetryEvent`, an event an exhaustive
  `switch` must now handle), intents the app adds get `validators:`, and
  SKILL.md parsing is fixed. See
  [Agent Skills](/docs/agent#when-the-model-answers-nothing).
- **Genkit 0.10.0** (`genkit_flutter_edge_ai`): tool `ref`s travel as call ids
  both ways; it requires `flutter_edge_ai` 2.4.0. See
  [Genkit](/docs/genkit#tool-calls).
- **2.4.1 / `flutter_edge_ai_litertlm` 1.15.0:** Google Tensor G5/G6 NPUs on
  Pixels, opt-in with `google_tensor_npu: true`; a stopped turn is rewound in
  place, so the chat keeps earlier images and audio; the Intel NPU on Windows
  loads its model again; a raw Gemma 4 tool call runs with typed arguments or
  not at all. See [LiteRT-LM](/docs/litertlm).
- **Agent skills 0.4.0** (`flutter_edge_ai_agent`, breaking):
  `schedule_notification` runs only with `NativeIntentExecutor(notifications:)`.
  See [Migration](/docs/migration).
- **llama.cpp engine** (`flutter_edge_ai_llama` 0.0.1): GGUF models, on
  pub.dev. See [llama.cpp](/docs/llama).

Upgrading from 2.3: see [Migration](/docs/migration).

## What's new in 2.3

- **2.3.2:** the active model keeps its LoRA across an app restart, and
  `ModelFileType.gguf` selects the optional [llama.cpp engine](/docs/llama),
  `flutter_edge_ai_llama`, on pub.dev since 0.0.1.
- **EmbeddingGemma 2 on an Intel NPU** (`flutter_edge_ai_litertlm` 1.13.2): the
  Panther Lake bundles run on Windows x64 with
  `preferredBackend: PreferredBackend.npu`. See
  [Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2-on-an-intel-npu).
- **Audio turns** (`flutter_edge_ai_speech` 0.5.7, `flutter_edge_ai_agent`
  0.2.10): `VoiceSession.runAudioTurn` gives the model the recording itself,
  with no speech-to-text, and `AgentSession.ask(audioBytes:)` asks an agent
  with a recording. See
  [Speech](/docs/speech#audio-turns-the-model-hears-the-recording) and
  [Agent Skills](/docs/agent#asking-with-a-recording).
- **`flutter_edge_ai_diagnostics` 0.3.0:** macOS support and
  `anonymousPeakBytes`, the lifetime footprint peak on iOS and macOS. See
  [Diagnostics](/docs/diagnostics).
- **EmbeddingGemma 2** (`flutter_edge_ai_litertlm` 1.13.0): text embeddings
  from one `.litertlm` bundle with its own tokenizer, on Android, iOS, macOS,
  Linux and Windows; up to 1024 tokens per input. See
  [Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2).
- **EmbeddingGemma 2 audio and combined inputs** (`flutter_edge_ai_litertlm`
  1.13.1, `flutter_edge_ai` 2.3.1): the 740m bundle embeds WAV, MP3 and FLAC
  clips on native platforms, and `EmbeddingInput(text:, images:, audio:)` puts
  several parts in one vector; an over-long input reports its exact token
  count. See
  [Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2-audio-and-combined-inputs).
- **EmbeddingGemma 2 on the Web** (`flutter_edge_ai_litertlm` 1.13.1): text
  and images in the browser through `@litert-lm/core`, on WebGPU (the
  browser needs it), and from 1.13.2 audio and combined inputs; add `window.EmbeddingEngine = m.EmbeddingEngine;` to
  `web/index.html`. See
  [Installation → Web](/docs/installation#web).
- **EmbeddingGemma 2 images** (`flutter_edge_ai_litertlm` 1.13.1): the 440m
  bundle embeds JPEG, PNG, GIF and BMP photos next to text, for text-to-image
  and image-to-image search in a RAG image index. See
  [Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2-images).
- **A new embedding API** (breaking): `embed(EmbeddingInput.text(t), taskType: …)`
  and `embedAll` replace `generateEmbedding(s)`, `dimension` replaces
  `getDimension()`, `TaskType` has nine values, errors are typed
  `EmbeddingException`s delivered as failed futures, and an over-long input
  throws `EmbeddingInputTooLongException` instead of being truncated.
- **RAG 1.1** (breaking): `RagIndex.add`/`search` take an `EmbeddingInput`,
  `open()` takes the embedder and `openVectors()` a profile, and a location
  binds one document modality. Needs `flutter_edge_ai_sqlite` /
  `flutter_edge_ai_qdrant` 2.1.0.
- **Engine packages import `package:flutter_edge_ai/engine.dart`**; core's
  internals moved under `lib/src`, and the deprecated 1.x/2.0 members are gone.
  Upgrade every flutter_edge_ai package together — see
  [Migration](/docs/migration).

## What's new in 2.2

- **Sampling defaults come from the model** (breaking): `temperature`, `topK`,
  `topP` and `randomSeed` are nullable, and an unset one comes from the
  sampler the model file ships, else its family's published defaults, instead
  of greedy `topK: 1`. Pass `topK: 1` to keep greedy decoding. See
  [Migration](/docs/migration).
- **2.2.1 — installs and model lifecycle:** a `fromFile` model is active again
  after a restart, and core never deletes a file you installed with
  `fromFile`. Installing a name again from another source replaces it (see
  [Installing again](#installing-again)). With nothing installed,
  `getActiveModel` and `getActiveEmbedder` throw `NoActiveModelError`, a
  `StateError`. `InferenceModel.isClosed` is new, and web reuses the loaded
  model as the other platforms do.

## What's new in 2.1

- **`enableThinking` replaces `isThinking`** on `createChat`, `createSession`
  and `openSession` (breaking); `ModelRuntimeDefaults.isThinking` is
  `thinkingDeclared`. New `ModelType.qwen35`. See [Migration](/docs/migration).
- **Qualcomm NPU is opt-in** (`flutter_edge_ai_litertlm` 1.10.0): set
  `qualcomm_npu: true` under `hooks: user_defines: flutter_edge_ai_litertlm:`,
  and the build hook fetches Qualcomm's QNN runtime. The same flag now covers
  **Qualcomm Linux arm64** boards. See [LiteRT-LM](/docs/litertlm).
- **LiteRT-LM v0.18.0** (`native-v0.18.0-d`). Apple's Metal accelerator ships as
  `LiteRtLmMetalAccelerator`, so an app can use `flutter_litert` beside it, and
  native tool calls work on Linux.

## What's new in 2.0

- **RAG is an independent module.** `flutter_edge_ai_rag` owns `RagIndex`,
  embedding profiles, filters, and provider selection; SQLite and Qdrant are
  replaceable storage packages. It can borrow core's active embedder, use a
  custom embedder, or run vector-only without `FlutterEdgeAi.initialize()`.
- **Persistent indexes are profile-safe.** A location is bound to a stable
  embedding-pipeline identity, and app-owned indexes have explicit disposal.
  See [Embeddings & RAG](/docs/embeddings-and-rag) and
  [Migration](/docs/migration).
- **The `flutter_gemma` aliases are gone.** The old Dart names no longer
  compile; `dart fix --apply` still renames them.
- **`ModelFileManager.setActiveModel` is removed** — use
  `ensureModelReadyFromSpec`.

## Historical release notes (1.x): Flutter Gemma became Flutter Edge AI

- **flutter_gemma is now Flutter Edge AI.** Every package has a new name — `flutter_edge_ai`, `flutter_edge_ai_litertlm`, … Installed models, vector stores and platform setup carry over, and `dart fix --apply` renames the old Dart names. See [Migration](/docs/migration).

Core through 1.11.4 (`flutter_gemma_litertlm` through 1.8.6) shipped under the `flutter_gemma*` names; the new names continue the same numbering (the table is in [Migration](/docs/migration)).

## What's new in 1.9

- **`embeddingTokenizers:`** — embedding backends no longer bring a tokenizer. Add `flutter_edge_ai_embeddings` and pass `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` beside `embeddingBackends:`, or the first embedding throws a `StateError` (since 2.3, `getActiveEmbedder()` throws an `EmbeddingLoadException` with that cause). Breaking for every app that computes embeddings. See [Migration](/docs/migration).
- **Engines no longer pull the tokenizer package** — `flutter_edge_ai_litertlm` and `flutter_edge_ai_onnx` no longer depend on `flutter_edge_ai_embeddings`. Speech intentionally still depends on LiteRT-LM to share its native bundle. See [Packages](/docs/packages).
- **Web embeddings run** — the LiteRT.js bundle was rebuilt on `@litertjs/core` 2.5.3 and all four JS files now ship together in `flutter_edge_ai_litertlm/web/`. See [Embeddings & RAG](/docs/embeddings-and-rag).
- **SQLite RAG on web drains for real** — `flutter_gemma_rag_sqlite` 1.4.0 requires sqlite3 3.6.0 and Flutter 3.47; a Flutter 3.44 app stays on 1.3.2. See [Embeddings & RAG](/docs/embeddings-and-rag).

## What's new in 1.8

- **Package Skills** — flutter_edge_ai ships agent skills for coding assistants; `dart run skills@ get --all` installs them. See [Package Skills](/docs/package-skills).
- **Whisper output language** — `getActiveStt(language:)` sets a default, `transcribe(…, language:)` overrides one call. Breaking for custom `SpeechRecognizer` implementations. See [Speech](/docs/speech#output-language-whisper).
- **Vector-store `flush()`** was added to persist an index. In 2.0 the current
  call is `RagIndex.flush()`; see [Embeddings & RAG](/docs/embeddings-and-rag).

## What's new in 1.7

- **Install from Hugging Face** — `installModel(…).fromHuggingFace(repo)` reads the repo's manifest and installs the right variant for the device; `resolveHuggingFace` inspects it first. See [Models → Hugging Face](/docs/models#hugging-face).

## What's new in 1.6

- **`flutter_edge_ai_onnx`** — new opt-in ONNX Runtime engine: text generation via ORT-GenAI (`OnnxEngine`) + embeddings via plain ONNX Runtime (`OnnxEmbeddingBackend`), both `dart:ffi`. Device-verified on macOS, Linux, Windows, Android, and iOS (arm64) — plus **Web**, via Transformers.js (generation) and onnxruntime-web (embeddings). See [Packages](/docs/packages#onnx-runtime-engine).
- **`flutter_edge_ai_builtin_ai` on Web** — Gemini Nano through Chrome's Prompt API, next to Gemini Nano on Android and Apple Foundation Models on iOS/macOS. See [Built-in AI](/docs/builtin-ai).
- **BREAKING (`flutter_gemma_embeddings` 2.0.0):** the embedder is now runtime-agnostic — `LiteRtEmbeddingBackend` moved to `flutter_gemma_litertlm` (1.5.0). See [Migration](/docs/migration).

## What's new in 1.5

- **genai_primitives support** — drive an on-device chat with the Flutter team's standard `ChatMessage` types via `package:flutter_edge_ai/genai.dart` (`sendMessage`/`generateContent` + streams, covering text, vision, audio, thinking, and tool calls). See [genai_primitives](/docs/genai).
- **Historical RAG facade:** 1.5 put RAG under `FlutterEdgeAi.rag`; 2.0 removed
  that facade in favor of independently owned `FlutterEdgeAiRag` indexes. The
  core facade still owns model introspection, storage helpers, and per-modality
  uninstallers.

## What's new in 1.4

- **`flutter_edge_ai_speech`** — new opt-in on-device speech package: STT (moonshine) + TTS (Matcha) + a full STT → LLM → TTS voice loop (`VoiceSession`). See [Speech](/docs/speech).

## What's new in 1.3

- **`ModelFileType.builtIn`** for OS system models (Gemini Nano / Apple Foundation Models), plus download-reliability fixes. See [Built-in AI](/docs/builtin-ai).

## What's new in 1.2

- **`flutter_edge_ai_agent`** — new opt-in agent-skills package (the `skillExecutors:` registration seam), plus the Android Mali GPU fix. See [Agent Skills](/docs/agent).

## What's new in 1.1

- **Declared-column RAG filters** were introduced through core initialization.
  In 2.0 the schema lives in `VectorStoreSpec`; see
  [Embeddings & RAG](/docs/embeddings-and-rag).

## What's new in 1.0

- **Modular package split** — the monolith is now a small **core** (`flutter_edge_ai`) plus **opt-in** packages, so your app ships only the native weight it uses: `flutter_edge_ai_litertlm` (.litertlm), `flutter_edge_ai_mediapipe` (.task/.bin), `flutter_edge_ai_embeddings`, `flutter_edge_ai_qdrant`, `flutter_edge_ai_sqlite`. See [Packages](/docs/packages).
- **New `FlutterEdgeAi.initialize(...)` registration** originally included AI
  runtimes and the vector store. In 2.0 it registers AI runtimes only.
- Model/session/chat/embedding APIs stayed compatible in 1.0; RAG later moved
  to `flutter_edge_ai_rag` in 2.0. See [Migration](/docs/migration).
- **Two on-device vector stores** — `flutter_edge_ai_qdrant` (qdrant-edge, fastest on native) and `flutter_edge_ai_sqlite` (portable across all six platforms, including Web). Since rag_sqlite 1.1.0 the SQLite store runs exact in-SQLite KNN via the `sqlite-vec`/`vec0` extension, replacing its Dart brute-force + HNSW search.

See the [CHANGELOG](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai/CHANGELOG.md) for the full release history.

## Quick Start

<Warning>

Complete the [platform setup](/docs/installation) before running this code.

</Warning>

### 1. Install a Model (One Time)

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

// Once, in main(): core has no engine of its own. Gemma 3 1B is gated, so
// pass a token — never hard-code it.
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isEmpty
      ? null
      : const String.fromEnvironment('HUGGINGFACE_TOKEN'),
);

// Install model. The URL below uses the .litertlm variant, which runs on
// Android, iOS and Desktop (Windows/macOS/Linux). Web uses web builds — see
// the note below.
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
).fromNetwork(
  'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
).withProgress((progress) {
  print('Downloading: $progress%');
}).install();
```

<Info>

**MediaPipe alternative:** Google's LLM Inference API is maintenance-only, so
new apps should prefer `.litertlm`. On mobile you can install the `.task` build of the
same model instead — drop `fileType` (it defaults to `ModelFileType.task`) and
register `MediaPipeEngine()` from `flutter_edge_ai_mediapipe`. On iOS, run the
`.task` build on `PreferredBackend.cpu`: on the GPU it is killed for memory
while loading ([details](/docs/mediapipe#backends)). On Web, use the
`-web.task` build (`gemma3-1b-it-int4-web.task`) with `MediaPipeEngine()`.
Desktop targets need the `.litertlm` build — `.task` and `.bin` are
MediaPipe-only.

</Info>

### 2. Create and Use a Model (Multiple Times)

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

<Warning>

`Message.isUser` defaults to `false`. Always pass `isUser: true` for user
messages, or the model returns an empty response. Always `close()` sessions and
models when you're done with them.

</Warning>

### Sampling

Leave `temperature`, `topK` and `topP` unset and each session gets the sampler
the model file ships, else the defaults its family publishes
(`SamplingParams.forModelType`; Gemma: `temperature: 1.0, topK: 64,
topP: 0.95`), else `temperature: 0.8, topK: 40, topP: 0.95`. A value you pass
wins, field by field. Pass `topK: 1` or `temperature: 0` for greedy decoding.

- **Where the model file's sampler is read:** a `.litertlm` bundle on native
  platforms, and an ONNX model's `genai_config.json`. Web `.litertlm` and
  MediaPipe `.task` use the family defaults, and MediaPipe holds an unset
  top-k to 40, its own default.
- **A temperature or top-p without a top-k** asks for sampling, so a greedy
  family (Phi, Hammer) or model config contributes no `topK: 1`: the session
  gets the next layer's top-k instead. Built-in AI is the exception: it keeps
  `topK: 1`, and says so once.
- **`.litertlm` keeps the sampler of an engine's first generation** for every
  later conversation ([LiteRT-LM #2080](https://github.com/google-ai-edge/LiteRT-LM/issues/2080)).
  To change it, close the model and load it again; a warning says so once when
  you set either sampler. A new chat on the same model still gets a new answer
  to the same prompt, and a freshly loaded model repeats its first answer for
  the same seed.
- **What an engine ignores** is printed once: built-in AI takes no seed and
  applies top-p only on Windows, MediaPipe web takes no top-p, ONNX web
  applies neither the seed nor top-p, and the NPU decodes greedily whatever
  you set. `randomSeed` is 1 when unset, unless a `.litertlm` bundle ships
  one; ONNX leaves it to the model config. Built-in AI sends
  `temperature: 0.8, topK: 1` for unset values, as it always has.

### System Instructions

Control model behavior with a system-level instruction:

```dart
final chat = await model.createChat(
  systemInstruction: 'You are a concise assistant. Always respond in bullet points.',
);
```

**Platform support:**

- **`.litertlm` on every platform, native and web**: passed as a real system turn.
- **ONNX (native and web)**: passed as a `system` message.
- **Built-in AI**: handed to the OS model as its instructions.
- **MediaPipe `.task` (Android, iOS, web)**: prepended to the first user message as a fallback.

### Changing a runtime parameter reloads the model

`getActiveModel` caches one model per active spec, but it compares every runtime
parameter — `maxTokens`, `preferredBackend`, `supportImage`,
`maxConcurrentSessions` and the rest. A call that differs in any of them
**closes the cached model and builds a new one**, logging which parameter forced
the rebuild:

```dart
final quick = await FlutterEdgeAi.getActiveModel(maxTokens: 512);
final deep  = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
// deep is a NEW model, and `quick` has been closed — using it now throws a
// StateError ('Model is closed…'). Drop the old handle.
```

So don't hold a handle across a parameter change, and don't vary the arguments
on a hot path: each change costs a full weight reload. To serve several
conversations from one loaded model, keep the arguments identical and open
several sessions instead (below). Closing it yourself first is equivalent:

```dart
await quick.close();
final deep = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
```

An app that needs several models loaded at once, such as one per backend,
opens them with `FlutterEdgeAi.openModel` instead: each call builds a model
the app owns and closes, which a `getActiveModel` rebuild never touches. See
[Desktop → Several models at once](/docs/desktop#several-models-at-once).

To serve several dialogues from one loaded model, do not reload it — open
several sessions instead (next section).

Web follows the same rule since `flutter_edge_ai` 2.2.1. Before that, every
`getActiveModel` call on web closed the cached model and built a new one,
identical arguments or not.

A model is closed from the moment its `close()` starts: `model.isClosed` is
true. Since 2.2.1 a `getActiveModel` call made while that close is still
running waits for it to finish (at most 60 s, then `TimeoutException`) and
builds a new model; it never returns the closing one, and two models are never
loaded at once.

<Info>

On native `.litertlm` (except the NPU) a `maxTokens` below 1024 is clamped up to
1024, so the 512 above would not have been honored in any case. See
[Troubleshooting](/docs/troubleshooting).

</Info>

### Concurrent Sessions (`openSession`)

A single loaded model can serve several **independent** dialogues at once.
`openSession()` returns a session with its own conversation history, detached
from the legacy `model.session` singleton; `openChat()` is the same for the
higher-level chat API. ONNX models and MediaPipe on web do not support it:
`openSession()` throws `UnsupportedError` there.

The model weights (the big, expensive part — hundreds of MB to several GB) are
loaded **once** and shared across every session; each session only adds its own
lightweight conversation context.

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

model.sessions;               // all live sessions (legacy + open)
await chatA.session.close();  // closing one leaves the others usable
```

<Warning>

**Concurrent contexts, serialized inference.** The sessions are logically
independent, but **only one session generates at a time** — calling
`getResponse()` or `generateChatResponse()` on a second session while another is still running blocks
until the first finishes. Generation is *not* parallel. This is intentional:
parallel on-device inference would contend for the accelerator and risk OOM.

</Warning>

**Memory:** each open session holds its own context (~100–500 MB depending on
model + `maxTokens`). On phones with large models (Gemma 4 E2B+), several
concurrent sessions can OOM. Cap the count with `maxConcurrentSessions:` on
`getActiveModel(...)` — `openSession()` throws `StateError` past the cap.

If you only ever have one conversation at a time, stick with the simpler
`createSession()` / `createChat()` singleton API — you don't need this.

## Managing Installed Models

### Installing again

Installing a file name again from the source it came from does nothing. From
another source — another URL (query and token aside), or `fromFile` with
another path — it replaces the install, and core deletes its own earlier copy
once the new one is active. Core never deletes or overwrites a file you
installed with `fromFile`: it is used in place, it is active again after a
restart, and a download that would land on it throws `ModelStorageException`.

### Uninstalling

For the **active** embedder / STT / TTS model, one call deletes every file it
owns (e.g. an embedder's model *and* tokenizer) and clears its persisted
identity so it isn't auto-restored on the next launch. Files you installed with
`fromFile` are yours: they are uninstalled but stay where they are.

```dart
await FlutterEdgeAi.uninstallEmbedder(); // model + tokenizer, clears identity
await FlutterEdgeAi.uninstallStt();
await FlutterEdgeAi.uninstallTts();
```

Each first closes the model `getActiveEmbedder()`, `getActiveStt()` or
`getActiveTts()` built from those files, including the one your app holds: a
request already running finishes, and later calls on it throw. The next
`getActive*()` call throws until a model is installed again, and then builds a
new one.

To delete an inference model, or any model by filename, use `uninstallModel()`.
When the file belongs to the active inference model (the model or its LoRA), it
also clears the active inference identity: `hasActiveModel()` is false and
`getActiveModel()` throws `NoActiveModelError` instead of handing out the model
of a deleted file. A directory model (ORT-GenAI, installed with
`fromHuggingFace`) is uninstalled by its name, the `spec.name` its install
returned: every file of it and its directory go.

It first closes the model `getActiveModel()` built from that file, with its
sessions and chats: a generation running on it stops early, with or without an
error depending on the engine, and later calls on it throw. Models you opened
with `openModel()` stay open; close them yourself:

```dart
// Closes the model getActiveModel() built from this file, deletes the
// downloaded file + metadata (a fromFile file stays) and, if this was the
// active model, clears the active inference identity.
await FlutterEdgeAi.uninstallModel('Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm');
```

<Info>

`clearActiveInferenceIdentity()` wipes both the in-memory active spec and the
persisted preference without deleting any file. `uninstallModel()` now does it
for you when it removes a file of the active model; calling it afterwards, as
earlier releases required, is still harmless. The `uninstallEmbedder/Stt/Tts`
helpers clear their identity too.

</Info>

### Inspecting what's active

Cheap, synchronous getters return the active model's **identity** (its spec)
without loading the engine — use these to render UI, not `getActiveModel()`
(which loads the runtime). Each is typed to its modality:

```dart
final InferenceModelSpec? model = FlutterEdgeAi.activeModelSpec;
final EmbeddingModelSpec? embedder = FlutterEdgeAi.activeEmbedderSpec;
final SttModelSpec? stt = FlutterEdgeAi.activeSttSpec;
final TtsModelSpec? tts = FlutterEdgeAi.activeTtsSpec;

// Where an installed file is read from on the device: your own file for a
// fromFile install, the app bundle for fromBundled on iOS, else core's copy.
// On web it returns the file name itself, not a path or a URL.
final path = await FlutterEdgeAi.getModelPath(
  'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
);
```

### Storage & cleanup

Inspect on-device usage and reclaim space left by interrupted downloads:

```dart
final info = await FlutterEdgeAi.getStorageInfo();      // StorageStats: files + bytes
final orphans = await FlutterEdgeAi.getOrphanedFiles();  // fragments with no metadata
final removed = await FlutterEdgeAi.cleanupStorage();    // delete orphans, returns count
await FlutterEdgeAi.performCleanup();                    // cancel stale tasks + sweep
```

## Message Types

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

// Thinking content (DeepSeek, Gemma 4, Qwen3, …)
final thinkingMessage = Message.thinking(text: "Let me analyze this problem...");

// Check if a message contains an image
if (message.hasImage) {
  print('This message contains an image');
}
```

## Response Types

The model can return different types of responses depending on its capabilities:

```dart
chat.generateChatResponseAsync().listen((response) {
  if (response is TextResponse) {
    // Regular text token from the model
    print('Text token: ${response.token}');
  } else if (response is FunctionCallResponse) {
    // Model wants to call a function
    print('Function: ${response.name}');
    print('Arguments: ${response.args}');
    _handleFunctionCall(response);
  } else if (response is ParallelFunctionCallResponse) {
    // Several calls in one reply
    for (final call in response.calls) {
      _handleFunctionCall(call);
    }
  } else if (response is ThinkingResponse) {
    // Model's reasoning process
    print('Thinking: ${response.content}');
    _showThinkingBubble(response.content);
  }
});
```

- **`TextResponse`** — contains a text token (`response.token`) for regular model output.
- **`FunctionCallResponse`** — contains function name (`response.name`) and arguments (`response.args`). See [Function Calling](/docs/function-calling).
- **`ParallelFunctionCallResponse`** — several calls in one reply (`response.calls`, each a `FunctionCallResponse`).
- **`ThinkingResponse`** — contains the model's reasoning process (`response.content`). See [Thinking Mode](/docs/thinking-mode).

## Next Steps

- [Installation](/docs/installation) — per-platform setup and engine registration.
- [Models](/docs/models) — supported models, file formats, and capabilities.
- [Migration](/docs/migration) — upgrade from `flutter_gemma` or Flutter Edge AI 1.x.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-inference`](/docs/package-skills), the skill that teaches it engines, installing a model, sessions and chats, streaming, and the platform setup for all six targets.
