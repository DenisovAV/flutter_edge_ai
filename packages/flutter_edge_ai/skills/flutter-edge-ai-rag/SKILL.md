---
name: flutter-edge-ai-rag
description: Use when adding or debugging on-device RAG, semantic search, text embeddings, metadata filters, embedding profiles, or pluggable sqlite-vec/qdrant-edge storage in a flutter_edge_ai app.
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

## Packages

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_rag flutter_edge_ai_sqlite
```

For the default core embedder also add its runtime/tokenizer packages, usually
`flutter_edge_ai_litertlm` and `flutter_edge_ai_embeddings`. Replace SQLite
with `flutter_edge_ai_qdrant` for qdrant-edge on native platforms. SQLite runs
on Android, iOS, Web, macOS, Windows, and Linux; qdrant-edge has no Web arm.

## Default active embedder

Initialize only embedding runtime pieces in core. Pin model downloads to an
immutable revision and use a profile ID that describes those exact bytes and
preprocessing:

```dart
import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

const embeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
const revision = '29888fcee3216acadc7e844906e5fe0d79a61875';
const modelBase =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/$revision';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
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
const databasePath = 'knowledge-embeddinggemma-29888fcee321-v1.db';
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

Use an absolute writable path from `getApplicationDocumentsDirectory()` on
native. A bare database name is the Web IndexedDB/VFS location.

## Index and search

```dart
const embeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: 'knowledge-embeddinggemma-29888fcee321-v1.db',
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
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: 'vectors-v1.db',
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

For independent text RAG, implement `RagEmbedder`:

```text
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);
  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> get profile async => const EmbeddingProfile(
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
  spec: VectorStoreSpec(providerId: 'sqlite', location: 'custom-v1.db'),
  embedder: AppEmbedder(model),
);
```

Different indexes may use different embedders. Never mix their vectors in one
location, even when dimensions match.

## Existing stores and lifecycle

A nonempty 1.x store has no profile metadata. Prefer a new profile-versioned
location and re-index. Only when the exact old embedding pipeline is known may
the app open with an explicit profile and
`allowLegacyProfileAdoption: true`; the provider also checks vector dimension.

Make open/dispose app-owned and idempotent:

```dart
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
Future<RagIndex>? opening;
Future<void>? disposing;

opening ??= rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: 'knowledge-v1.db',
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
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: 'knowledge-v1.db',
  ),
  embeddingProfile: EmbeddingProfile(id: 'embedding-pipeline-v1', dimension: 768),
);
await index.dispose();
await FlutterEdgeAi.dispose();
```

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
- A text operation using the default embedder needs an active core embedder and
  a matching `activeEmbedderProfileId`.
