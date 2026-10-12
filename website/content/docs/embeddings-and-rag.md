---
title: Embeddings & RAG
description: Embed text with EmbeddingGemma 1 and 2 across nine task types, and build profile-safe on-device RAG with pluggable SQLite or Qdrant storage.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
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
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_litertlm: ^1.13.0
  flutter_edge_ai_embeddings: ^2.3.0 # tokenizers for .tflite / .onnx models
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0 # all six platforms, including Web
  # flutter_edge_ai_qdrant: ^2.1.0 # native alternative
```

<Warning>

Upgrade every flutter_edge_ai package together. With core 2.3.0 the minimum
versions are litertlm 1.13.0, embeddings 2.3.0, onnx 0.5.8, rag 1.1.0, sqlite
and qdrant 2.1.0 (the full list is in [Migration](/docs/migration)). An older
engine or store fails to compile against 2.3.0.

</Warning>

**flutter_edge_ai_sqlite** needs Flutter 3.47 or later. On Web, embeddings
and SQLite RAG need files copied into your app's **web/** — the LiteRT.js loader
and **rag/sqlite3.wasm**; see [Installation → Web](/docs/installation#web).

## Embedding models

| Model | Files | Platforms | Tokenizer | Longest input |
|---|---|---|---|---|
| EmbeddingGemma 2 text | one `.litertlm` | Android, iOS, macOS, Linux, Windows | inside the bundle | 1024 tokens |
| EmbeddingGemma 1, Gecko | `.tflite` + tokenizer file | Android, iOS, macOS, Linux, Windows, Web | `flutter_edge_ai_embeddings` | the model's sequence length |
| MiniLM, EmbeddingGemma ONNX | `.onnx` + `tokenizer.json` | native via **flutter_edge_ai_onnx**; Web for WordPiece models | `flutter_edge_ai_embeddings` | the graph's static length, or none |

The first two run on **LiteRtEmbeddingBackend** from **flutter_edge_ai_litertlm**;
the ONNX ones on **OnnxEmbeddingBackend** from **flutter_edge_ai_onnx**. LiteRT
EmbeddingGemma (1 and 2) and Gecko produce 768-dimensional vectors;
all-MiniLM-L6-v2 produces 384. A number such as 256 in an artifact name is the
maximum input length in tokens, not the vector dimension. See
[Models](/docs/models#text-embedding-models) for download links.

## EmbeddingGemma 2

EmbeddingGemma 2 text ships as one `.litertlm` bundle that carries its own
tokenizer: install the model alone — no **tokenizerFrom…()** call, and no
**flutter_edge_ai_embeddings** or **embeddingTokenizers:** needed. The
repository is not gated.

```dart
const revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$revision/'
      'embeddinggemma-2-text-270m.litertlm',
    )
    .install();

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vector = await embedder.embed(
  EmbeddingInput.text('Flutter runs on six platforms.'),
  taskType: TaskType.retrievalDocument,
);
```

- **Native only** with flutter_edge_ai_litertlm 1.13.0: Android, iOS, macOS,
  Linux and Windows. On Web, **install()** refuses a `.litertlm` embedder with
  an **UnsupportedError** before downloading anything.
- **Text only for now.** **getActiveEmbedder(supportImage: true)** or
  **supportAudio: true** throws **EmbeddingLoadException**; images arrive in
  litertlm 1.14.0, audio in 1.16.0.
- **At most 1024 tokens per input**, task prefix, BOS and EOS included
  (**maxInputTokens** is 1024). Keep chunks at 512 tokens or fewer: memory
  grows with the input length — on an M4 Pro Mac about +170 MB at 128 tokens,
  +340 MB at 512 and +560 MB at 1024. A longer input throws
  **EmbeddingInputTooLongException** whose **actualTokens** is null.
- **CPU.** **activeBackend** is **PreferredBackend.cpu**.
- **Disk:** the 165 MB bundle plus a 71 MB weight cache the engine writes at
  its first load (the 440m bundle adds 218 MB for vision, the 740m bundle
  writes 385 MB in total, even for text-only use). The cache lives in the app's
  cache directory: never backed up, and rebuilt at the next load if the OS
  clears it.
- EmbeddingGemma 1 and 2 are different embedding spaces with the same
  dimension: give each its own vector-store location and profile.

## EmbeddingGemma 1 (`.tflite` + tokenizer)

Initialize the backend and the tokenizers:

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  // EmbeddingGemma 1 is gated; never hard-code the token.
  huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isEmpty
      ? null
      : const String.fromEnvironment('HUGGINGFACE_TOKEN'),
);
```

