---
name: flutter-edge-ai-inference
description: Use when adding on-device LLM inference to a Flutter app with flutter_edge_ai — offline chat, running Gemma, Qwen or Phi locally, installing a model from Hugging Face (gated repos included), streaming replies, a system prompt, thinking or reasoning output, image or audio prompts, picking a CPU, GPU or NPU backend, stopping generation — or setting up the recommended .litertlm engine (ModelFileType.litertlm) on Android, iOS, macOS, Windows, Linux or web, including the Android minSdk and internet permission, the Apple entitlements and Podfile, and the web index.html script tags. Also use when a reply comes back empty, the model answers identically every time, maxTokens does not shorten replies, FlutterEdgeAi is an undefined name, getActiveModel throws "No inference engine can handle this model", a session throws "Session is closed", numbers come back wrong on the GPU, or .litertlm fails to load on Android. For .task or .bin models (ModelFileType.task or ModelFileType.binary), use flutter-edge-ai-mediapipe.
---

# Running a model with flutter_edge_ai

## Rules

1. Depend on `flutter_edge_ai` and an engine package, and import both. Engine packages do not re-export core.
2. Register the engine in `FlutterEdgeAi.initialize(inferenceEngines: [...])`. Core ships none.
3. Declare `fileType` on `installModel`. It defaults to `ModelFileType.task`, and the declaration — never the file name — picks the engine.
4. `maxTokens` is the context window. Cap the reply with `maxOutputTokens` on the session or chat.
5. Pass `isUser: true` on every user `Message`.
6. Close a session or chat when its conversation ends. Keep the model while the feature is in use, and close it when the app no longer needs it.
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

await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
)
    .fromNetwork(
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    )
    .withProgress((int percent) => print('downloading: $percent%'))
    .install();

final InferenceModel model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
```

Gemma 4 E2B is 2.6 GB and needs no token. On web use `gemma-4-E2B-it-web.litertlm` from the same repo (2.0 GB).

`install()` skips the download when the file is already on disk, so calling it at every launch is safe. The latest install becomes the model `getActiveModel` loads.

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

Other sources on the same builder: `.fromAsset(path)` for a model bundled in the app, `.fromFile(path)` for one already on disk, `.fromBundled(name)` for a platform-bundled resource.

`modelType` tells flutter_edge_ai how the model writes tool calls and reasoning, and on some engines it also picks the prompt format. Gemma 3 and Gemma 3n are `ModelType.gemmaIt` — there is no `gemma3`. The full set: `ModelType.general`, `ModelType.gemmaIt`, `ModelType.gemma4`, `ModelType.deepSeek`, `ModelType.qwen`, `ModelType.qwen3`, `ModelType.qwen35`, `ModelType.llama`, `ModelType.hammer`, `ModelType.functionGemma`, `ModelType.phi`. A wrong type still generates text; tool calls and reasoning then arrive as raw text.

## Traps

**Core not imported**
- Symptom: `Undefined name 'FlutterEdgeAi'`, `Undefined class 'InferenceModel'`, with only the engine package imported.
- Fix: `import 'package:flutter_edge_ai/flutter_edge_ai.dart';` as well.

**flutter_gemma names after upgrading to 2.0**
- Symptom: `Undefined name 'FlutterGemma'`, `Undefined name 'GemmaLogLevel'`, or a `package:flutter_gemma/...` import that does not resolve.
- Fix: the flutter_gemma names are gone in 2.0. Rename the dependencies and imports (`flutter_gemma*` → `flutter_edge_ai*`; `flutter_gemma_rag_sqlite` and `flutter_gemma_rag_qdrant` become `flutter_edge_ai_sqlite` and `flutter_edge_ai_qdrant`), then run `dart fix --apply`, which renames the old class names. Delete the old `flutter-gemma-*` skill directories and run `dart run skills@ get --all` again — they still teach the old names. RAG also left core in 2.0: see the flutter-edge-ai-rag skill.

**No engine registered**
- Symptom: `StateError: No inference engine can handle this model (ModelFileType.litertlm). Add the engine package to pubspec.yaml and pass it in inferenceEngines: of FlutterEdgeAi.initialize(...)`
- Fix: add the engine package and register its provider — or fix `fileType` if the wrong engine is registered.

**`maxTokens` used as a reply length**

```dart
// WRONG — asks for a 100-token context, not a 100-token reply
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 100);
```

- Symptom: replies are as long as ever. On native `.litertlm` the value is raised to 1024, the smallest context those models support, and only a debug-mode log says so. The web `.litertlm` engine does not take the value at all; on MediaPipe it is the real limit.
- Fix:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
final session = await model.createSession(maxOutputTokens: 100);
```

