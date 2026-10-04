---
name: flutter-edge-ai-rag
description: Use when adding or debugging on-device RAG, semantic search, text embeddings, metadata filters, embedding profiles, or pluggable sqlite-vec/qdrant-edge storage in a flutter_edge_ai app with flutter_edge_ai_rag, flutter_edge_ai_sqlite or flutter_edge_ai_qdrant. Also use when moving RAG code to flutter_edge_ai 2.0 — FlutterEdgeAi.rag is undefined, initialize(vectorStore:) was removed, or open() throws "No vector-store provider can handle providerId" — and when QdrantLegacyStoreException or an embedding-profile mismatch is thrown.
---

# On-device RAG with Flutter Edge AI

## Non-negotiable architecture

1. RAG is not initialized by `FlutterEdgeAi.initialize()`. Use the independent
   `flutter_edge_ai_rag` package and an app-owned `FlutterEdgeAiRag` instance.
2. Storage packages are providers: `flutter_edge_ai_sqlite` registers
   `SqliteVectorStoreProvider`; `flutter_edge_ai_qdrant` registers
   `QdrantVectorStoreProvider`. Application code uses `RagIndex`.
3. One persistent location belongs to one stable `EmbeddingProfile`. Its ID
   versions weights, tokenizer, pooling, normalization, and document/query
   prefixes. A mutable URL or file path is not an identity.
4. Keep one live `RagIndex` per location, make opening single-flight, and share
   it across widgets. Web SQLite enforces this with an exclusive Web Lock.
5. Dispose indexes before `FlutterEdgeAi.dispose()` or before disposing a
   custom embedder. An index owns its vector store but only borrows its embedder.
6. Declare every filter field in `VectorStoreSpec.filterSchema` before the
   SQLite index is created. Changing SQLite's physical `vec0` schema requires a
   new schema-versioned location and re-index.
7. `location` is an absolute path on native — a database file for SQLite, a
   directory for Qdrant; build it from `getApplicationDocumentsDirectory()` —
   and a plain name on Web.

## Packages

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_rag flutter_edge_ai_sqlite path path_provider
```

For the default core embedder also add its runtime/tokenizer packages, usually
`flutter_edge_ai_litertlm` and `flutter_edge_ai_embeddings`. Replace SQLite
with `flutter_edge_ai_qdrant` for qdrant-edge on native platforms. SQLite runs
on Android, iOS, Web, macOS, Windows, and Linux; qdrant-edge has no Web arm.

`flutter_edge_ai_sqlite` needs Flutter 3.47 or newer. On older Flutter use
`flutter_edge_ai_qdrant` (native only) or upgrade Flutter.

## Default active embedder

Initialize only embedding runtime pieces in core. Pin model downloads to an
immutable revision and use a profile ID that describes those exact bytes and
preprocessing:

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const embeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
const revision = '29888fcee3216acadc7e844906e5fe0d79a61875';
const modelBase =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/$revision';
// EmbeddingGemma is gated: build with --dart-define=HUGGINGFACE_TOKEN=hf_...
const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  huggingFaceToken: hfToken.isEmpty ? null : hfToken,
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      '$modelBase/embeddinggemma-300M_seq256_mixed-precision.tflite',
    )
    .tokenizerFromNetwork('$modelBase/sentencepiece.model')
    .install();
await FlutterEdgeAi.getActiveEmbedder();

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
// Native: an absolute path to the database file. Web: a plain name.
const databaseName = 'knowledge-embeddinggemma-29888fcee321-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'lang', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
    ]),
  ),
  activeEmbedderProfileId: embeddingProfileId,
);
```

The EmbeddingGemma repo is gated: the Hugging Face account behind the token
must accept the Gemma license on the model page, or the download is refused.
Keep the token out of source — it is compiled into the app, so a shipped app
should download from a repo that needs none.

`open()` pins the embedder that is active at that moment: install the embedder
before opening the index, and after switching embedders open a new index at a
new location.

## Index and search

```dart
const embeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
const databaseName = 'knowledge-embeddinggemma-29888fcee321-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'lang', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
    ]),
  ),
  activeEmbedderProfileId: embeddingProfileId,
);
await index.addText(
  id: 'doc-1',
  content: chunk,
  metadata: jsonEncode({'lang': 'en', 'year': 2024}),
);

final hits = await index.searchText(
  query: question,
  topK: 5,
  threshold: 0.3,
  filter: Filter(
    must: [FieldEquals(key: 'lang', value: 'en')],
    mustNot: [FieldRange(key: 'year', lte: 2010)],
  ),
);

await index.flush();
```

`addText` uses the document embedding path; `searchText` uses the query path.
For precomputed batches, generate with `TaskType.retrievalDocument`, then use
`addVector`. Use `searchVector` for precomputed queries. `remove`, `stats`,
`clear`, and `flush` operate on the owned index. Flush after a write batch:
it is required for qdrant durability, a Web SQLite durability fence, and a
no-op on native SQLite.

## Vector-only and custom embedders

RAG can run without `FlutterEdgeAi.initialize()`.

For vector-only use, bind the new store explicitly and call only vector APIs:

```dart
const databaseName = 'vectors-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embeddingProfile: EmbeddingProfile(
    id: 'my-precomputed-embedding-pipeline-v1',
    dimension: 768,
  ),
);
final vector = List<double>.filled(768, 0);
final queryVector = List<double>.filled(768, 0);
await index.addVector(id: 'doc-1', content: chunk, embedding: vector);
final hits = await index.searchVector(embedding: queryVector);
```

For independent text RAG, implement `RagEmbedder`. `EmbeddingProfile` has no
`const` constructor — it validates its arguments:

```text
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);
  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> get profile async => EmbeddingProfile(
    id: 'my-model-tokenizer-pooling-prefix-v1',
    dimension: 384,
  );

  @override
  Future<List<double>> embedDocument(String text) =>
      model.embed('document: $text');

  @override
  Future<List<double>> embedQuery(String text) => model.embed('query: $text');
}

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: customDatabasePath, // absolute path on native, a name on Web
  ),
  embedder: AppEmbedder(model),
);
```

Different indexes may use different embedders. Never mix their vectors in one
location, even when dimensions match.

## qdrant-edge storage (native only)

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

const embeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
final rag = FlutterEdgeAiRag(
  providers: const [QdrantVectorStoreProvider()],
);
// A directory, not a file — qdrant creates its shard files inside it.
final storeDirectory = p.join(
  (await getApplicationDocumentsDirectory()).path,
  'knowledge-qdrant-embeddinggemma-29888fcee321-v1',
);
try {
  final index = await rag.open(
    spec: VectorStoreSpec(providerId: 'qdrant', location: storeDirectory),
    activeEmbedderProfileId: embeddingProfileId,
  );
} on QdrantLegacyStoreException catch (e) {
  // Written by flutter_gemma_rag_qdrant 1.2 or earlier: not readable.
  // e.message names the files to delete; delete them, then re-index.
  print(e.message);
}
```

`QdrantVectorStoreProvider` has no static providerId constant: pass the string
`'qdrant'`. Keep the directory apart from any SQLite database. A store written
by `flutter_gemma_rag_qdrant` 1.2 or earlier makes `open()` throw
`QdrantLegacyStoreException`: its format cannot be read or adopted, so delete
the files its message names and re-index. Catch that type, not the base
`VectorStoreException` — the base type also covers a shard that is only locked
by another open store. The legacy-adoption path below applies to profile-less
qdrant stores written by 1.3.x.

## Existing stores and lifecycle

A nonempty 1.x store has no profile metadata. Prefer a new profile-versioned
location and re-index. Only when the exact old embedding pipeline is known may
the app open it with an explicit `embeddingProfile` and
`allowLegacyProfileAdoption: true`. That flag is a `VectorStoreSpec` field, not
an `open()` argument; the provider also checks vector dimension:

```dart
const oldDatabaseName = 'rag.db'; // the location the 1.x app already used
final databasePath = kIsWeb
    ? oldDatabaseName
    : p.join((await getApplicationDocumentsDirectory()).path, oldDatabaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    allowLegacyProfileAdoption: true,
  ),
  embeddingProfile: EmbeddingProfile(
    id: 'the-verified-old-embedding-pipeline-v1',
    dimension: 768,
  ),
);
```

Make open/dispose app-owned and idempotent:

```dart
const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
Future<RagIndex>? opening;
Future<void>? disposing;

opening ??= rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embeddingProfile: EmbeddingProfile(id: 'embedding-pipeline-v1', dimension: 768),
);
disposing ??= () async {
  final pending = opening;
  if (pending != null) await (await pending).dispose();
}();
await disposing;
```

Do not create an index in each widget or reopen the same Web location while a
previous index is live. Shutdown order is:

```dart
const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embeddingProfile: EmbeddingProfile(id: 'embedding-pipeline-v1', dimension: 768),
);
await index.dispose();
await FlutterEdgeAi.dispose();
```

## Moving from 1.x core RAG to 2.0

In flutter_edge_ai 2.0 RAG left core: the `FlutterEdgeAi.rag.…` calls and the
`vectorStore:` and `filterSchema:` parameters of `FlutterEdgeAi.initialize()`
are gone. Add `flutter_edge_ai_rag` and a storage package, remove those two
parameters, and open a `RagIndex`:

| 1.x (`FlutterEdgeAi.rag.…`) | 2.0 `RagIndex` |
| --- | --- |
| `initialize(vectorStore: ...)` on core | `FlutterEdgeAiRag(providers: [...])` |
| `rag.initialize(location)` | `rag.open(spec: VectorStoreSpec(...))` |
| `addDocument(...)` | `addText(...)` |
| `addDocumentWithEmbedding(...)` | `addVector(...)` |
| `searchSimilar(query: ...)` | `searchText(query: ...)` |
| `removeDocument(id: ...)` | `remove(id: ...)` |
| `stats()` / `flush()` / `clear()` | the same methods on the index |

`No vector-store provider can handle providerId "…"` means the provider for
that ID was not passed to `FlutterEdgeAiRag(providers: ...)`, or cannot run on
this platform (qdrant on Web). A nonempty store written by 1.x is usable only
through the legacy-adoption path above, or after re-indexing into a new
location.

## Web assets and common failures

- Copy `web/rag/sqlite3.wasm` from `flutter_edge_ai_sqlite` to the same path in
  the app. Copy the four matching LiteRT embedding files from
  `flutter_edge_ai_litertlm/web/` when that runtime is used.
- A filter with no effect usually names a field omitted from `filterSchema`.
  SQLite names must match `^[A-Za-z][A-Za-z0-9_]*$` and avoid reserved columns.
- A profile mismatch means model/preprocessing bytes changed or the wrong
  location was opened. Do not bypass it; choose the correct profile/location.
- A first `addVector` on an empty store needs `embeddingProfile`; raw numbers
  cannot identify their embedding space.
- A text operation using the default embedder needs `activeEmbedderProfileId`
  on `open()`. `open()` pins the embedder that is active at that moment:
  install the embedder before opening the index, and after switching embedders
  open a new index at a new location.