Pin both files to an immutable revision. The stable profile used by the vector
store must describe the exact weights, tokenizer, pooling, normalization, and
document/query prefix contract.

EmbeddingGemma 1 is a gated repository: the Hugging Face account behind the
token must accept the Gemma license on the model page before the download
succeeds.

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

## Embedding API

```dart
final embedder = await FlutterEdgeAi.getActiveEmbedder();

final query = await embedder.embed(
  EmbeddingInput.text('Where does Flutter run?'),
  taskType: TaskType.retrievalQuery,
);
final documents = await embedder.embedAll(
  [for (final chunk in chunks) EmbeddingInput.text(chunk)],
  taskType: TaskType.retrievalDocument,
);
print('${embedder.dimension} dimensions, up to ${embedder.maxInputTokens} tokens');
```

- **taskType** is required and prefixes the text: **retrievalQuery** and
  **retrievalDocument** for search, **none** for no prefix, and
  **questionAnswering**, **factChecking**, **codeRetrieval**,
  **classification**, **clustering**, **sentenceSimilarity**. Native and Web
  apply the same prefix for the same task.
- **embedAll** keeps the input order, fails on the first error and takes a
  **cancelToken**.
- An input longer than **maxInputTokens** — task prefix, BOS and EOS
  included — is never truncated: it fails with
  **EmbeddingInputTooLongException**. A null **maxInputTokens** means the
  model file declares no limit.
- Every error arrives as a failed future and is an **EmbeddingException**: a
  closed model gives **EmbedderClosedException**, a model that cannot load
  **EmbeddingLoadException**.
- **generateEmbedding**, **generateEmbeddings** and **getDimension** still
  compile as deprecated forwarders and are removed in 2.5.0.

## RAG with the active core embedder

Install the embedder first: **open()** resolves the embedder's profile, which
loads the model.

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
      FilterField(name: 'year', type: FilterFieldType.number),
      FilterField(name: 'archived', type: FilterFieldType.bool),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
);

await index.add(
  id: 'doc-1',
  document: EmbeddingInput.text('Flutter runs on six platforms.'),
  metadata: '{"category":"flutter","year":2026,"archived":false}',
);

final hits = await index.search(
  query: EmbeddingInput.text('Where does Flutter run?'),
  topK: 5,
  threshold: 0.3,
  filter: Filter(
    must: [FieldEquals(key: 'category', value: 'flutter')],
    mustNot: [FieldEquals(key: 'archived', value: true)],
  ),
);

await index.flush();
```

**location** is an absolute path on native — a database file for SQLite, a
directory for Qdrant; build it from **getApplicationDocumentsDirectory()** — and
a plain name on Web. path_provider has no Web implementation, so call it only
off-web (see the sample under Independent text RAG).

**add** embeds with the document role and stores the text as the hit's
content; **search** uses the query role. Chunk text below the embedder's
**maxInputTokens**: a longer chunk throws **EmbeddingInputTooLongException**.
Every error of a Future-returning **RagIndex** method arrives as a failed
future.

**FlutterEdgeAiActiveEmbedder** borrows the model returned by
**FlutterEdgeAi.getActiveEmbedder()** and never closes it. It pins the model
that is active when it is created; after switching embedders it throws
**StateError** — open a new index at a new location. A request that failed
because core replaced the model before it ran is retried once.

- **FlutterEdgeAiActiveEmbedder.forActiveModel(namespace:)** derives the
  profile id from the installed file names, so installing a model under other
  file names changes the id and the old location refuses to open. Install with
  revision-qualified **filename:**s so new weights get a new id too.
- **FlutterEdgeAiActiveEmbedder(profileId: profileId)** takes an explicit id
  that versions the weights, tokenizer, pooling, normalization and prefixes.
  Profile ids may not contain control characters.

Queries over text documents use **TaskType.retrievalQuery**; pass
**queryTask:** for another task.

## Batch or vector-only RAG

For precomputed vectors, open a vector-only index with the profile of the
pipeline that produced them:

```dart
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(id: profileId, dimension: 768),
);

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vectors = await embedder.embedAll(
  [for (final document in documents) EmbeddingInput.text(document)],
  taskType: TaskType.retrievalDocument,
);
for (var i = 0; i < documents.length; i++) {
  await index.addVector(
    id: 'doc-$i',
    content: documents[i],
    embedding: vectors[i],
  );
}