Use 4096 or more with images or audio — one image costs hundreds of tokens.

**`isUser` left out**
- Symptom: an empty response, no error. `Message.isUser` defaults to `false`, so the prompt is read as the model's own turn.
- Fix: `Message(text: prompt, isUser: true)`.

**Same reply every time**
- Symptom: identical output for identical input. `createSession` and `createChat` default to `topK: 1`, which is greedy decoding.
- Fix: pass `topK` (e.g. 40) and a `temperature`. Set them on the first session after `getActiveModel` — on `.litertlm` the first session's sampler settings can stay in effect for later ones.
- Exception: decoding stays greedy whatever you pass on `.litertlm` running on the NPU (`activeBackend == PreferredBackend.npu`) and on ONNX, native and web. Those ignore the sampling parameters; only a debug log says so on the NPU.

**`Session is closed`**
- Symptom: `StateError: Session is closed` from a session or chat that is still in use.
- Cause: `createSession` and `createChat` fill one slot per model; creating another closes the one before.
- Fix: one conversation at a time, or `openSession` / `openChat` for several (below). On the web `.litertlm` engine a second `createSession` hands back the session that is already open, history and all, rather than a fresh one — close the current chat before creating the next.

## Generate

```dart
final InferenceModelSession session = await model.createSession(
  temperature: 0.8,
  topK: 40,
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

To stop early, call `await session.stopGeneration()` — `chat.stopGeneration()` on a chat. Cancelling the stream subscription detaches Dart but does not stop native decoding on every engine. On `.litertlm` on Android, iOS and desktop the chat keeps working after a stop, but images and audio from earlier turns are no longer visible to the model — re-send an image if the next question is about it. Every `flutter_edge_ai_litertlm` release includes this behavior; the legacy `flutter_gemma_litertlm` package needs 1.8.1 or later.

## Multi-turn chat

```dart
final InferenceChat chat = await model.createChat(
  systemInstruction: 'You are a concise assistant.',
  temperature: 0.8,
  topK: 40,
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

## Two conversations at once

`createSession` and `createChat` fill a single slot on the model, so a second one closes the first. For concurrent conversations use `openSession` / `openChat`, and close each one.

They live only on the base class, so — unlike `createChat` — they inherit nothing from the installed model: pass `modelType:` (and `supportImage:` if the chat sends images) explicitly, or the chat runs as `ModelType.gemmaIt` with images off. They work on `.litertlm` (native and web), on MediaPipe Android and iOS, and on built-in AI; everywhere else — ONNX and MediaPipe web — they throw `UnsupportedError`.

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

Gemma 4, Qwen3 and DeepSeek R1 can emit reasoning on their supported engines.
Pass `enableThinking: true` to `createChat`. Reasoning arrives as
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

```dart
final chat = await model.createChat(enableThinking: true, modelType: ModelType.qwen3);
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
final chat = await model.createChat(supportImage: true);
await chat.addQueryChunk(
  Message(text: 'What is in this photo?', isUser: true, imageBytes: bytes),
);
```

On web only a MediaPipe `.task` build takes images (the flutter-edge-ai-mediapipe skill). The `.litertlm` web engine is text-only: `supportImage: true` loads without error, but `addQueryChunk` with an image throws `UnsupportedError`.

## Audio

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096, supportAudio: true);
final chat = await model.createChat(supportAudio: true);
await chat.addQueryChunk(
  Message(text: 'What is said in this recording?', isUser: true, audioBytes: bytes),
);
```

`audioBytes` is a whole WAV file — 16 kHz mono, header included. The speech package is the opposite: `transcribe` takes raw PCM with no header. Audio input needs Gemma 4 or Gemma 3n, on Android, iOS or desktop; on the `.litertlm` web engine an audio message throws `UnsupportedError`.

## The model is a singleton

`getActiveModel` returns one model per process. Calling it again with different runtime arguments rebuilds it and closes the previous one — a handle still held stops working. Load it once, then create and close sessions per conversation.

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
| `npu` | NPU, GPU, CPU on Windows, and on Qualcomm Android and Qualcomm Linux arm64 when the app sets `qualcomm_npu`; GPU, CPU everywhere else |
| `cpu` | CPU only |

Read `activeBackend` rather than assuming the requested one loaded; the web `.litertlm` engine reports `null`. `PreferredBackend.npu` needs a Snapdragon (Android) or Intel Lunar/Panther Lake (Windows) and a model compiled for that NPU; `PreferredBackend.cpu` never falls back. The iOS Simulator is CPU-only. On web, MediaPipe is GPU-only.

On NPU, run a **Gemma 4** bundle. A Gemma 3 bundle on either vendor's NPU drops every prefill chunk after the first — no error, no log line, and a fluent reply that answers from the opening of the prompt and ignores the rest (LiteRT-LM#3508). `maxTokens` is also not clamped up to 1024 on the NPU attempt the way it is on CPU and GPU, because the safe context is baked into the compiled bundle: pass the `cache_length` it was built for. Requesting `PreferredBackend.npu` does not guarantee the NPU runs — the engine falls back to GPU then CPU, and the floor applies to those attempts, so a fallback is clamped rather than crashed. The NPU candidate is attempted only on Windows and on Android phones with Qualcomm FastRPC; on other Android phones, macOS, Linux and iOS it is skipped, because nothing there can run it — and on macOS the native runtime was measured accepting `npu` anyway, which made `activeBackend` report an NPU the machine does not have. On Windows the check is per OS, so a PC without an Intel NPU still attempts it, and `activeBackend` can then report `npu` while the model runs elsewhere.

On GPU, Gemma 4 can copy numbers wrongly from a long prompt: `2026/06/23` comes back as `20226/12/17`, the same way on every run (LiteRT-LM#3012 on Adreno, #2814 on Metal). The published Gemma 4 `.litertlm` files ask for half-precision activations. Ask for full precision when the answers carry figures, dates or amounts:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.gpu,
  activationDataType: ActivationDataType.float32,
);
```

