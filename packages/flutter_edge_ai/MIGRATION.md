# Migration guide

## flutter_gemma → flutter_edge_ai (1.11.4)

The project is now **Flutter Edge AI**. Every package moved to a new name; the
code, the platforms and the on-device data are the same.

| Before | After |
|--------|-------|
| `flutter_gemma` | `flutter_edge_ai` 1.11.4 |
| `flutter_gemma_litertlm` | `flutter_edge_ai_litertlm` 1.8.6 |
| `flutter_gemma_mediapipe` | `flutter_edge_ai_mediapipe` 1.0.8 |
| `flutter_gemma_embeddings` | `flutter_edge_ai_embeddings` 2.2.1 |
| `flutter_gemma_rag_sqlite` | `flutter_edge_ai_sqlite` 1.4.0 |
| `flutter_gemma_rag_qdrant` | `flutter_edge_ai_qdrant` 1.3.2 |
| `flutter_gemma_speech` | `flutter_edge_ai_speech` 0.5.2 |
| `flutter_gemma_agent` | `flutter_edge_ai_agent` 0.2.6 |
| `flutter_gemma_builtin_ai` | `flutter_edge_ai_builtin_ai` 0.3.0 |
| `flutter_gemma_onnx` | `flutter_edge_ai_onnx` 0.5.1 |
| `flutter_gemma_diagnostics` | `flutter_edge_ai_diagnostics` 0.1.0 |
| `genkit_flutter_gemma` | `genkit_flutter_edge_ai` 0.6.2 |

The old `flutter_gemma*` packages stay on pub.dev as they are, so an app that
has not moved yet keeps working.

To move:

1. Replace each `flutter_gemma*` dependency in `pubspec.yaml` with its new name
   and the version from the table.
2. Replace `package:flutter_gemma` with `package:flutter_edge_ai` in your
   imports — the same for every other package in the table. A project-wide
   search and replace does it.
3. Run `dart fix --apply` (Flutter 3.44 or newer). It renames `FlutterGemma`,
   `FlutterGemmaPlugin`, `FlutterGemmaDesktop`, `GemmaLogLevel`,
   `FlutterGemmaDiagnostics` and the genkit names to their new spellings. Until
   you run it they still compile as deprecated aliases — the core ones up to
   `flutter_edge_ai` 2.0.0, `FlutterGemmaDiagnostics` up to
   `flutter_edge_ai_diagnostics` 0.2.0, the genkit ones up to
   `genkit_flutter_edge_ai` 0.7.0.

If you installed the agent skills, run `dart run skills@ get --all` again
and delete the old `flutter-gemma-*` skill directories: they still teach the
old names.

What does not change:

- Installed models, the model directory and the Web cache stay where they are,
  so nothing downloads again.
- Existing Qdrant and SQLite vector stores open as before.
- The Android package `dev.flutterberlin.*`, the platform channels and the
  macOS `post_install` snippet in your Podfile are unchanged.

Genkit: model and embedder ids are now `flutter-edge-ai/<name>`, and the
context-window middleware is registered as `flutter-edge-ai-context-window`.
Code that uses `flutterEdgeAi.model(...)` and `trimContext()` picks this up; a
hard-coded `'flutter-gemma/<name>'` string has to change. The old Dart names are
deprecated aliases here too, until `genkit_flutter_edge_ai` 0.7.0.

Move every package at once: an app that keeps a `flutter_gemma_X` next to
`flutter_edge_ai_X` gets the same native libraries and Android classes twice,
and the build fails. An old satellite you did not move (say
`flutter_gemma_speech`) pulls the old engine back in the same way.

`flutter_edge_ai_sqlite` needs Flutter 3.47. An app on Flutter 3.44 that uses
the SQLite store upgrades Flutter first.

## flutter_gemma 0.x → 1.0

1.0 split the monolithic `flutter_gemma` plugin into a small **core** package
plus **opt-in** packages, so your app only ships the native weight it actually
uses. This is the **only breaking change**: you add the packages you need and one
`initialize(...)` call. **Every model / session / chat / embedding / RAG API is
unchanged** — your existing inference code keeps working as-is.

## TL;DR

1. Add the opt-in packages for the formats/features you use (see table below).
2. Call `await FlutterEdgeAi.initialize(inferenceEngines: [...], ...)` once in `main()`,
   passing the engines/backends from the packages you added.
3. Everything else stays the same.

## 1. pubspec.yaml

**Before (0.16.x):**
```yaml
dependencies:
  flutter_gemma: ^0.16.3
```

**After (1.0):**
```yaml
dependencies:
  flutter_edge_ai: ^1.11.4                 # core — always required
  flutter_edge_ai_litertlm: ^1.8.6        # add if you run .litertlm models (also provides LiteRtEmbeddingBackend)
  flutter_edge_ai_mediapipe: ^1.0.8       # add if you run .task / .bin models
  flutter_edge_ai_embeddings: ^2.2.1      # add if you compute embeddings (needs a backend, see above)
  flutter_edge_ai_qdrant: ^1.3.2      # add for native on-device RAG (qdrant)
  flutter_edge_ai_sqlite: ^1.4.0      # add for on-device RAG (sqlite-vec; all platforms incl. web) — needs Flutter 3.47
```

Pick by what you actually used in 0.16.x:

