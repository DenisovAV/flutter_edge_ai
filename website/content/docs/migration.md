---
title: Migration
description: Upgrade to Flutter Edge AI 2.1 (enableThinking, opt-in Qualcomm NPU) and 2.0 (RAG moves to flutter_edge_ai_rag), move from flutter_gemma to flutter_edge_ai, and from the 0.16.x monolith to the modular packages.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

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
on the device. An app that wants the Qualcomm NPU asks for it in its
`pubspec.yaml` (the workspace root's, if the app is a pub workspace member):

```
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

The build hook downloads `com.qualcomm.qti:qnn-runtime` from Maven Central once
per machine and caches it; offline builds set `qualcomm_npu_maven_url` to a
mirror or `qualcomm_npu_aar` to the AAR itself. Setting the flag accepts
Qualcomm's AI Stack License. It needs `flutter_edge_ai` 2.1.1. Without the flag
nothing fails: `npu` falls back to GPU, then CPU. See [LiteRT-LM](/docs/litertlm).

**Linux arm64 (`flutter_edge_ai_litertlm` 1.11.0).** The same flag also bundles
the Qualcomm NPU stack into Linux arm64 builds — Qualcomm Linux boards such as
the QCS6490, QCS8275 or QCS9075. The hook reads the QNN runtime out of
Qualcomm's public QAIRT SDK zip (about 32 MB of it, by range request);
`qualcomm_npu_qairt_zip` points it at a local copy. On the board the user must
be in group `fastrpc`. A Linux x64 build ignores the flag.

## Flutter Edge AI 1.x → 2.0: RAG leaves core

Flutter Edge AI 2.0 keeps inference, embeddings, speech, installation, and
model lifecycle in `flutter_edge_ai`, but moves RAG orchestration and all
vector-store contracts to `flutter_edge_ai_rag`. RAG is instance-scoped and can
use the active core embedder, a custom embedder, or precomputed vectors without
initializing core.

```
dependencies:
  flutter_edge_ai: ^2.1.1
  flutter_edge_ai_rag: ^1.0.0
  flutter_edge_ai_sqlite: ^2.0.0 # or flutter_edge_ai_qdrant: ^2.0.0
```

Also breaking in 2.0:

- `Filter`, `FilterSchema`, `RetrievalResult`, `VectorStoreRepository` and the
  other RAG types now import from `package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart`,
  not from core.
- `ModelFileManager.setActiveModel` is removed — use `ensureModelReadyFromSpec`.
- The deprecated `flutter_gemma` name aliases (`FlutterGemma`, `GemmaLogLevel`, …)
  are removed. `dart fix --apply` still renames them.

Remove `vectorStore:` and `filterSchema:` from `FlutterEdgeAi.initialize()`.
Register only AI runtimes there, then create and own RAG independently:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);

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

### Embedding profiles and persistent data

Every persistent location is durably bound to an `EmbeddingProfile`. Its ID
must version the weights, tokenizer, pooling, normalization, and document/query
prefix contract. For batch/precomputed vectors, pass an explicit profile; if
later text searches borrow the active core embedder, also pass the same ID as
`activeEmbedderProfileId`. A vector-only index omits it. Independent text RAG
passes a custom `RagEmbedder` whose `profile` reports that stable identity.

A nonempty 1.11 store has no profile metadata. Prefer a new, profile-versioned
location and re-index. If you can independently attest the old model and
preprocessing, open once with `allowLegacyProfileAdoption: true` on the
`VectorStoreSpec` and the verified `embeddingProfile`; the provider checks the
stored dimension before binding it.

SQLite filter fields are physical `vec0` columns, so a schema change needs a
new schema-versioned location and re-index. On Web, keep one app-owned index per
location because SQLite holds an exclusive Web Lock. Dispose RAG indexes before
`FlutterEdgeAi.dispose()` or before disposing a custom embedder.

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
2. In your import lines, replace `flutter_gemma_rag_` with `flutter_edge_ai_`
   first (`flutter_gemma_rag_sqlite` → `flutter_edge_ai_sqlite`,
   `flutter_gemma_rag_qdrant` → `flutter_edge_ai_qdrant`), then `flutter_gemma`
   with `flutter_edge_ai` everywhere — in the package name and in the file name:
   `package:flutter_gemma/flutter_gemma.dart` becomes
   `package:flutter_edge_ai/flutter_edge_ai.dart`. A project-wide search and
   replace does it.
3. Run `dart fix --apply` (Flutter 3.44 or newer). It renames `FlutterGemma`,
   `FlutterGemmaPlugin`, `FlutterGemmaDesktop`, `GemmaLogLevel`,
   `FlutterGemmaDiagnostics` and the genkit names to their new spellings. In 1.11.4
   they still compiled as deprecated aliases; `flutter_edge_ai` 2.0.0,
   `flutter_edge_ai_diagnostics` 0.2.0 and `genkit_flutter_edge_ai` 0.7.0 drop
   the aliases, and `dart fix --apply` renames the old names all the same.

If you installed the agent skills, run `dart run skills@ get --all` again
and delete the old `flutter-gemma-*` skill directories: they still teach the
old names.

What does not change:

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
`initialize(...)` call. Model/session/chat/embedding APIs stayed compatible in
that release; RAG later changed in 2.0 as documented above.

## TL;DR

1. Add the opt-in packages for the formats/features you use (see table below).
2. Call `await FlutterEdgeAi.initialize(inferenceEngines: [...], ...)` once in `main()`, passing the engines/backends from the packages you added.
3. Everything else stays the same.

## 1. pubspec.yaml

**Before (0.16.x):**

```
dependencies:
  flutter_gemma: ^0.16.3
```

**After (current 2.0 set):**

```
dependencies:
  flutter_edge_ai: ^2.1.1                 # core — always required
  flutter_edge_ai_litertlm: ^1.11.0        # add if you run .litertlm models (also provides LiteRtEmbeddingBackend)
  flutter_edge_ai_mediapipe: ^1.1.1       # add if you run .task / .bin models
  flutter_edge_ai_embeddings: ^2.2.2      # add if you compute embeddings (tokenizers; needs a backend, see above)
  flutter_edge_ai_rag: ^1.0.0             # add for on-device RAG (RagIndex) + one store below
  flutter_edge_ai_qdrant: ^2.0.0          # native on-device RAG store (qdrant)
  flutter_edge_ai_sqlite: ^2.0.0          # RAG store (sqlite-vec; all platforms incl. web) — needs Flutter 3.47
```

Pick by what you actually used in 0.16.x:

| In 0.16.x you used… | Add |
|---|---|
| `.litertlm` models (Gemma 4, Qwen3, FastVLM, any desktop) | `flutter_edge_ai_litertlm` |
| `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4, …) | `flutter_edge_ai_mediapipe` |
| `generateEmbedding()` / `installEmbedder()` | `flutter_edge_ai_embeddings` + `flutter_edge_ai_litertlm` (`LiteRtEmbeddingBackend`) |
| RAG (`addDocument` / `searchSimilar`), fastest on native | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| RAG on web (or a portable store on any platform) | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` |

<Info>

Not sure which format your models are? In 0.16.x desktop was always `.litertlm`
(`flutter_edge_ai_litertlm`). On mobile/web check the file extension you install.
You can add **both** engine packages and let the registry route each model by its
file type.

</Info>

> **New opt-in packages since 1.2** (not migration targets from the 0.16.x
> monolith — they add new capabilities): `flutter_edge_ai_agent` (on-device agent
> skills — SKILL.md + tool-calling loop), `flutter_edge_ai_builtin_ai` (OS
> system models — Gemini Nano on Android and Web, Apple Foundation Models on
> iOS/macOS, Windows AI Foundry on Windows), `flutter_edge_ai_speech` (STT, TTS
> and a voice loop), `flutter_edge_ai_diagnostics` (memory a model costs, read
> from the OS),
> and `flutter_edge_ai_onnx` (ONNX Runtime — ORT-GenAI text generation +
> plain-ORT embeddings via `dart:ffi` on native, + Web via Transformers.js /
> onnxruntime-web). Add any of them only if you want that feature. See
> [Getting Started](/docs/getting-started).

## Breaking: embeddings 2.0.0 — `LiteRtEmbeddingBackend` moved

<Warning>

`flutter_gemma_embeddings` **2.0.0** is a breaking change, independent of the
0.16.x → 1.0 migration above. As of `flutter_gemma_litertlm` **1.5.0**,
`flutter_gemma_embeddings` no longer ships a concrete embedding backend —
`LiteRtEmbeddingBackend` moved to `flutter_edge_ai_litertlm`. Since 2.2.0 the
package holds only the embedding tokenizer implementations; the pipeline,
pooling and isolate worker live in core.

</Warning>

If your app registers `LiteRtEmbeddingBackend()`, fix the import and bump both
dependencies:

```dart
// Before (< 2.0.0):
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';