final queryVector = await embedder.embed(
  EmbeddingInput.text('search text'),
  taskType: TaskType.retrievalQuery,
);
final hits = await index.searchVector(embedding: queryVector);
```

**addVector** and **searchVector** also work on an index opened with an
embedder, so batch ingest and text search can share one location. A purely
vector-based app never initializes Flutter Edge AI.

## Independent text RAG

Implement **RagEmbedder** when retrieval has its own embedding lifecycle:

```dart
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);

  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> resolveProfile() async =>
      EmbeddingProfile(id: 'my-model-and-pipeline-v1', dimension: 384);

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) =>
      model.embed('document: ${document.text}');

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) => model.embed('query: ${query.text}');
}

// kIsWeb: package:flutter/foundation.dart; p: package:path/path.dart.
// path_provider has no Web implementation, so call it only off-web.
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: kIsWeb
        ? 'custom-profile-v1.db'
        : p.join(
            (await getApplicationDocumentsDirectory()).path,
            'custom-profile-v1.db',
          ),
  ),
  embedder: AppEmbedder(myEmbeddingModel),
);
```

The index borrows a custom embedder too. Dispose the index before disposing the
embedder.

## Image and audio documents

A location holds documents of one modality, declared in
**VectorStoreSpec.documents** (text by default) and stored with the profile.
An image or audio index needs an embedder whose **modalities** include it; its
documents carry a **content** reference (a URI, file path or asset id), never
the media bytes. A text query over an image index is text-to-image search.
The embedders bundled with flutter_edge_ai 2.3.0 embed text only, so with them
an image or audio index fails to open with **EmbeddingLoadException**; a custom
**RagEmbedder** can embed media today. Cross-modal scores are not on one scale:
mixed corpora use one index per modality.

## Profiles, locations, and migration

One persistent location belongs to exactly one **EmbeddingProfile** and one
document modality. Use a new, profile-versioned location after changing
weights, tokenizer, pooling, normalization, prefixes, or dimensions.
**clear()** deletes documents but keeps the binding.

Stores written by flutter_edge_ai_rag 1.0 (sqlite and qdrant 2.0.x) open
unchanged as text locations. The API changes from rag 1.0 are listed in
[Migration](/docs/migration).

A nonempty database created before 2.0 has no stored profile. Prefer a new
location and re-index. If you can independently verify the exact original
embedding pipeline, explicit adoption is available:

```dart
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: legacyPath,
    allowLegacyProfileAdoption: true,
  ),
  profile: EmbeddingProfile(id: verifiedProfileId, dimension: 768),
);
```

The dimension is checked before the profile is persisted. The flag is an
attestation, not automatic detection, and applies to text locations only.

SQLite filter fields are physical **vec0** columns. Changing a schema requires a
new schema-versioned location and re-indexing; opening a database without a
schema and later reopening it with one cannot add columns.

## Filters

**Filter** combines **must** (AND), **should** (OR), and **mustNot** (NOT):

- **FieldEquals** for scalar equality.
- **FieldRange** for inclusive numeric bounds.
- **FieldMatchAny** for set membership.

Only fields declared in **VectorStoreSpec.filterSchema** are filterable. A
condition on an undeclared field throws **ArgumentError**. SQLite names must
match ^[A-Za-z][A-Za-z0-9_]*$ and cannot reuse **id**, **embedding**,
**content**, **metadata**, **distance**, or **k**; this narrower set is portable
to Qdrant.

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
the binding.

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
