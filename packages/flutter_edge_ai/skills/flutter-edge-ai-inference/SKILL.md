---
name: flutter-edge-ai-inference
description: Use when adding on-device LLM inference with flutter_edge_ai — offline chat, local models, Hugging Face installs, streaming, system prompts, thinking, structured JSON output, ResponseFormat or a schema-constrained reply, image/audio prompts, CPU/GPU/NPU selection, stopping generation, or setting up the recommended .litertlm engine on Android, iOS, macOS, Windows, Linux or web. Also use when a reply is empty or deterministic, maxTokens does not shorten replies, FlutterEdgeAi is undefined, getActiveModel reports no engine, a session is closed, GPU numbers are wrong, or .litertlm fails on Android. For .task or .bin models, use flutter-edge-ai-mediapipe.
---

# Running a model with flutter_edge_ai

## Rules

1. Depend on `flutter_edge_ai` and an engine package, and import both. Engine packages do not re-export core.
2. Register the engine in `FlutterEdgeAi.initialize(inferenceEngines: [...])`. Core ships none.
3. Declare `fileType` on `installModel`. It defaults to `ModelFileType.task`, and the declaration — never the file name — picks the engine.
4. `maxTokens` is the context window. Cap the reply with `maxOutputTokens` on the session or chat.
5. Pass `isUser: true` on every user `Message`.
6. Use `openSession` / `openChat`; `createSession`, `createChat`, `model.session` and `model.chat` are deprecated and will be removed in 3.0.0. Close each returned session or chat when its conversation ends, keep the model while the feature is in use, and close it when the app no longer needs it.
7. Keep Hugging Face tokens out of source: read them with `String.fromEnvironment`. That keeps a token out of git, not out of the app — it is compiled into the binary, and on web into `main.dart.js`. A shipped app should download from a repo that needs no token.
8. On Android, set `minSdk 30` for anything built on `.litertlm` — inference, embeddings, speech.
9. Read [references/platform-setup.md](references/platform-setup.md) before the first build on a platform: without those entries the model fails to load or the app is killed for memory.

## Setup — the recommended engine (.litertlm)

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_litertlm
```

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

// In main(), before runApp: initialize() needs the Flutter binding.
WidgetsFlutterBinding.ensureInitialized();
await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

// A registry build: model type, file type, a commit-pinned URL, install name
// and size come with it; the size is checked before the model is active (not
// on the web): a file of another size is deleted and install() throws
// ModelValidationException.
await FlutterEdgeAi.installModelFromCatalog(LiteRtLmModels.gemma4E2bIt.generic)
    .withProgress((int percent) => print('downloading: $percent%'))
    .install();

final InferenceModel model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
```

Gemma 4 E2B is 2.6 GB and needs no token. On web install `LiteRtLmModels.gemma4E2bIt.web` (2.0 GB). `installModelFromCatalog` needs `flutter_edge_ai` 2.5.5; `FlutterEdgeAi.catalog` lists every build the registered engines offer, and `CatalogModel.variantFor` picks one this runtime runs (by platform and processor; for an NPU build the app names the SoC). On web, a file over 2 GiB needs `initialize(webStorageMode: WebStorageMode.streaming)`. Every build and where it has been run: https://flutteredge.ai/docs/registry. For your own file, `FlutterEdgeAi.installModel(modelType:, fileType:)` with `fromNetwork`, `fromAsset` or `fromFile`.

Supported models, their file types and engines: https://flutteredge.ai/docs/models.

`install()` skips the download when the file is already installed from the same source, so calling it at every launch is safe. The latest install becomes the model `getActiveModel` loads.

A gated repo needs a token, given once:

```dart
const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
  huggingFaceToken: hfToken.isEmpty ? null : hfToken,
);
```

Build with `--dart-define=HUGGINGFACE_TOKEN=hf_...`.

When a Hugging Face repo publishes a deployment manifest, one call picks the variant and its tested runtime settings. The engine carries its own resolver, so registering `LiteRtLmEngine` is enough:

```dart
final install = await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.litertlm,
).fromHuggingFace('litert-community/LFM2.5-230M').install();

final model = await FlutterEdgeAi.getActiveModel(defaults: install.runtime);
```

