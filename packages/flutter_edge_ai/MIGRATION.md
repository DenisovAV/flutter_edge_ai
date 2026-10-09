# Migration guide

## flutter_edge_ai 2.1.0: `isThinking` is `enableThinking`

A rename with no `dart fix` rule, so the compiler finds every call site:

- `createSession`, `openSession`, `createChat` and `openChat` take
  `enableThinking:` instead of `isThinking:`.
- `ModelRuntimeDefaults.isThinking` is `thinkingDeclared` — what the model's
  manifest declares, which you pass on as
  `enableThinking: r.runtime.thinkingDeclared ?? false`.
- `genkit_flutter_edge_ai` 0.7: the `isThinking` model option is
  `enableThinking`.

Requires `flutter_edge_ai_litertlm` 1.9.0 or later, which sends the flag to the
runtime under the key chat templates read.

## flutter_edge_ai_litertlm 1.10.0: Android NPU is opt-in

Only apps that use `PreferredBackend.npu` on Android need to act. Qualcomm
licenses its QNN runtime for redistribution inside an application only, so the
package no longer ships it and every other Android app is about 83 MB smaller
on the device. An app that wants the Qualcomm NPU asks for it:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

- Put it in the pubspec of the app you build, or in the workspace root's
  pubspec if the app is a pub workspace member; pub reads `user_defines` from
  nowhere else, and the runtime log then says the stack is not enabled.
- The build hook downloads `com.qualcomm.qti:qnn-runtime` from Maven Central
  once per machine and caches it. Offline builds and CI without Maven access set
  `qualcomm_npu_maven_url` to a mirror or `qualcomm_npu_aar` to the AAR itself.
- Setting the flag accepts Qualcomm's AI Stack License. Qualcomm's notices are
  in the package's `NOTICES` and reach your app's licence page on their own.
- Requires `flutter_edge_ai` 2.1.1: core prepares the libraries the NPU
  dispatch loads, now from split APKs as well and off the main thread.

Without the flag nothing fails: `npu` falls back to GPU, then CPU, as on any
device without an NPU.

**Linux arm64 (`flutter_edge_ai_litertlm` 1.11.0).** The same flag also bundles
the Qualcomm NPU stack into Linux arm64 builds — Qualcomm Linux boards such as
the QCS6490, QCS8275 or QCS9075. The hook reads the QNN runtime out of
Qualcomm's public QAIRT SDK zip (about 32 MB of it, by range request);
`qualcomm_npu_qairt_zip` points it at a local copy. On the board the user must
be in group `fastrpc`. A Linux x64 build ignores the flag.

## Flutter Edge AI 1.x → 2.0: RAG leaves core

Flutter Edge AI 2.0 keeps inference, embeddings, speech, installation, and
model lifecycle in `flutter_edge_ai`, but moves RAG orchestration and all
vector-store contracts to `flutter_edge_ai_rag`. RAG is now instance-scoped and
can run with the active core embedder, a custom embedder, or precomputed vectors
without initializing core.

Update dependencies:

```yaml
dependencies:
  flutter_edge_ai: ^2.1.1
  flutter_edge_ai_rag: ^1.0.0
  flutter_edge_ai_sqlite: ^2.0.0 # or flutter_edge_ai_qdrant: ^2.0.0
```

Remove `vectorStore:` and `filterSchema:` from `FlutterEdgeAi.initialize()`.
Register only AI runtimes there:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
```

Then create and own the RAG index independently:

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'category', type: FilterFieldType.string),
    ]),
  ),
  activeEmbedderProfileId:
      'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
      'retrieval-prefix-meanpool-l2-v1',
);

try {
  await index.addText(id: 'doc-1', content: 'Text to retrieve');
  final hits = await index.searchText(query: 'What should I retrieve?');
  await index.flush();
  print(hits);
} finally {
  await index.dispose();
}
```

The old and new calls map as follows:

| 1.x core RAG | 2.0 `RagIndex` |
|---|---|
| `FlutterEdgeAi.rag.initialize(location)` | `FlutterEdgeAiRag(...).open(spec: VectorStoreSpec(location: ...))` |
| `addDocument(...)` | `addText(...)` |
| `addDocumentWithEmbedding(...)` | `addVector(...)` |
| `searchSimilar(query: ...)` | `searchText(query: ...)` |
| low-level vector search | `searchVector(embedding: ...)` |
| `removeDocument(id: ...)` | `remove(id: ...)` |
| `stats()` / `flush()` / `clear()` | same methods on the owned index |
| core/plugin teardown | `RagIndex.dispose()` before core/embedder teardown |