// After (>= 2.0.0):
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
```

```
dependencies:
  flutter_edge_ai_embeddings: ^2.2.2   # tokenizer implementations (still required)
  flutter_edge_ai_litertlm: ^1.11.0     # now provides LiteRtEmbeddingBackend
```

`LiteRtEmbeddingBackend()` itself is unchanged — only where the class is
imported from. Since litertlm 1.8.0 it also needs a tokenizer registered
beside it: add `flutter_edge_ai_embeddings` to your pubspec and pass
`embeddingTokenizers: [GemmaEmbeddingTokenizers()]`, or the first embedding
throws a `StateError` naming that step. You still depend on
`flutter_edge_ai_embeddings` (it owns the tokenizers); you just no longer import
a backend class from it. If you'd rather run embeddings over an
ONNX/ORT model instead, `flutter_edge_ai_onnx`'s `OnnxEmbeddingBackend` is a
drop-in alternative — see [Packages](/docs/packages#onnx-runtime-engine).

## Breaking: builtin_ai 0.3.0 — the native layer moved to `flutter_local_ai`

<Warning>

`flutter_edge_ai_builtin_ai` **0.3.0** (and `flutter_gemma_builtin_ai` 0.3.0 before
it) is no longer a Flutter plugin. It ships no
Kotlin/Swift/C++ and no pigeon; every OS backend now comes from
[`flutter_local_ai`](https://pub.dev/packages/flutter_local_ai), which it depends
on. **No Dart code changes** — `BuiltInAi`, `BuiltInAiEngine`,
`BuiltInAiModels`, `BuiltInAiAvailability`, `BuiltInAiUnavailableException` and
`BuiltInAiHuggingFaceResolver` keep their names and signatures — but three
build-level things move.

</Warning>

1. **`pub get` regenerates the plugin registrants and `Podfile.lock`**: this
   package leaves them, `flutter_local_ai` enters. CI that runs a frozen
   `pod install --deployment` fails until you re-commit the lockfile.
2. **The macOS deployment floor rises from 10.15 to 12.0.** A macOS 11 target
   fails resolution with a message naming the `flutter_local_ai` pod, not the
   package you added. iOS is unaffected — `flutter_local_ai` builds from 13.0 and
   core `flutter_edge_ai` still requires 15.0.
3. **`package:flutter_gemma_builtin_ai/pigeon.g.dart` is gone** with the channel
   it wrapped. It was generated plumbing that the documented API never used.

In exchange, **Windows joins the supported platforms** (AI Foundry / Phi Silica),
and `BuiltInAiModels` gains `windowsAiFoundry`, `chromePromptApi`, `all` and
`forCurrentPlatform`. Requesting vision on a backend that has none now throws at
model creation instead of dropping images mid-conversation. See [Built-in
AI](/docs/builtin-ai).

## Breaking: rag_sqlite 1.1.0 — the index does not carry over

<Warning>

`flutter_gemma_rag_sqlite` **1.1.0** replaced the Dart brute-force/HNSW store
with in-SQLite `vec0` KNN, and with it the table the index lives in:
`documents` became `vec_documents`. **An index written by 1.0.x is not read by
1.1.0+.** This shipped as a minor version with no note — if you upgraded and
your RAG answers went vague, this is why.

</Warning>

Nothing errors. `initialize()` succeeds, `getStats()` reports **0 documents**,
`searchSimilar()` returns **no hits**, and your rows are still sitting in the
old `documents` table, unread. The model then answers without the context it
used to have, which reads as the model getting worse rather than as a
migration you missed.

**Your data is recoverable.** Unlike the qdrant break below, nothing is lost:
1.0.x stored `id`, `content`, the `embedding` as a `Float32` BLOB and
`metadata` in a plain table, all still readable. Move it once at startup — no
re-embedding, no model needed:

Before copying anything, identify the exact embedder that produced the old
vectors. The profile ID must version its weights, tokenizer, pooling,
normalization, and document/query prefixes; the dimension must equal that
embedder's output dimension. Do not infer identity from the database path or
reuse the example values below without verifying them.

```dart
import 'dart:typed_data';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';   // add sqlite3 to your own pubspec