Other sources on the same builder: `.fromAsset(path)` for a model bundled in the app, `.fromFile(path)` for one already on disk, `.fromBundled(name)` for a platform-bundled resource. A `fromFile` file is used in place and stays the app's: uninstalling leaves it, and it is active again after a restart. Installing the same file name again from another source replaces the install.

`modelType` tells flutter_edge_ai how the model writes tool calls and reasoning, and on some engines it also picks the prompt format. Gemma 3 and Gemma 3n are `ModelType.gemmaIt` — there is no `gemma3`. The full set: `ModelType.general`, `ModelType.gemmaIt`, `ModelType.gemma4`, `ModelType.deepSeek`, `ModelType.qwen`, `ModelType.qwen3`, `ModelType.qwen35`, `ModelType.llama`, `ModelType.hammer`, `ModelType.functionGemma`, `ModelType.phi`. A wrong type still generates text; tool calls and reasoning then arrive as raw text.

## Traps

**Core not imported**
- Symptom: `Undefined name 'FlutterEdgeAi'`, `Undefined class 'InferenceModel'`, with only the engine package imported.
- Fix: `import 'package:flutter_edge_ai/flutter_edge_ai.dart';` as well.

**flutter_gemma names after upgrading to 2.0**
- Symptom: `Undefined name 'FlutterGemma'`, `Undefined name 'GemmaLogLevel'`, or a `package:flutter_gemma/...` import that does not resolve.
- Fix: the flutter_gemma names are gone in 2.0. Rename the dependencies and imports (`flutter_gemma*` → `flutter_edge_ai*`; `flutter_gemma_rag_sqlite` and `flutter_gemma_rag_qdrant` become `flutter_edge_ai_sqlite` and `flutter_edge_ai_qdrant`), then run `dart fix --apply`, which renames the old class names. Delete the old `flutter-gemma-*` skill directories and run `dart run skills@ get --all` again — they still teach the old names. RAG also left core in 2.0: see the flutter-edge-ai-rag skill.

**Deep imports after upgrading to 2.3**
- Symptom: `Target of URI doesn't exist: 'package:flutter_edge_ai/core/model.dart'` — or any other `package:flutter_edge_ai/core/…`, `/mobile/…`, `/web/…`, `/desktop/…` or `flutter_edge_ai_interface.dart` import.
- Fix: since `flutter_edge_ai` 2.3.0 core's internals are private under `lib/src`. Apps import `package:flutter_edge_ai/flutter_edge_ai.dart`; an engine or tokenizer package imports `package:flutter_edge_ai/engine.dart`. The deprecated members went in the same release — `setModelPath`, `installModelFromAsset`, `initialize(enableWebCache:)` and the rest; core's MIGRATION.md lists each with its replacement.

