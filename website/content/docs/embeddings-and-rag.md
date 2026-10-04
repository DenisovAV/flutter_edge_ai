---
title: Embeddings & RAG
description: Generate embeddings and build profile-safe on-device RAG with pluggable SQLite or Qdrant storage.
image: https://flutteredge.ai/images/og-image.png
---

Flutter Edge AI separates three concerns:

- **flutter_edge_ai** installs and runs embedding models.
- **flutter_edge_ai_rag** owns instance-scoped retrieval orchestration, stable
  embedding profiles, filters, and **RagIndex**.
- **flutter_edge_ai_sqlite** and **flutter_edge_ai_qdrant** provide
  interchangeable vector stores.

RAG can borrow the active core embedder, use an application-provided
**RagEmbedder**, or run entirely on precomputed vectors. It does not require an
inference model and is not initialized through **FlutterEdgeAi.initialize()**.

## Packages

```
dependencies:
  flutter_edge_ai: ^1.12.0
  flutter_edge_ai_litertlm: ^1.8.7
  flutter_edge_ai_embeddings: ^2.2.2
  flutter_edge_ai_rag: ^1.0.0
  flutter_edge_ai_sqlite: ^1.5.0 # all six platforms, including Web
  # flutter_edge_ai_qdrant: ^1.4.0 # native alternative
```

Initialize only the embedding runtime in core:

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
```

The LiteRT backend runs EmbeddingGemma and Gecko. ONNX models use
**OnnxEmbeddingBackend** from **flutter_edge_ai_onnx**. Dimensions are
model-dependent: LiteRT EmbeddingGemma/Gecko produce 768-dimensional vectors;
all-MiniLM-L6-v2 produces 384. A number such as 256 in an artifact name is the
maximum input sequence length, not the vector dimension.

## Install an embedding model

Pin both files to an immutable revision. The stable profile used by the vector
store must describe the exact weights, tokenizer, pooling, normalization, and
document/query prefix contract.

```dart
const revision = '29888fcee3216acadc7e844906e5fe0d79a61875';
const profileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/$revision/embeddinggemma-300M_seq256_mixed-precision.tflite',
    )
    .tokenizerFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/$revision/sentencepiece.model',
    )
    .install();
```

On native, current LiteRT and ONNX embedding paths run on CPU. On Web they try
WebGPU and can fall back to WASM. **preferredBackend** is accepted by
**getActiveEmbedder** for API symmetry but is not applied; inspect
**EmbeddingModel.activeBackend** when the selected backend matters.

## RAG with the active core embedder

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
    filterSchema: const FilterSchema(fields: [
      FilterField(name: 'category', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
      FilterField(name: 'archived', type: FilterFieldType.bool),
    ]),
  ),
  activeEmbedderProfileId: profileId,
);

await index.addText(
  id: 'doc-1',
  content: 'Flutter runs on six platforms.',
  metadata: '{"category":"flutter","year":2026,"archived":false}',
);

final hits = await index.searchText(
  query: 'Where does Flutter run?',
  topK: 5,
  threshold: 0.3,
  filter: const Filter(
    must: [FieldEquals(key: 'category', value: 'flutter')],
    mustNot: [FieldEquals(key: 'archived', value: true)],
  ),
);

await index.flush();
```

The default adapter resolves **FlutterEdgeAi.getActiveEmbedder()** lazily and
borrows the returned model; it never closes core-owned state. The explicit
profile ID prevents vectors created by different model bytes or preprocessing
from being mixed after an app restart.

## Batch or vector-only RAG

When the first write is a precomputed vector, bind the profile at open time.
Pass the matching **activeEmbedderProfileId** too if later text searches should
borrow the active core embedder.

```dart
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embeddingProfile: EmbeddingProfile(id: profileId, dimension: 768),
  activeEmbedderProfileId: profileId,
);

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vectors = await embedder.generateEmbeddings(
  documents,
  taskType: TaskType.retrievalDocument,
);
for (var i = 0; i < documents.length; i++) {
  await index.addVector(
    id: 'doc-$i',
    content: documents[i],
    embedding: vectors[i],
  );
}

final queryVector = await embedder.generateEmbedding(
  'search text',
  taskType: TaskType.retrievalQuery,
);
final hits = await index.searchVector(embedding: queryVector);
```