final documentsDirectory = await getApplicationDocumentsDirectory();
final databasePath = '${documentsDirectory.path}/rag.db';

// This example is exact only for the pinned EmbeddingGemma pipeline named
// here. Replace both constants if another embedder produced the legacy rows.
const sourceEmbeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
const sourceEmbeddingDimension = 768;
final sourceEmbeddingProfile = EmbeddingProfile(
  id: sourceEmbeddingProfileId,
  dimension: sourceEmbeddingDimension,
);

final store = SqliteVectorStore();
await store.initialize(databasePath);

final db = sqlite3.open(databasePath);
try {
  final hasLegacy = db
      .select("SELECT name FROM sqlite_master "
              "WHERE type='table' AND name='documents'")
      .isNotEmpty;

  if (hasLegacy) {
    final legacyRows = db.select(
      'SELECT id, content, embedding, metadata FROM documents',
    );
    if (legacyRows.isNotEmpty) {
      final firstEmbedding = legacyRows.first['embedding'] as Uint8List;
      final storedDimension = firstEmbedding.lengthInBytes ~/ 4;
      if (firstEmbedding.lengthInBytes % 4 != 0 ||
          storedDimension != sourceEmbeddingDimension) {
        throw StateError(
          'Legacy vectors do not match $sourceEmbeddingProfile',
        );
      }
      // Bind the verified space before the first addDocument call.
      await store.bindEmbeddingProfile(sourceEmbeddingProfile);
    }

    for (final row in legacyRows) {
      // 1.0.x wrote each element with setFloat32(..., Endian.little); read it
      // back the same way. ByteData.sublistView needs no 4-byte alignment,
      // which a raw asFloat32List view of the BLOB would.
      final bytes = ByteData.sublistView(row['embedding'] as Uint8List);
      if (bytes.lengthInBytes % 4 != 0 ||
          bytes.lengthInBytes ~/ 4 != sourceEmbeddingDimension) {
        throw StateError('Legacy row ${row['id']} has the wrong dimension');
      }
      await store.addDocument(
        id: row['id'] as String,
        content: row['content'] as String,
        embedding: List<double>.generate(
          bytes.lengthInBytes ~/ 4,
          (i) => bytes.getFloat32(i * 4, Endian.little),
        ),
        metadata: row['metadata'] as String?,
      );
    }
    db.execute('DROP TABLE documents');   // only after the loop succeeds
  }
} finally {
  db.close();
  await store.close();
}
```

Guard it with your own "already migrated" flag if you prefer, but the
`sqlite_master` check is enough: dropping the table is what makes the block a
no-op on every later launch.

There is no built-in migration call — this is a one-time fix for an upgrade
that has already happened, not an ongoing API.

## Breaking: rag_qdrant 1.3.0 — the on-disk store is not readable

<Warning>

`flutter_gemma_rag_qdrant` **1.3.0** moves onto the official `qdrant_edge`
UniFFI SDK, and **an index written by 1.2 or earlier cannot be read**. This is a
data change, not an API change: your `addDocument` / `searchSimilar` calls are
unchanged, but the documents already on the device are not.

</Warning>

An upgraded app finds no documents where its corpus used to be. 1.3.0 refuses
loudly rather than starting empty — `initialize()` throws a
`QdrantLegacyStoreException` naming the old store — so this shows up the first
time the store opens, not as silently unanswered questions later.

Remove the old store's files once, then re-index. 1.3.0 will not do it for you:
it never deletes data it cannot read, and the three entries a 1.x shard owns
(`edge_config.json`, `wal/`, `segments/`) may sit beside files of your own.

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

final store = QdrantVectorStore();
try {
  await store.initialize(path);
} on QdrantLegacyStoreException catch (e) {
  // e.message names the three entries a 1.x shard owns. Remove them with the
  // file APIs you already use for `path`, then initialize() again.
  rethrow;
}
// ...then re-add your documents, and flush() — on qdrant, points live in the
// shard's in-RAM segment until then, so a background kill loses the re-index.
```