**After upgrading to 2.5**
- Symptom: `The method 'fromLegacyUrl' isn't defined for the type 'InferenceModelSpec'`, `generateEmbedding`/`generateEmbeddings`/`getDimension` undefined, or a deprecation warning on `FlutterEdgeAiPlugin.instance.createModel`.
- Fix: build the spec as `InferenceModelSpec(name:, modelSource: ModelSource.network(url) /.asset/.bundled/.file, modelType:)`; `fromLegacyUrl` defaulted to `ModelType.general`, so pass a model type explicitly. Replace `createModel(...)` (deprecated, removed in 3.0.0) with `FlutterEdgeAi.getActiveModel(...)` — on Android, iOS and desktop it ignored `modelType` and `fileType` and returned the active model anyway — or with `FlutterEdgeAi.openModel` for several models. Embeddings: `embed(EmbeddingInput.text(t), taskType: TaskType.retrievalQuery)`, `embedAll`, `dimension` (see the flutter-edge-ai-rag skill and core's MIGRATION.md).

**No engine registered**
- Symptom: `StateError: No inference engine can handle this model (ModelFileType.litertlm). Add the engine package to pubspec.yaml and pass it in inferenceEngines: of FlutterEdgeAi.initialize(...)`
- Fix: add the engine package and register its provider — or fix `fileType` if the wrong engine is registered.
- A `.gguf` model needs `flutter_edge_ai_llama` (llama.cpp through llamadart): register `LlamaEngineProvider()` and install with `fileType: ModelFileType.gguf`. Its build setup — the `hooks: user_defines: llamadart:` block, the Apple companion package with SwiftPM, iOS 16.4 / macOS 14, Android arm64-v8a and x86_64 only — is in that package's README.

**`maxTokens` used as a reply length**

```dart
// WRONG — asks for a 100-token context, not a 100-token reply
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 100);
```

- Symptom: replies are as long as ever. On native `.litertlm` CPU/GPU attempts the value is raised to 1024, the smallest context those models support, and only a debug-mode log says so. NPU attempts are not clamped: keep `maxTokens` at or below that catalog variant's `requiredMaxTokens` / compiled cache length, preferably by passing its `runtimeDefaults`. The web `.litertlm` engine does not take the value at all; on MediaPipe it is the real limit.
- Fix:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
final session = await model.openSession(maxOutputTokens: 100);
try {
  // Use session for this conversation.
} finally {
  await session.close();
}
```

Use 4096 or more with images or audio — one image costs hundreds of tokens.

**`isUser` left out**
- Symptom: an empty response, no error. `Message.isUser` defaults to `false`, so the prompt is read as the model's own turn.
- Fix: `Message(text: prompt, isUser: true)`.

**Same reply every time**
- Symptom: identical output for identical input.
- Causes: `topK: 1` is passed somewhere (greedy; it was the default up to `flutter_edge_ai` 2.1); the model's family decodes greedily by default (`ModelType.phi`, `ModelType.hammer`); or the seed is fixed — an unset `randomSeed` is 1 (or the `.litertlm` bundle's own), so a freshly loaded model repeats its first sampled answer.
- Fix: leave `temperature`, `topK` and `topP` unset to get the model's own sampler or its family's defaults (`SamplingParams.forModelType`), or pass a `temperature` — with no `topK`, a greedy family or bundle then contributes no `topK: 1`. Set them on the first session after `getActiveModel`: on `.litertlm` the sampler of the first generation stays in effect for later sessions (a one-time warning says so when a later session asks for other values), and its random state carries on, so a new chat already gets a new answer. MediaPipe starts each session from its seed: vary `randomSeed` there for a different answer to the same prompt.
- Exception: decoding stays greedy whatever you pass on `.litertlm` running on the NPU (`activeBackend == PreferredBackend.npu`); a one-time warning says so when you set any of them. ONNX follows the model's `genai_config.json`, which is greedy unless it sets `do_sample`; values you pass override it.

**Too many open sessions**
- Symptom: `StateError` says the model reached `maxConcurrentSessions`.
- Cause: every `openSession` and `openChat` stays live until it is closed.
- Fix: keep and reuse the handle for a conversation, and close it in `finally` or widget/service teardown.

## Generate

```dart
// Sampling left unset: the model's own sampler, else its family's defaults.
final InferenceModelSession session = await model.openSession(
  maxOutputTokens: 256,
);
try {
  await session.addQueryChunk(Message(text: prompt, isUser: true));
  final String reply = await session.getResponse();
} finally {
  await session.close();
}
```

Streaming:

```dart
final reply = StringBuffer();
await session.addQueryChunk(Message(text: prompt, isUser: true));
await for (final token in session.getResponseAsync()) {
  reply.write(token); // update the UI here
}
```

To stop early, call `await session.stopGeneration()` — `chat.stopGeneration()` on a chat. Cancelling the stream subscription detaches Dart but does not stop native decoding on every engine. On current `.litertlm` Android, iOS and desktop sessions, a stopped turn that produced text stays in the chat with its partial reply; a stop before any text is taken back. Rewind-capable native conversations rewind and reinsert that exchange. NPU, linear-attention and other non-rewind paths rebuild from full message history, including image and audio parts, so earlier media is preserved. The legacy `flutter_gemma_litertlm` package needs 1.8.1 or later for a stopped chat to answer again at all.

## Structured JSON output

Use only `openSession(responseFormat:)` or `openChat(responseFormat:)`;
`createSession` and `createChat` have no format argument. Build
`ResponseFormat.jsonObject()` or `ResponseFormat.jsonSchema(...)`, then call
`model.refusalFor(format)`. Do not open the session when it returns a
`ResponseFormatUnsupportedException`. `model.structuredOutputSupport` reports
the enforced keywords and `delivery` (`incremental` or `buffered`).

Core's dialect is `type`, `properties`, `required`,
`additionalProperties: false`, `items`, `enum`, `const`, the min/max item,
string and numeric bounds, plus `description`, `title`, `examples`. The root
needs one scalar `type`; do not use unions, `$ref`, `$defs`, composition,
`pattern` or `format`.

Handle all three structured failures: `ResponseFormatUnsupportedException`;
`IncompleteStructuredOutputException` (`end`, `partialText`);
`NonConformingStructuredOutputException` (`text`, optional `schemaPath`).
Incremental engines stream text before the final validation error. A prompt that
never fits the context fails with `ContextLimitException` instead. Never combine
a format with tools or `enableThinking: true`.

Current support: LiteRT-LM enforces the whole dialect on macOS and iOS arm64
CPU/Metal, Linux x64 CPU/Vulkan, Windows x64 CPU/D3D12, and Android arm64 CPU
plus Adreno/Mali/PowerVR GPU. Every NPU, Web, and unlisted row is refused.
MediaPipe refuses every format. ONNX accepts
only native macOS arm64 with `tokenizer.json`; a qualified GGUF runtime accepts
macOS arm64 CPU/Metal and Chrome on macOS with dart2wasm + WebGPU, subject to
`refusalFor`; built-in AI has no qualified platform yet.

## Multi-turn chat

```dart
final InferenceChat chat = await model.openChat(
  systemInstruction: 'You are a concise assistant.',
  maxOutputTokens: 512,
);
try {
  await chat.addQueryChunk(Message(text: prompt, isUser: true));
  final reply = StringBuffer();
  await for (final r in chat.generateChatResponseAsync()) {
    switch (r) {
      case TextResponse(:final token):
        reply.write(token);
      case ThinkingResponse() || FunctionCallResponse() || ParallelFunctionCallResponse():
        break;
    }
  }
} finally {
  await chat.close();
}
```

The chat keeps the history: add the next user message and generate again. `generateChatResponse()` returns the whole reply as one sealed `ModelResponse` — `TextResponse`, `FunctionCallResponse`, `ParallelFunctionCallResponse` or `ThinkingResponse` — and a `switch` over it must cover all four.

For a core-managed turn, any engine error removes the entire staged turn before
the error reaches the app. A hook-backed chat owns that policy itself; the
shipped llama.cpp hook also rolls failed turns back. Catch
`ContextLimitException` as a refused input: nothing from that turn was
committed, so shorten it or reopen with less history. Do not treat every
`TurnEnd.contextLimit` as a refusal—a turn can fill the window during decoding
and end cleanly after producing text, in which case the partial exchange is
kept.

## Two conversations at once

Every `openSession` and `openChat` owns a conversation and counts against `maxConcurrentSessions`. Keep each returned handle and close it when done.

An argument you leave out of `openChat` is filled by the engine. Native
`.litertlm` takes the installed model's type and media flags. Its native FFI
sessions accept declared image and audio input on both native and virtual
backings. Each session has its own conversation and KV cache on macOS CPU/Metal,
Linux and Windows CPU, Android Adreno/Mali, Qualcomm or Google Tensor NPUs on
Android, and Intel NPUs on Windows. Linux Vulkan, Windows D3D12, iOS, Android
CPU/PowerVR/MediaTek, and unverified Linux arm64 accelerators use virtual
sessions that replay full messages, including media, into one shared
conversation. The `.litertlm` web engine is also virtual but text-only and uses
core's defaults, so pass `modelType:` for a non-Gemma model. Hybrid models such
as LFM2 rebuild from full messages when recovery is needed and never rewind.
Native sessions cost memory while idle: Gemma 4 E2B on an M5 Pro added 36.8 MiB
of RSS per idle session at `maxTokens: 4096`, from the third session onward. Set
`maxConcurrentSessions` on `getActiveModel` or `openModel` to bound the count.

`flutter_edge_ai_llama` and MediaPipe on the web take the installed type and media support. MediaPipe on Android and iOS takes the type and audio support, with images off unless you pass `supportImage: true`. Built-in AI takes the type and image support and refuses `supportAudio: true`. Native and web ONNX take the installed type but remain text-only. Detached sessions work on native/web `.litertlm`, MediaPipe Android/iOS/Web, `flutter_edge_ai_onnx` natively since 0.8.0 and on Web since 0.9.0, built-in AI and llama.cpp; close every detached session yourself.

```dart
final summariser = await model.openChat(modelType: ModelType.gemma4);
final assistant = await model.openChat(modelType: ModelType.gemma4);
try {
  await summariser.addQueryChunk(Message(text: chunk, isUser: true));
  await assistant.addQueryChunk(Message(text: question, isUser: true));
} finally {
  await summariser.close();
  await assistant.close();
}
```

## Thinking models

Gemma 4, Qwen3, DeepSeek R1 and `.litertlm` bundles with a thought channel
(e.g. SmolLM3, Phi-4 Mini Reasoning) can emit reasoning on their supported engines.
Pass `enableThinking: true` to `openChat`. Reasoning arrives as
`ThinkingResponse` only from `generateChatResponseAsync()`;
`generateChatResponse()` strips it. On a native `.litertlm`, reasoning that a
bundle streams on its thought channel arrives as `ThinkingResponse` whatever
the `modelType`, and `enableThinking: false` sends `enable_thinking: false` to the
template — a Qwen3 template that reads the flag thinks when it is missing. With
`ModelType.qwen3`, core also appends ` /no_think` to text turns, the only off
switch for a bundle whose template ignores the flag; Qwen3.5 and later take
`ModelType.qwen35` and no suffix. On Web, the `.litertlm` engine sends the
same `enable_thinking`, and Gemma 4 E2B returns `ThinkingResponse` in Chrome;
core also parses Qwen3's emitted `<think>` tags there. MediaPipe Web has no
thinking API, ONNX Web ignores `enableThinking`, and DeepSeek R1 thinks on
Android and iOS only — it ships as a mobile `.task` build.

A model that thinks until `maxOutputTokens` ends the turn with an empty answer.
On `.litertlm` (native, `flutter_edge_ai_litertlm` 1.18.0+) cap the thinking
with `LiteRtLmEngine(thinkingTokenBudget: 512)` in `initialize`: each
generation with `enableThinking: true` then stops thinking at the budget and
answers, and in a tool loop a generation after a tool result has its own
budget. Keep the budget below `maxOutputTokens` and below what the context
(`maxTokens`, 1024 by default) has left after the prompt and the history, or it
is never reached. It does nothing with `enableThinking: false`, even on a model
that reasons anyway (Qwen3 4B Thinking 2507). LiteRT-LM caps the bundle's first
declared channel (measured on Gemma 4 E2B and
`Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`); a bundle that declares none is not
capped, and loading one with a budget prints a warning. It is set per engine,
not per chat, and fixed when the engine is registered; the web engine ignores
it. On the GPU it slows decoding for the whole generation (Gemma 4 E2B: about a
fifth on an M5 Pro, about 40% on an NVIDIA L4); on the CPU no cost was
measured.

```dart
final chat = await model.openChat(enableThinking: true, modelType: ModelType.qwen3);
final answer = StringBuffer();
await chat.addQueryChunk(Message(text: question, isUser: true));
await for (final r in chat.generateChatResponseAsync()) {
  switch (r) {
    case ThinkingResponse(:final content):
      print('reasoning: $content');
    case TextResponse(:final token):
      answer.write(token);
    case FunctionCallResponse() || ParallelFunctionCallResponse():
      break;
  }
}
await chat.close();
```

## Images

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096, supportImage: true);
final chat = await model.openChat(supportImage: true);
try {
  await chat.addQueryChunk(
    Message(text: 'What is in this photo?', isUser: true, imageBytes: bytes),
  );
  final response = await chat.generateChatResponse();
} finally {
  await chat.close();
}
```

On web, images need a MediaPipe `.task` build such as `gemma-4-E2B-it-web.task` (same Hugging Face repo as the `.litertlm`, `ModelFileType.task`, the flutter-edge-ai-mediapipe skill). On that build Gemma 4 has no thinking, and its tools never reach the model. The `.litertlm` web engine is text-only: `supportImage: true` loads without error, but `addQueryChunk` with an image throws `UnsupportedError`.

## Audio

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096, supportAudio: true);
final chat = await model.openChat(supportAudio: true);
try {
  await chat.addQueryChunk(
    Message(text: 'What is said in this recording?', isUser: true, audioBytes: bytes),
  );
  final response = await chat.generateChatResponse();
} finally {
  await chat.close();
}
```

`audioBytes` is a whole WAV file — 16 kHz mono, header included. The speech package is the opposite: `transcribe` takes raw PCM with no header. Audio input needs Gemma 4 or Gemma 3n, on Android, iOS or desktop (VibeVoice-ASR also takes audio, for transcription only; measured on Android and macOS); on the `.litertlm` web engine an audio message throws `UnsupportedError`.

The `.litertlm` engine sends a Gemma 4 message as images, text, then audio, as the Gemma 4 model card asks, and every other model type as images, audio, then text (`flutter_edge_ai` 2.4.0 with `flutter_edge_ai_litertlm` 1.14.0; litertlm 1.13.x ignores `multimodalOrder`). A model whose chat template expects another order takes `getActiveModel(multimodalOrder: MultimodalOrder.imagesAudioText)` or `MultimodalOrder.imagesTextAudio`.

## The model is a singleton

`getActiveModel` returns one model per process. Calling it again with the same arguments returns that model, on every platform (web since 2.2.1). Different runtime arguments, or another active model, rebuild it and close the previous one — a handle still held stops working; `model.isClosed` says so from the moment `close()` starts, and a `getActiveModel` call made meanwhile waits for the close to finish before it builds the next model. With no model installed it throws `NoActiveModelError`, a `StateError`. Load it once, then create and close sessions per conversation.

For several models loaded at once (one file on CPU and GPU, or two files), use `FlutterEdgeAi.openModel(spec, …)` (2.5.0, mobile and desktop) with `LiteRtLmEngine` (`flutter_edge_ai_litertlm` 1.16.0); other engines throw `UnsupportedError`. Install the file with `install(activate: false)` and pass the returned `spec`. Every call builds a new model that the app closes: it is never cached, a `getActiveModel` rebuild leaves it open, and the plugin has no memory policy (on iOS a process past its memory limit is killed, not thrown at). An `activate: false` install that would replace the active model's file throws `StateError`, and `openModel` refuses a spec that is not the installed one. Its parameters mean what they do on `getActiveModel`; a model's sampler is fixed by its first generation, so sessions sharing one model use the same sampling; uninstalling a model does not close the models opened on it (`uninstallModel` closes only the model `getActiveModel` built from that file). Measured on macOS (CPU and GPU engines on one file, two GPU engines) and on Windows Lunar Lake (CPU, GPU and NPU engines together). Not measured: Android, iOS, Linux, and two GPU engines on Windows, where a second one can fail with `wgpu::Instance already set` (https://flutteredge.ai/docs/desktop).

```dart
final spec = (await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
).fromFile(path).install(activate: false)).spec;