A purely vector-based app can omit **activeEmbedderProfileId** and never
initialize Flutter Edge AI.

## Independent text RAG

Implement **RagEmbedder** when retrieval has its own embedding lifecycle:

```dart
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);

  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> get profile async =>
      EmbeddingProfile(id: 'my-model-and-pipeline-v1', dimension: 384);

  @override
  Future<List<double>> embedDocument(String text) =>
      model.embed('document: $text');

  @override
  Future<List<double>> embedQuery(String text) =>
      model.embed('query: $text');
}

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: 'custom-profile-v1.db',
  ),
  embedder: AppEmbedder(myEmbeddingModel),
);
```

The index borrows a custom embedder too. Dispose the index before disposing the
embedder.

## Profiles, locations, and migration

One persistent location belongs to exactly one **EmbeddingProfile**. Use a new,
profile-versioned location after changing weights, tokenizer, pooling,
normalization, prefixes, or dimensions. **clear()** deletes documents but keeps
the profile binding.

A nonempty database created before 1.12 has no stored profile. Prefer a new
location and re-index. If you can independently verify the exact original
embedding pipeline, explicit adoption is available:

```dart
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: legacyPath,
    allowLegacyProfileAdoption: true,
  ),
  embeddingProfile: EmbeddingProfile(id: verifiedProfileId, dimension: 768),
);
```

The dimension is checked before the profile is persisted. The flag is an
attestation, not automatic detection.

SQLite filter fields are physical **vec0** columns. Changing a schema requires a
new schema-versioned location and re-indexing; opening a database without a
schema and later reopening it with one cannot add columns.

## Filters

**Filter** combines **must** (AND), **should** (OR), and **mustNot** (NOT):

- **FieldEquals** for scalar equality.
- **FieldRange** for inclusive numeric bounds.
- **FieldMatchAny** for set membership.

Only fields declared in **VectorStoreSpec.filterSchema** are filterable.
Conditions on undeclared fields are ignored. SQLite names must match
^[A-Za-z][A-Za-z0-9_]*$ and cannot reuse **id**, **embedding**, **content**,
**metadata**, **distance**, or **k**; this narrower set is portable to Qdrant.

## Ownership and durability

**RagIndex** owns its vector store and must be disposed. It borrows its embedder.
The shutdown order is therefore:

```dart
await index.flush();
await index.dispose();
await FlutterEdgeAi.dispose(); // or dispose the custom embedder
```

Keep one app-owned index per persistent location. Make opening single-flight and
share its future across widgets. This is mandatory on Web, where the SQLite
provider holds an exclusive Web Lock for the location until **dispose()**.

**flush()** is required for qdrant-edge, drains IndexedDB for Web SQLite, and is
a no-op for native SQLite. **clear()** is an exclusive operation and preserves
the profile binding.

## Choosing a store

| | qdrant-edge | SQLite + sqlite-vec |
|---|---|---|
| Platforms | Android, iOS, macOS, Linux, Windows | Android, iOS, Web, macOS, Linux, Windows |
| Search | HNSW approximate | Exact KNN inside SQLite |
| Best fit | Native throughput at larger scale | Web, portability, deterministic exact results |
| Provider ID | qdrant | sqlite |

The providers implement the same RAG contract, so switching storage changes the
registered provider and **VectorStoreSpec.providerId**, not the retrieval
pipeline. Current measurements show qdrant-edge roughly 5–11× faster at
1k–10k documents; see the
[benchmark report](https://github.com/DenisovAV/flutter_edge_ai/blob/main/docs/benchmarks/rag_sqlite_vec_vs_qdrant.md).

**Writing this with a coding assistant?** **dart run skills@ get --all** installs
the **flutter-edge-ai-rag** skill with these profile, ownership, and filter rules.