<Warning>

Catch `QdrantLegacyStoreException`, not the base `VectorStoreException`.
`initialize()` also throws the base type when a current-layout (1.3.0 and later)
shard is present but will not open right now — a WAL held by another store, a
permission problem — and
treating that as "the old format is here" is how a recovery step can act on a
store that is perfectly fine.

</Warning>

`clear()` no longer deletes anything: it empties the shard in place, and it
refuses when a 1.x layout is present rather than removing files it cannot
read.

If your app has no re-indexing path of its own, do the re-index behind the same
progress UI you use for the first run — from the user's side this is a rebuild
of the index, not a migration they can be asked to wait through silently.

## 2. main.dart — current 2.0 composition

**Before (0.16.x):** engines were bundled into core; `initialize()` was optional.

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // (initialize was optional — only for HF token / retries)
  runApp(MyApp());
}
```

**Current (2.0):** register only AI runtimes with core. Construct RAG with its
own provider registry and own the returned index separately.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()], // flutter_edge_ai_litertlm
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
    // '' when the define is absent — an empty token still sends a bare
    // `Authorization: Bearer` header, so pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
  );

  final rag = FlutterEdgeAiRag(
    providers: const [QdrantVectorStoreProvider()],
  );
  final index = await rag.open(
    spec: VectorStoreSpec(
      providerId: 'qdrant',
      location: ragDirectory,
    ),
    activeEmbedderProfileId:
        'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
        'retrieval-prefix-meanpool-l2-v1',
  );

  runApp(MyApp(ragIndex: index));
}
```