final cpu = await FlutterEdgeAi.openModel(spec, preferredBackend: PreferredBackend.cpu);
final gpu = await FlutterEdgeAi.openModel(spec, preferredBackend: PreferredBackend.gpu);
// ... generate on either ...
await gpu.close();
await cpu.close();
```

## Backends

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 1024,
  preferredBackend: PreferredBackend.gpu,
);
print(model.activeBackend); // what actually loaded
```

| `preferredBackend` | Tried in order |
| --- | --- |
| `null` or `gpu` | GPU, then CPU |
| `npu` | GPU, then CPU: a generic bundle has no NPU graph, so the NPU is not tried (with `backendFallback: false`, a `LiteRtLmBundleException`) |
| `cpu` | CPU only |
| any, for a bundle compiled for an NPU | the NPU only: `null` and `npu` run there, `gpu` and `cpu` are refused |

The rows are for a generic bundle. A text model that declares `backend_constraint` is tried only on the backends it allows (with `null`, GPU then CPU, each only if it allows it). With `LiteRtLmEngine(backendFallback: false)` (`flutter_edge_ai_litertlm` 1.14.0) only the first backend of a row is tried, and a failure throws `BackendInitException` with LiteRT-LM's own reason.

Read `activeBackend` rather than assuming the requested one loaded; the web `.litertlm` engine reports `null`. `PreferredBackend.npu` needs a Snapdragon (Android), a Qualcomm Linux arm64 board, a Google Tensor G5/G6 Pixel (Android 16 or later, not a BP2A build; run on G6 only), a MediaTek Android 12+ device whose NeuroPilot runtime opens in the app (`flutter_edge_ai_litertlm` 1.17.0), or Intel Lunar/Panther Lake (Windows), and a model compiled for that NPU — an NPU build is compiled for one context (`requiredMaxTokens` on its catalog variant), so keep `maxTokens` at or below it; the Intel NPU needs `flutter_edge_ai_litertlm` 1.15.0 — 1.14.0, like every release since `native-v0.17.0`, fails its load or ends the process (`0xC0000409`); `PreferredBackend.cpu` never falls back. Intel's Gemma 4 12B for Panther Lake needs 1.17.0 (OpenVINO 2026.4.1; 2026.3 refuses its metadata-2.7 blobs), and each load writes a 5.55 GB weight bank to `%TEMP%`: keep that much free on the system drive and `close()` the model before the app exits. The iOS Simulator is CPU-only. On an iOS device a MediaPipe `.task` on the GPU is killed for memory while loading, before any fallback can run: pass `PreferredBackend.cpu` for it (flutter-edge-ai-mediapipe). On web, MediaPipe is GPU-only.

