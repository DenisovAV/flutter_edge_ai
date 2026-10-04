---
title: Embeddings & RAG
description: Generate text embeddings and run on-device retrieval-augmented generation (RAG) with a payload-aware Filter API.
image: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai can generate vector embeddings from text (EmbeddingGemma / Gecko on
LiteRT, or BERT / MiniLM / WordPiece models via the ONNX backend)
and run on-device RAG with a vector store. Two stores are available, both with
the same Dart API: **qdrant-edge** — the fastest store on native (HNSW
approximate nearest-neighbour) — and **sqlite-vec** — a portable, exact store
that runs on **all six platforms (Android, iOS, macOS, Linux, Windows, Web)**,
and the only store that runs on Web. Your code is portable across both.

## Setup

Embeddings need the `flutter_edge_ai_embeddings` package plus a backend that
implements it — `flutter_edge_ai_litertlm`'s `LiteRtEmbeddingBackend` (or
`flutter_edge_ai_onnx`'s `OnnxEmbeddingBackend` for ONNX/ORT models, which also
runs on Web via onnxruntime-web). RAG also
needs a vector store package — `flutter_edge_ai_qdrant` (native, fastest) or
`flutter_edge_ai_sqlite` (sqlite-vec; all platforms, including Web). Register
them in `await FlutterEdgeAi.initialize(...)`:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()], // flutter_edge_ai_litertlm
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
  vectorStore: QdrantVectorStore(),                    // or WebSqliteVectorStore() on web
);
```

See [Installation](/docs/installation) for the full registration reference. On
web, `LiteRtEmbeddingBackend` also needs its LiteRT.js loader script in
`web/index.html` — see [Installation → Web](/docs/installation#web).

## Text embeddings

The embedding **dimension depends on the model and backend**. The LiteRT models
(EmbeddingGemma / Gecko) generate **768-dimensional vectors**; with
`OnnxEmbeddingBackend` the dimension is model-dependent (e.g. all-MiniLM-L6-v2 is
384-dim). The number in a model name (64/256/512/1024/2048) is the max input
sequence length in tokens, not the embedding dimension. See
[Models](/docs/models#text-embedding-models) for the full list.

### Install an embedding model

```dart
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite',
      token: 'hf_...',
    )
    .tokenizerFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
      token: 'hf_...',
    )
    .install();
```

### Generate embeddings

```dart
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final embeddings = await embedder.generateEmbeddings(
  docs.map((d) => d.content).toList(),
  taskType: TaskType.retrievalDocument,
);
```

<Info>
On native, `LiteRtEmbeddingBackend` runs embedding on **CPU only**: EmbeddingGemma
is an int4 `.tflite` model, and the TFLite GPU delegate cannot run int4 — so GPU
embedding is not possible for that model format. The ONNX backend is CPU-only too:
it appends no execution provider, so it runs ORT's default. On web both backends
try **WebGPU** first and fall back to WASM (LiteRT.js, onnxruntime-web). On native,
embedding runs on a background isolate so it doesn't block the UI thread; on web
it runs on the main thread.
</Info>

`getActiveEmbedder(preferredBackend:)` is accepted for symmetry with
`getActiveModel` and **never applied** — no embedding backend reads it. Core logs
one line per isolate saying so, but only in debug builds. Read
`EmbeddingModel.activeBackend` when it matters:

```dart
final embedder = await FlutterEdgeAi.getActiveEmbedder(
  preferredBackend: PreferredBackend.gpu, // accepted, not applied
);
print(embedder.activeBackend); // PreferredBackend.cpu on native
```

That answer survives a release build, which the log line does not. It is `null` on
web, where the runtime picks for itself and does not report back synchronously; the
LiteRT web bundle exposes `window.getLiteRtEmbeddingAccelerator()` and
`window.getLiteRtEmbeddingFullyAccelerated()` for that, and the ONNX web arm has
no equivalent.

## On-device RAG / vector store

All RAG operations live on the `FlutterEdgeAi.rag` namespace — the canonical
entry point. (The store is opt-in: register a `vectorStore:` in
`await FlutterEdgeAi.initialize(...)`, or every `rag` call except `flush()` throws
a clear "add a RAG package" error — `flush()` returns without doing anything.)

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// 1. Install an embedding model (any of Gecko / EmbeddingGemma) — see above.

// 2. Initialize the vector store (one shard per database path). On native pass
//    an absolute path: a bare name resolves against the process working
//    directory, which is not writable on Android or iOS. On web a name is enough.
final dir = await getApplicationDocumentsDirectory(); // package:path_provider
await FlutterEdgeAi.rag.initialize('${dir.path}/rag_store');

// 3. Add documents — let flutter_edge_ai compute embeddings for you
for (final doc in docs) {
  await FlutterEdgeAi.rag.addDocument(
    id: doc.id,
    content: doc.content,
    metadata: '{"category":"science","lang":"en"}',
  );
}

// 3b. Or batch-embed yourself and feed pre-computed vectors via
//     addDocumentWithEmbedding(...) for higher throughput.
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final embeddings = await embedder.generateEmbeddings(
  docs.map((d) => d.content).toList(),
  taskType: TaskType.retrievalDocument,
);
for (var i = 0; i < docs.length; i++) {
  await FlutterEdgeAi.rag.addDocumentWithEmbedding(
    id: docs[i].id,
    content: docs[i].content,
    embedding: embeddings[i],
    metadata: '{"category":"science","lang":"en"}',
  );
}

// 3c. Persist what you indexed while the store stays open (see below)
await FlutterEdgeAi.rag.flush();

// 4. Semantic search, with optional payload-aware Filter
final results = await FlutterEdgeAi.rag.searchSimilar(
  query: 'quantum entanglement',
  topK: 10,
  threshold: 0.0,
  filter: Filter(
    must: [FieldEquals(key: 'category', value: 'science')],
    mustNot: [FieldEquals(key: 'lang', value: 'fr')],
  ),
);

// 5. Maintain the store: remove one document (no-op if the id is absent),
//    read stats, or clear everything.
await FlutterEdgeAi.rag.removeDocument(id: 'doc-42');
final stats = await FlutterEdgeAi.rag.stats();
await FlutterEdgeAi.rag.clear();
```