Also breaking in 2.0:

- `Filter`, `FilterSchema`, `RetrievalResult` and `VectorStoreRepository` now
  import from `package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart`.
- `ModelFileManager.setActiveModel` is removed; use `ensureModelReadyFromSpec`.
- The flutter_gemma-era name aliases (`FlutterGemma`, …) are gone;
  `dart fix --apply` still renames them.

### Embedding-profile migration

Every persistent location is now durably bound to an `EmbeddingProfile`. Its
ID must version the weights, tokenizer, pooling, normalization, and
document/query prefix contract; a path or mutable download URL is not a stable
identity. Use a different location after any of those inputs change.

For batch/precomputed vectors, pass both the profile and the matching active
embedder ID if later searches use the active core embedder:

```dart
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embeddingProfile: EmbeddingProfile(
    id: embeddingProfileId,
    dimension: 768,
  ),
  activeEmbedderProfileId: embeddingProfileId,
);
```

This is required when the first operation is `addVector`: a new store cannot
infer which embedding space raw numbers belong to. For a vector-only index,
omit `activeEmbedderProfileId`; for independent text RAG, pass a custom
`RagEmbedder` whose `profile` reports the same stable identity.

A nonempty 1.11 store has no profile metadata. The safest migration is a new,
profile-versioned location plus re-indexing. If you can independently attest
the exact old model and preprocessing, open once with
`VectorStoreSpec(…, allowLegacyProfileAdoption: true)` and the verified
`EmbeddingProfile` passed as `embeddingProfile:` to `rag.open`; the provider
checks the stored vector dimension before persisting the binding.

SQLite filter schemas are part of the physical `vec0` table. Adding or changing
a field requires a new schema-versioned location and re-indexing. Do not open a
database first without a schema and later expect `vec0` to alter it.

On Web, one location may have only one live SQLite index because the provider
holds an exclusive Web Lock. Keep one app-owned `RagIndex`, make its open future
single-flight, and dispose it before reopening the location. Dispose all RAG
indexes before `FlutterEdgeAi.dispose()` or before disposing a custom embedder.

## Historical: flutter_gemma → flutter_edge_ai (1.11.4)

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
2. In your import lines replace `flutter_gemma` with `flutter_edge_ai`
   everywhere it appears — the package and the file name, e.g.
   `package:flutter_gemma/flutter_gemma.dart` →
   `package:flutter_edge_ai/flutter_edge_ai.dart`. Two packages also drop
   `rag_`: `flutter_gemma_rag_sqlite` → `flutter_edge_ai_sqlite` and
   `flutter_gemma_rag_qdrant` → `flutter_edge_ai_qdrant`.
3. Run `dart fix --apply` (Flutter 3.44 or newer). It renames `FlutterGemma`,
   `FlutterGemmaPlugin`, `FlutterGemmaDesktop`, `GemmaLogLevel`,
   `FlutterGemmaDiagnostics` and the genkit names to their new spellings. In 1.11.4
   they still compiled as deprecated aliases; `flutter_edge_ai` 2.0.0,
   `flutter_edge_ai_diagnostics` 0.2.0 and `genkit_flutter_edge_ai` 0.7.0 drop
   the aliases, and `dart fix --apply` renames the old names all the same.

If you installed the agent skills, run `dart run skills@ get --all` again
and delete the old `flutter-gemma-*` skill directories: they still teach the
old names.

What did not change in the 1.11.4 rename itself:

- Installed models, the model directory and the Web cache stay where they are,
  so nothing downloads again.
- Existing Qdrant and SQLite vector stores opened as before in 1.11.4. Moving
  onward to 2.0 requires the embedding-profile migration above.
- The Android package `dev.flutterberlin.*`, the platform channels and the
  macOS `post_install` snippet in your Podfile are unchanged.

Genkit: model and embedder ids are now `flutter-edge-ai/<name>`, and the
context-window middleware is registered as `flutter-edge-ai-context-window`.
Code that uses `flutterEdgeAi.model(...)` and `trimContext()` picks this up; a
hard-coded `'flutter-gemma/<name>'` string has to change. The old Dart names were
deprecated aliases in 0.6.2; 0.7.0 drops them, and `dart fix --apply` renames them.

Move every package at once: an app that keeps a `flutter_gemma_X` next to
`flutter_edge_ai_X` gets the same native libraries and Android classes twice,
and the build fails. An old satellite you did not move (say
`flutter_gemma_speech`) pulls the old engine back in the same way.

`flutter_edge_ai_sqlite` needs Flutter 3.47. An app on Flutter 3.44 that uses
the SQLite store upgrades Flutter first.