Only list what you ship. If you don't do embeddings, omit `embeddingBackends`; if
you don't do RAG, do not create an index. A vector-only or custom-embedder RAG
pipeline can run without initializing core at all. Dispose every `RagIndex`
before `FlutterEdgeAi.dispose()` or before disposing its custom embedder.

## 3. Model/chat stays compatible; RAG uses `RagIndex`

Model, session, chat, and embedding installation calls keep their API. Replace
the removed singleton RAG facade with calls on the app-owned index:

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
await index.addText(id: 'doc-1', content: document);
await index.flush(); // required for qdrant; Web SQLite durability fence
final hits = await index.searchText(query: query, topK: 5);

// Shutdown order: the index borrows its embedder.
await index.dispose();
await FlutterEdgeAi.dispose();
```

## What you'll see if you forget step 2

- Calling `getActiveModel()` with no matching `inferenceEngines` registered throws a `StateError` naming the model's `ModelFileType` and the engines that are registered — add the engine package for that file type.
- `FlutterEdgeAi.getActiveEmbedder()` or default text RAG with no matching
  `embeddingBackends` throws a clear error naming the runtime package to add.
- `FlutterEdgeAiRag.open()` with no matching registered provider throws and
  lists the registered provider IDs. Text RAG with the default active embedder
  also requires a stable `activeEmbedderProfileId`; raw vectors require an
  explicit `embeddingProfile` when a new location is created.

## Platform setup

Native setup moved to the package that owns it:

- **MediaPipe Gradle / Pod deps + the `@mediapipe/tasks-genai` web CDN** are now in `flutter_edge_ai_mediapipe` (bundled automatically on Android/iOS; add the CDN `<script>` for web).
- **The `.litertlm` native library + the `@litert-lm/core` web CDN** are in `flutter_edge_ai_litertlm`.
- **The sqlite-vec web loader** (`sqlite3.wasm` with `sqlite-vec` statically linked) is in `flutter_edge_ai_sqlite`.

The iOS/Android entitlements and manifest entries still apply when you ship an
inference engine. See the full [Installation guide](/docs/installation).

## Troubleshooting

**`dlopen` "library not found" after upgrading from `flutter_gemma_*`:** run
`flutter clean` and delete `~/Library/Caches/flutter_gemma/native` (Linux:
`~/.cache/flutter_gemma/native`, Windows: `%LOCALAPPDATA%\flutter_gemma\native`),
then `flutter pub get`.
`flutter_edge_ai_litertlm` owns the native LiteRT library;
`flutter_edge_ai_speech` consumes it transitively — it has no Native-Assets hook
of its own. `flutter_edge_ai_embeddings` has no native code at all.