### Persisting the index: `flush()`

Call `FlutterEdgeAi.rag.flush()` after indexing. What it does depends on the store:

- **qdrant-edge** — required. New documents stay in memory until the store is
  flushed or closed, so an index built without either is lost when the process
  ends — an Android app killed in the background is the ordinary case. `close()`
  persists too, but only logs a failed save; `flush()` throws it.
- **sqlite-vec, native** — a no-op: every statement is on disk when it returns.
- **sqlite-vec, web** — drains the IndexedDB storage and waits for it. `sqlite3`
  3.4.0 through 3.5.2 returned early over a write batch already in flight
  ([upstream #408](https://github.com/simolus3/sqlite3.dart/issues/408)), which
  is why `flutter_gemma_rag_sqlite` 1.4.0 requires sqlite3 3.6.0 and, with it,
  **Flutter 3.47** — a higher floor than every other package here. On Flutter
  3.44 only the old `flutter_gemma_rag_sqlite` 1.3.2 resolves, with the partial drain;
  `close()` is the full drain on every version.

A store that cannot persist at all (the web in-memory fallback) throws
`VectorStoreException` rather than returning. A custom store that `implements`
`VectorStoreRepository` must declare `flush()`; one that `extends` it inherits an
empty default — override it if your store buffers writes.

## The Filter API

`Filter` supports `must` / `should` / `mustNot` lists of conditions:

- `FieldEquals` — exact match on a payload field.
- `FieldRange` — numeric range on a payload field.
- `FieldMatchAny` — match against any value in a set.

Both stores honor `Filter` on **all platforms**, and both need the filterable
fields declared up front in a `FilterSchema` (see below). qdrant-edge promotes
exactly the declared fields to payload keys at write time; sqlite-vec creates
them as columns at table-creation time. On either store a condition on an
undeclared field is **dropped**, as if it had never been written: the search
returns the same hits as `filter: null`, and a filter mixing declared and
undeclared fields narrows only by the declared ones. A missing declaration
therefore looks like "my filter had no effect" — too many results, never an
error and never zero.

### Declaring filter fields

The sqlite-vec store filters over declared columns. Describe them with a
`FilterSchema` of `FilterField`s, and pass it either to `initialize(...)`:

```dart
await FlutterEdgeAi.initialize(
  vectorStore: SqliteVectorStore(),
  filterSchema: const FilterSchema(fields: [
    FilterField(name: 'category', type: FilterFieldType.string),
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'year', type: FilterFieldType.number),
  ]),
);
```

…or at runtime via `configure(...)` on the `VectorStoreRepository` — it returns
`void`, so do not `await` it:

```dart
store.configure(FilterSchema(fields: [
  FilterField(name: 'category', type: FilterFieldType.string),
]));
```

`FilterFieldType` has exactly three values: `string`, `number`, `bool`.

What a field may be NAMED is decided by the store, and the two differ — the
check runs in `configure()`, so you find out when you hand the schema over, not
at the first insert.

`SqliteVectorStore` is the strict one: a name must match
`^[A-Za-z][A-Za-z0-9_]*$` and must not be one vec0 already uses (`id`,
`embedding`, `content`, `metadata`, `distance`, `k`). The name becomes a real
`vec0` column and sqlite-vec's DDL grammar has no quoted identifier form, so
`doc-type` is unrepresentable there rather than merely unescaped.

`QdrantVectorStore` accepts far more — payload keys are free-form UTF-8 — with
two rules of its own: no `.`, which qdrant reads as a nested-path separator, and
none of the keys the store uses itself (`__flutter_gemma_id`,
`__flutter_gemma_content`, `__flutter_gemma_metadata`).

So the portable set is sqlite's. If you may ever switch backends, stay inside
it. Regardless of store, a schema with a duplicate or empty name is rejected.

A `Filter` over the declared fields is then applied inside the store; a filter
referencing an **undeclared** field is silently ignored (no-op, never throws).

<Warning>
Declare a `FilterSchema` on **both** stores. Neither store filters on a field it
was not told about: the condition is dropped and the search comes back
unfiltered, with no error and no log in a release build. The difference between
the two is not "schema optional": sqlite-vec needs the schema at table-creation
time, while qdrant promotes at write time.
</Warning>

## Platform support

| Feature | Android | iOS | Web | Desktop |
|---|---|---|---|---|
| Text Embeddings | ✅ | ✅ | ✅ | ✅ |
| VectorStore — qdrant-edge | ✅ | ✅ | ❌ | ✅ |
| VectorStore — sqlite-vec | ✅ | ✅ | ✅ | ✅ |
| Payload `Filter` | ✅ | ✅ | ✅ | ✅ |

Both stores expose the identical Dart API, so you can swap one for the other by
changing only the `vectorStore:` you register.

| | qdrant-edge | sqlite-vec (`vec0`) |
|---|---|---|
| **Platforms** | Native only (Android, iOS, macOS, Linux, Windows) | All six — native **+ Web** |
| **KNN** | HNSW approximate | Exact (brute-force inside SQLite) |
| **Speed** | Fastest native (~5–11× faster search at 1k–10k docs) | Portable, identical results everywhere |
| **When to use** | Native throughput at scale | Web reach, or exact results across every platform |

<Info>
**`sqlite-vec` fetches its native library at build time (1.3.0+).** The
per-platform `vec0` extension comes from this repository's
`native-sqlite-vec-v*` GitHub Release, downloaded and SHA256-verified by the
package's build hook the first time you build for a given platform, then cached
under `~/.cache/flutter_gemma/native/` (`~/Library/Caches/…` on macOS,
`%LOCALAPPDATA%\…` on Windows). So the **first** build of each platform needs
`github.com` reachable; later builds do not. `flutter_edge_ai_litertlm` has always
worked this way — as of 1.3.0 both packages behave the same.

Before 1.3.0 the loadables were committed into the package, which shipped all
seven platforms' binaries to every consumer to use one of them. If you build in
an air-gapped environment, copy the whole `flutter_gemma/native` cache directory
from a machine that built the same package versions, including its hidden
version-marker files — a folder copied without them is discarded and fetched
again. There is no setting that points the build at archives you vendor
yourself.
</Info>

**Which store?** `qdrant-edge` is the fastest **native** option — benchmarked
~5–11× faster search than the `sqlite-vec` store at 1k–10k documents — using HNSW
approximate nearest-neighbour. `sqlite-vec` is exact (brute-force KNN inside
SQLite via the `vec0` extension), portable across all six platforms, and the only
store that runs on Web. Pick qdrant-edge for native throughput; pick sqlite-vec
for exact results or cross-platform / web reach.

Benchmarks comparing the two stores across platforms (EmbeddingGemma 300M,
768-dim) are in the
[repo benchmarks](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai/example/integration_test/benchmarks/comparison.md).

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-rag`](/docs/package-skills), the skill that teaches it embedding models, both vector stores, and the metadata filters above — including the `filterSchema` trap that returns unfiltered results.