## Historical: flutter_gemma 0.x → 1.0

1.0 split the monolithic `flutter_gemma` plugin into a small **core** package
plus **opt-in** packages, so your app only ships the native weight it actually
uses. This is the **only breaking change**: you add the packages you need and one
`initialize(...)` call. The model/session/chat/embedding APIs stayed compatible
in that release; RAG later changed in 2.0 as documented above.

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

**Current equivalents (2.0):**
```yaml
dependencies:
  flutter_edge_ai: ^2.1.1                 # core — always required
  flutter_edge_ai_litertlm: ^1.11.0       # .litertlm + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: ^1.1.1       # .task / .bin
  flutter_edge_ai_embeddings: ^2.2.2      # tokenizer providers
  flutter_edge_ai_rag: ^1.0.0             # RAG orchestration + contracts
  flutter_edge_ai_qdrant: ^2.0.0          # native qdrant provider
  flutter_edge_ai_sqlite: ^2.0.0          # sqlite-vec provider; needs Flutter 3.47
```

Pick by what you actually used in 0.16.x:

| In 0.16.x you used… | Add now |
|---|---|
| `.litertlm` models (Gemma 4, Qwen3, FastVLM, any desktop) | `flutter_edge_ai_litertlm` |
| `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4, …) | `flutter_edge_ai_mediapipe` |
| `generateEmbedding()` / `installEmbedder()` | `flutter_edge_ai_litertlm` + `flutter_edge_ai_embeddings` (tokenizers, required since 1.9; see [Embedder decoupling](#embedder-decoupling-litertlm-150) below) |
| RAG on native | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| RAG on web | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` |

> Not sure which format your models are? Desktop is always `.litertlm`
> (`flutter_edge_ai_litertlm`). On mobile/web check the file extension you install.
> You can add **both** engine packages and let the registry route each model by
> its file type.

> **New opt-in packages since 1.2/1.3** (not migration targets from the 0.16.x
> monolith — they add new capabilities): `flutter_edge_ai_agent` (on-device agent
> skills — SKILL.md + tool-calling loop), `flutter_edge_ai_builtin_ai` (OS
> system models — Gemini Nano on Android and Web, Apple Foundation Models on
> iOS/macOS, Windows AI Foundry on Windows; a thin adapter over
> `flutter_local_ai`, which owns the native layer), `flutter_edge_ai_onnx` (ONNX
> Runtime generation and embeddings) and `flutter_edge_ai_diagnostics` (memory
> a model costs, read from the OS).
> Add any of them only if you want that feature — see the README **Features** list.

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    // '' when the define is absent, and an empty token still sends a
    // bare `Authorization: Bearer` header — pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
  );

  runApp(MyApp());
}
```

Only list the AI runtimes you ship. RAG storage is registered independently on
`FlutterEdgeAiRag`, not on core.

## 3. Everything else is unchanged

These kept the same API through the 1.0 split — no edits needed for it (later
breaking changes, such as `isThinking` → `enableThinking` in 2.1.0 and RAG
moving to `flutter_edge_ai_rag` in 2.0, are covered above):

```dart
// install + run a model
await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(url, token: token).install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat  = await model.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello', isUser: true));
await for (final r in chat.generateChatResponseAsync()) { /* r is a ModelResponse */ }

// embeddings
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(modelUrl, token: token)
    .tokenizerFromNetwork(tokenizerUrl, token: token)
    .install();

// RAG: use the independently owned RagIndex shown in the 2.0 section above.
```

## What you'll see if you forget step 2

- Calling `getActiveModel()` with no matching `inferenceEngines` registered throws
  a `StateError` naming the model's `ModelFileType` and the engines that are
  registered — add the engine package for that file type.
- `FlutterEdgeAi.getActiveEmbedder()` with no `embeddingBackends` throws
  a clear "add an embedding backend package" error (e.g. `flutter_edge_ai_litertlm`'s
  `LiteRtEmbeddingBackend`).
- `FlutterEdgeAiRag.open()` with no matching provider throws and reports the
  registered provider IDs.

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
[README platform setup](README.md#platform-setup) for the full list.

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
  flutter_edge_ai_embeddings: ^2.2.2
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
  `flutter_edge_ai_litertlm` and `flutter_edge_ai_speech` and removed one, run
  `flutter clean` and delete `~/Library/Caches/flutter_gemma/native` (Windows:
  `%LOCALAPPDATA%\flutter_gemma\native`), then `flutter pub get`. They share one
  native library (`flutter_edge_ai_embeddings` 2.x has no native code); see
  those packages' READMEs.