| In 0.16.x you used… | Add in 1.0 |
|---|---|
| `.litertlm` models (Gemma 4, Qwen3, FastVLM, any desktop) | `flutter_edge_ai_litertlm` |
| `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4, …) | `flutter_edge_ai_mediapipe` |
| `generateEmbedding()` / `installEmbedder()` | `flutter_edge_ai_litertlm` (see [Embedder decoupling](#embedder-decoupling-litertlm-150) below) |
| RAG (`addDocument` / `searchSimilar`) on native | `flutter_edge_ai_qdrant` |
| RAG on web | `flutter_edge_ai_sqlite` |

> Not sure which format your models are? Desktop is always `.litertlm`
> (`flutter_edge_ai_litertlm`). On mobile/web check the file extension you install.
> You can add **both** engine packages and let the registry route each model by
> its file type.

> **New opt-in packages since 1.2/1.3** (not migration targets from the 0.16.x
> monolith — they add new capabilities): `flutter_edge_ai_agent` (on-device agent
> skills — SKILL.md + tool-calling loop) and `flutter_edge_ai_builtin_ai` (OS
> system models — Gemini Nano on Android and Web, Apple Foundation Models on
> iOS/macOS, Windows AI Foundry on Windows; a thin adapter over
> `flutter_local_ai`, which owns the native layer).
> Add either only if you want that feature — see the README **Features** list.

## 2. main.dart — the one new call

**Before (0.16.x):** engines were bundled into core; `initialize()` was optional.
```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // (initialize was optional — only for HF token / retries)
  runApp(MyApp());
}
```

**After (1.0):** register the packages you added.
```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    vectorStore: QdrantVectorStore(),          // or WebSqliteVectorStore() on web
    // '' when the define is absent, and an empty token still sends a
    // bare `Authorization: Bearer` header — pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
  );

  runApp(MyApp());
}
```

Only list what you ship. If you don't do embeddings, omit `embeddingBackends`;
if you don't do RAG, omit `vectorStore`.

## 3. Everything else is unchanged

These keep the exact same API — no edits needed:

```dart
// install + run a model
await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(url, token: token).install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat  = await model.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello', isUser: true));
await for (final r in chat.generateChatResponseAsync()) { /* r is a ModelResponse */ }

// embeddings + RAG
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(modelUrl, token: token)
    .tokenizerFromNetwork(tokenizerUrl, token: token)
    .install();
await FlutterEdgeAiPlugin.instance.addDocument(/* ... */);
final hits = await FlutterEdgeAiPlugin.instance.searchSimilar(query: query, topK: 5);
```

## What you'll see if you forget step 2

- Calling `getActiveModel()` with no matching `inferenceEngines` registered throws
  a `StateError` naming the model's `ModelFileType` and the engines that are
  registered — add the engine package for that file type.
- `createEmbeddingModel()` / auto-embedding RAG with no `embeddingBackends` throws
  a clear "add an embedding backend package" error (e.g. `flutter_edge_ai_litertlm`'s
  `LiteRtEmbeddingBackend`).
- RAG calls with no `vectorStore` throw "add a RAG package" (the default store is
  an unconfigured sentinel).

## Platform setup

Native setup moved to the package that owns it:

- **MediaPipe Gradle / Pod deps + the `@mediapipe/tasks-genai` web CDN** are now in
  `flutter_edge_ai_mediapipe` (bundled automatically on Android/iOS; add the CDN
  `<script>` for web — see the main README).
- **The `.litertlm` native library + the `@litert-lm/core` web CDN** are in
  `flutter_edge_ai_litertlm`.
- **The custom `sqlite3.wasm` (with `sqlite-vec`/`vec0` linked in)** ships as a web asset in `flutter_edge_ai_sqlite`.

The iOS/Android entitlements and manifest entries from the main README still
apply when you ship an inference engine. See the
[README Setup section](README.md#setup) for the full list.

## Embedder decoupling (litertlm 1.5.0)

If you were on an earlier 1.x and imported `LiteRtEmbeddingBackend` from
`flutter_gemma_embeddings`, that class moved:

**Before:**
```dart
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
```

**After:**
```dart
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
```

`LiteRtEmbeddingBackend()` itself is unchanged — only the import path moved,
and there is no re-export shim, so it must be updated.

### Register a tokenizer (litertlm 1.8.0 / onnx 0.4.0)

An embedding backend no longer names a tokenizer. Which family a model needs
is a property of the MODEL, not of the engine that runs it — EmbeddingGemma is
SentencePiece whether LiteRT or ONNX Runtime executes its weights — so the app
supplies it, and the engine packages stopped depending on
`flutter_gemma_embeddings` because of it.

**Add the dependency** (it no longer arrives through the engine):
```yaml
dependencies:
  flutter_edge_ai_embeddings: ^2.2.1
```

**Add one line to `initialize`:**
```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],   // new
);
```

Omit it and the first embedding throws a `StateError` naming this step. It
never falls back to a tokenizer of its own choosing: the wrong family produces
vectors that are quietly the wrong point in the embedding space, which no test
downstream can tell from a working model.

An app that never embeds anything passes neither list and can drop
`flutter_edge_ai_embeddings` entirely.

If your app used embeddings **without** also using `.litertlm` inference, add
`flutter_edge_ai_litertlm` to your `pubspec.yaml` — this also delivers the
shared native bundle (`libLiteRtLm`) your app was previously getting
transitively through `flutter_gemma_embeddings`'s old dependency on it.

## Troubleshooting

- **`dlopen` "library not found" after removing a package:** if you had both
  `flutter_edge_ai_litertlm` and `flutter_edge_ai_embeddings` and removed one, run
  `flutter clean` and delete `~/Library/Caches/flutter_gemma/native` (Windows:
  `%LOCALAPPDATA%\flutter_gemma\native`), then `flutter pub get`. They share one
  native library; see those packages' READMEs.