Prefill gets slower (about 3× on a Snapdragon 8 Elite and an iPhone 11, under 1.5× on an Apple M3 Max); decode speed barely changes. Left unset, the model file decides. It applies to the text decoder of `.litertlm` models on Android, iOS and desktop — not to the vision or audio encoders, which keep what the model file asks for; MediaPipe, ONNX, built-in AI and the web engines ignore it entirely.

`float32` needs more GPU memory than the default, and a GPU engine that cannot be created falls back to CPU without an error — right digits, a much slower run. After loading, check `model.activeBackend == PreferredBackend.gpu` before concluding the setting did anything. On Android the GPU shares system memory, so on a 4–6 GB phone running out of it at `float32` can end the app rather than fall back to CPU. Both precisions share one compiled GPU program cache per model, so switching recompiles the GPU programs (about 600 MB for Gemma 4 E2B): pick one precision per install rather than per request. Every `flutter_edge_ai_litertlm` release supports the setting; the legacy `flutter_gemma_litertlm` package needs 1.8.3 or later.

## Platform setup

Android needs `minSdk 30` and the internet permission in release builds, and ships `arm64-v8a` only. iOS needs Podfile or Xcode settings and memory entitlements; macOS needs entitlements and a Podfile build phase; web needs script tags in `web/index.html`. Read [references/platform-setup.md](references/platform-setup.md) before building for any of them — without those entries the model fails to load or the app runs out of memory.
