---
title: Getting Started
description: Run Gemma and other on-device LLMs in your Flutter app — Android, iOS, Web, and Desktop.
image: https://flutteredge.ai/images/og-image.png
---

Bring the power of Google's lightweight Gemma language models and other on-device
LLMs directly to your Flutter applications. With **flutter_edge_ai** you can
seamlessly incorporate advanced AI capabilities into your apps — all without
relying on external servers.

[Gemma](https://ai.google.dev/gemma) is a family of lightweight, state-of-the-art
open models built from the same research and technology used to create the Gemini
models. The plugin supports not only Gemma, but also Qwen, DeepSeek, Phi, FastVLM,
SmolLM and more — see [Models](/docs/models) for the full list.

## Features

- **Local Execution:** Run Gemma and other LLMs (Qwen, DeepSeek, Phi, FastVLM, SmolLM, …) directly on user devices for enhanced privacy and offline functionality.
- **Platform Support:** Compatible with iOS, Android, Web, macOS, Windows, and Linux.
- **Desktop Support:** Native desktop apps with GPU acceleration via LiteRT-LM, called directly from Dart through `dart:ffi` — no JVM/JRE bundling. See [Desktop Support](/docs/desktop).
- **Built-in / System AI:** Use the OS's own on-device model, no download — Gemini Nano (Android + Chrome), Apple Foundation Models (iOS/macOS) and Windows AI Foundry. See [Built-in AI](/docs/builtin-ai).
- **Pluggable Engines:** Opt-in engine packages — LiteRT-LM, MediaPipe, ONNX Runtime, built-in OS AI — registered via `FlutterEdgeAi.initialize(...)`. See [Packages](/docs/packages).
- **Multimodal Support:** Text + image input with Gemma 4, Gemma3n, FastVLM, Qwen2-VL, SmolVLM2, and LLaVA-OneVision vision models. See [Multimodal](/docs/multimodal).
- **Audio Input:** Record and send audio messages with Gemma 4 and Gemma3n models (Android, iOS device, Desktop).
- **Function Calling:** Let models call external functions and integrate with other services. See [Function Calling](/docs/function-calling).
- **Agent Skills:** Give the model a catalog of `SKILL.md` skills it picks and runs itself — text, JS, native intents, or MCP tools. See [Agent Skills](/docs/agent).
- **Speech & Voice (STT + TTS + voice loop):** Transcribe audio, synthesize speech, and run a full on-device speech-to-speech voice loop (`VoiceSession`) via `flutter_edge_ai_speech` — STT (moonshine/Whisper/Parakeet) + TTS (Matcha/Qwen3/Inflect) today. See [Speech](/docs/speech).
- **Thinking Mode:** View the reasoning process of DeepSeek, Gemma 4, and Qwen3 models. See [Thinking Mode](/docs/thinking-mode).
- **Stop Generation:** Cancel text generation mid-process on Android, iOS, Web, and Desktop.
- **Backend Switching:** Choose CPU or GPU where supported, plus NPU for
  `.litertlm` on supported Qualcomm Snapdragon Android devices and Intel
  LunarLake/PantherLake Windows PCs.
- **LoRA Support:** Efficient fine-tuning and integration of LoRA (Low-Rank Adaptation) weights.
- **Enhanced Downloads:** Smart retry logic with exponential backoff and automatic restart of interrupted downloads.
- **Android Foreground Service:** opt in with `foreground: true` for large downloads to bypass the 9-minute timeout.
- **Text Embeddings & RAG:** Generate vectors with pluggable embedding runtimes,
  then use independent `flutter_edge_ai_rag` indexes with Qdrant or SQLite
  storage. See [Embeddings & RAG](/docs/embeddings-and-rag).
- **Web Persistent Caching:** Models persist across browser restarts using the Cache API (Web only).

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

Through 1.11.3 the packages shipped under the `flutter_gemma*` names; the new names continue the same numbering (the table is in [Migration](/docs/migration)).

## What's new in 1.9

- **`embeddingTokenizers:`** — embedding backends no longer bring a tokenizer. Add `flutter_edge_ai_embeddings` and pass `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` beside `embeddingBackends:`, or the first embedding throws a `StateError`. Breaking for every app that computes embeddings. See [Migration](/docs/migration).
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
**MediaPipe alternative:** on mobile you can install the `.task` build of the
same model instead — drop `fileType` (it defaults to `ModelFileType.task`) and
register `MediaPipeEngine()` from `flutter_edge_ai_mediapipe`. On Web, use the
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

### System Instructions

Control model behavior with a system-level instruction:

```dart
final chat = await model.createChat(
  systemInstruction: 'You are a concise assistant. Always respond in bullet points.',
);
```

**Platform support:**

- **`.litertlm` on every platform, native and web**: passed as a real system turn.
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

To serve several dialogues from one loaded model, do not reload it — open
several sessions instead (next section).

On **web** there is no reuse at all: every `getActiveModel` call closes the
cached model and builds a new one, identical arguments or not. Get the model
once and keep the handle.

<Info>
On native `.litertlm` (except the NPU) a `maxTokens` below 1024 is clamped up to
1024, so the 512 above would not have been honored in any case. See
[Troubleshooting](/docs/troubleshooting).
</Info>

### Concurrent Sessions (`openSession`)

A single loaded model can serve several **independent** dialogues at once.
`openSession()` returns a session with its own conversation history, detached
from the legacy `model.session` singleton; `openChat()` is the same for the
higher-level chat API.

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
`generateResponse()` on a second session while another is still running blocks
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

### Uninstalling

For the **active** embedder / STT / TTS model, one call deletes every file it
owns (e.g. an embedder's model *and* tokenizer) and clears its persisted
identity so it isn't auto-restored on the next launch:

```dart
await FlutterEdgeAi.uninstallEmbedder(); // deletes model + tokenizer, clears identity
await FlutterEdgeAi.uninstallStt();
await FlutterEdgeAi.uninstallTts();
```

To delete an inference model, or any model by filename, use `uninstallModel()`
and clear the active inference identity if you removed the active one:

```dart
// Free in-memory handles first if the model is loaded.
await model.close();

// Delete the files + metadata.
await FlutterEdgeAi.uninstallModel('Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm');

// Clear the persisted "active model" identity so it isn't auto-restored.
await FlutterEdgeAi.clearActiveInferenceIdentity();
```

<Info>
`clearActiveInferenceIdentity()` wipes both the in-memory active spec and the
persisted preference. Pair it with `uninstallModel()` only when the deleted model
was the active one. The `uninstallEmbedder/Stt/Tts` helpers already clear the
identity for you.
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

// Absolute on-device path of an installed file (a URL/OPFS handle on web):
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

// Thinking content (for DeepSeek models)
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
  } else if (response is ThinkingResponse) {
    // Model's reasoning process
    print('Thinking: ${response.content}');
    _showThinkingBubble(response.content);
  }
});
```

- **`TextResponse`** — contains a text token (`response.token`) for regular model output.
- **`FunctionCallResponse`** — contains function name (`response.name`) and arguments (`response.args`). See [Function Calling](/docs/function-calling).
- **`ThinkingResponse`** — contains the model's reasoning process (`response.content`). See [Thinking Mode](/docs/thinking-mode).

## Next Steps

- [Installation](/docs/installation) — per-platform setup and engine registration.
- [Models](/docs/models) — supported models, file formats, and capabilities.
- [Migration](/docs/migration) — upgrade from `flutter_gemma` or Flutter Edge AI 1.x.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-inference`](/docs/package-skills), the skill that teaches it engines, installing a model, sessions and chats, streaming, and the platform setup for all six targets.