On NPU, run a **Gemma 4** bundle (none is published for MediaTek: there Gemma 3 1B `…_mt6989` ran on a Galaxy Tab S10+, and whether it keeps its prefill chunks is not measured). Most Gemma 3 bundles on the Qualcomm or the Intel NPU (Google Tensor and MediaTek not measured) drop every prefill chunk after the first — no error, no log line, and a fluent reply that answers from the opening of the prompt and ignores the rest (LiteRT-LM#3508; of the published Qualcomm 1B files only `…_sm8850` keeps them). `maxTokens` is also not clamped up to 1024 on the NPU attempt the way it is on CPU and GPU, because the safe context is baked into the compiled bundle: pass the `cache_length` it was built for. A bundle compiled for no NPU never runs on one, whatever its `backend_constraint` says: it has no NPU graph, and LiteRT would try to compile it on the device with a compiler plugin, which no NPU stack here ships, and run it on the CPU while reporting `npu` — so `PreferredBackend.npu` falls back to GPU, then CPU, for it (refused with `backendFallback: false`), and the floor applies to those attempts. A bundle compiled for an NPU (`…_qualcomm_sm8750.litertlm`, read from the file before any engine exists) runs on the NPU only: it is the default when `preferredBackend` is unset, `gpu`/`cpu` throw `LiteRtLmBundleException`, and an unreachable NPU throws `BackendInitException` at once. Unset `preferredVisionBackend`/`preferredAudioBackend` follow the file (the encoder's declared `backend_constraint`, the CPU when it allows the CPU; else the NPU it is compiled for; else CPU): Gemma 4 vision and audio run on the CPU, Gemma 3n vision on the GPU, because its section allows gpu only. Set one only where the section allows it (the published Gemma 4 and Gemma 3n audio encoders declare cpu, so `gpu` is refused; `preferredVisionBackend: cpu` is refused on Gemma 3n), or the load throws `LiteRtLmBundleException`; read `activeVisionBackend`/`activeAudioBackend` (filled by `flutter_edge_ai_litertlm` 1.14.0, null when the model has no such encoder). Its `problem` is `wrongBackend` for a backend the file rules out, `incomplete` for a download that stopped early, and `unsupportedNpu` for a text model, or an encoder that is on, compiled for an NPU this package has no dispatch for here (a Qualcomm bundle on Windows, a Google Tensor or MediaTek bundle off Android), for sections the load turns on that are compiled for two different NPUs, or for an NPU encoder next to a text model that is not on the NPU. `LiteRtLmEngine(backendFallback: false)` (1.14.0) makes one attempt and reports LiteRT-LM's reason (`LiteRtLmEngineCreateException.nativeMessage`); `readLiteRtLmBundleInfo(path)` (1.14.0) shows what the file declares. The NPU candidate is attempted only for a bundle compiled for an NPU, and only on Windows, on Android phones with Qualcomm FastRPC, on Qualcomm Linux arm64 boards with `/dev/fastrpc-cdsp`, and on Google Tensor G5/G6 Pixels with Android 16 or later (not a BP2A build; LiteRT itself refuses a bundle of the other Tensor generation when the engine is created), and on MediaTek Android 12+ devices whose NeuroPilot adapters open in the app (NeuroPilot refuses a bundle compiled for another MediaTek SoC when the engine is created), the last four only when the app sets `qualcomm_npu`, `google_tensor_npu` or `mediatek_npu`; on other Android phones, macOS, other Linux machines and iOS it is skipped, because nothing there can run it — and on macOS the native runtime was measured accepting `npu` anyway, which made `activeBackend` report an NPU the machine does not have. Windows has no device probe: a bundle compiled for the Intel NPU is not refused on a PC without one, and what LiteRT does then is not measured.

On GPU, Gemma 4 can copy numbers wrongly from a long prompt: `2026/06/23` comes back as `20226/12/17`, the same way on every run (LiteRT-LM#3012 on Adreno, #2814 on Metal). The published Gemma 4 `.litertlm` files ask for half-precision activations. Ask for full precision when the answers carry figures, dates or amounts:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.gpu,
  activationDataType: ActivationDataType.float32,
);
```

Prefill gets slower (about 3× on a Snapdragon 8 Elite and an iPhone 11, under 1.5× on an Apple M3 Max); decode speed barely changes. Left unset, the model file decides, with one exception: a FunctionGemma bundle that declares no `prefer_activation_type` gets `float32` on its GPU attempt, because at `float16` it answers with nothing. A plain Gemma 3 270M (`ModelType.gemmaIt`) answers with `<pad>` on the GPU too (LiteRT-LM#3280) but is not covered: pass `float32` for it. A value you pass always wins. It applies to the text decoder of `.litertlm` models on Android, iOS and desktop — not to the vision or audio encoders, which keep what the model file asks for; MediaPipe, ONNX, built-in AI and the web engines ignore it entirely.

`float32` needs more GPU memory than the default, and by default a GPU engine that cannot be created falls back to CPU without an exception, only a WARNING line in the log — right digits, a much slower run; with `LiteRtLmEngine(backendFallback: false)` the load throws `BackendInitException` instead. After loading, check `model.activeBackend == PreferredBackend.gpu` before concluding the setting did anything. On Android the GPU shares system memory, so on a 4–6 GB phone running out of it at `float32` can end the app rather than fall back to CPU. Both precisions share one compiled GPU program cache per model, so switching recompiles the GPU programs (about 600 MB for Gemma 4 E2B): pick one precision per install rather than per request. Every `flutter_edge_ai_litertlm` release supports the setting; the legacy `flutter_gemma_litertlm` package needs 1.8.3 or later.

## Platform setup

Android needs `minSdk 30` and the internet permission in release builds, and ships `arm64-v8a` only. iOS needs Podfile or Xcode settings and memory entitlements; macOS needs a 14.0 deployment target, entitlements, and with Swift Package Manager off a Podfile build phase; web needs script tags in `web/index.html`. Read [references/platform-setup.md](references/platform-setup.md) before building for any of them — without those entries the model fails to load or the app runs out of memory.

Finished an app with flutter_edge_ai? See the [showcase](https://flutteredge.ai/showcase) and [submit it](https://flutteredge.ai/showcase/submit).
