---
name: flutter-gemma-rag
description: Use when adding RAG, semantic search or text embeddings to a flutter_gemma app — searching the user's documents on-device, an embedding model plus a vector store (flutter_gemma_rag_sqlite or flutter_gemma_rag_qdrant). Also use when a metadata filter returns unfiltered results, retrieval quality is poor, addDocument throws about a missing embedding model, the vector store fails to open on a phone, or it throws UnimplementedError on web.
---

# On-device RAG with flutter_gemma

## Rules

1. Use the `FlutterGemma.rag` facade: `initialize`, `addDocument`, `searchSimilar`. It embeds documents and queries with the correct task types.
2. Declare every field used in a filter in `filterSchema:` at `initialize`. A condition on an undeclared field is dropped, never rejected: with no schema at all the search comes back completely unfiltered, and a filter that mixes declared and undeclared fields narrows only by the declared ones.
3. On native, give `rag.initialize` an absolute path in a writable directory. A bare name resolves against the process working directory, which is not writable on Android or iOS.
4. Activate an embedding model with `getActiveEmbedder()` before `addDocument`.
5. `LiteRtEmbeddingBackend` comes from `flutter_gemma_litertlm`, not `flutter_gemma_embeddings`.
6. On web use `WebSqliteVectorStore`. `SqliteVectorStore` constructs there without complaint and throws `UnimplementedError` from the first call — `configure()` is a silent no-op, so the mistake shows up as a failed search, not a failed setup. `flutter_gemma_rag_qdrant` is native-only.
7. Android needs `minSdk 30` — the LiteRT embedding runtime, not the vector store. The rest of the build setup is the flutter-gemma-inference skill's [platform setup](../flutter-gemma-inference/references/platform-setup.md).

## Setup

```sh
flutter pub add flutter_gemma flutter_gemma_litertlm flutter_gemma_embeddings flutter_gemma_rag_sqlite path_provider
```

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_rag_sqlite/flutter_gemma_rag_sqlite.dart';
import 'package:path_provider/path_provider.dart';

const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');
const embeddingGemma =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main';

await FlutterGemma.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  // The tokenizer is registered separately from the backend: which family a
  // model needs is a property of the MODEL, not the engine. Omit it and the
  // first embedding throws a StateError naming the package to add.
  embeddingTokenizers: [GemmaEmbeddingTokenizers()], // flutter_gemma_embeddings
  vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
  filterSchema: const FilterSchema(fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'year', type: FilterFieldType.number),
  ]),
  huggingFaceToken: hfToken.isEmpty ? null : hfToken,
);

await FlutterGemma.installEmbedder()
    .modelFromNetwork('$embeddingGemma/embeddinggemma-300M_seq512_mixed-precision.tflite')
    .tokenizerFromNetwork('$embeddingGemma/sentencepiece.model')
    .install();
final EmbeddingModel embedder = await FlutterGemma.getActiveEmbedder();

await FlutterGemma.rag.initialize(
  kIsWeb ? 'rag.db' : '${(await getApplicationDocumentsDirectory()).path}/rag.db',
);
```

EmbeddingGemma is a gated repo: the token's Hugging Face account must have accepted the Gemma licence, and the token ships inside the app — on web inside `main.dart.js`. `seq512` in the file name is the input window in tokens; `seq256`, `seq1024` and `seq2048` variants sit in the same repo.

`rag.initialize` takes a database file for sqlite and a directory for qdrant. On native it persists across launches at that path. Add `inferenceEngines:` from the flutter-gemma-inference skill when the app also generates answers from the results.

## Index and search

```dart
import 'dart:convert';

await FlutterGemma.rag.addDocument(
  id: 'doc-1',
  content: chunk,
  metadata: jsonEncode({'lang': 'en', 'year': 2024}),
);

final List<RetrievalResult> hits = await FlutterGemma.rag.searchSimilar(
  query: question,
  topK: 5,
  filter: const Filter(
    must: [FieldEquals(key: 'lang', value: 'en')],
    mustNot: [FieldRange(key: 'year', lte: 2010)],
  ),
);
for (final hit in hits) {
  print('${hit.id} ${hit.similarity.toStringAsFixed(2)} ${hit.content}');
}
```

`searchSimilar` takes the question as text and embeds it itself. Each `RetrievalResult` has `id`, `content`, `similarity` and `metadata`. Filter operators: `FieldEquals`, `FieldRange` (`gte`, `lte`), `FieldMatchAny`, combined with `must`, `should` and `mustNot`.

`addDocument` with an existing `id` replaces that document. `FlutterGemma.rag.removeDocument(id:)` deletes one; `FlutterGemma.rag.clear()` empties the store.

## Traps

**Filter has no effect**
- Symptom: results ignore the filter; no error.
- Fix: declare the field in `filterSchema`. With `flutter_gemma_rag_sqlite`, names must match `^[A-Za-z][A-Za-z0-9_]*$` and cannot be `id`, `embedding`, `content`, `metadata`, `distance` or `k`. Its `vec0` table also caps declared metadata columns at 16; nothing checks that at `initialize`, so a 17th field surfaces when the table is created, on the first `addDocument`.

**Poor retrieval after embedding by hand**
- Query and document embeddings are trained asymmetrically. `generateEmbedding` defaults to `TaskType.retrievalQuery`, so text embedded for indexing without a task type gets the query prefix.
- Fix: pass `TaskType.retrievalDocument` when indexing by hand:

```dart
final vector = await embedder.generateEmbedding(
  chunk,
  taskType: TaskType.retrievalDocument,
);
await FlutterGemma.rag.addDocumentWithEmbedding(
  id: 'doc-2',
  content: chunk,
  embedding: vector,
);
```

**`addDocument` throws**
- Symptom: `No embedding model is active. addDocument(content:) and searchSimilar(query:) auto-embed text, which requires an embedding model.`
- Fix: install an embedder and call `FlutterGemma.getActiveEmbedder()` first.

**Store fails to open on a phone**
- Cause: a bare name such as `'rag.db'` passed to `rag.initialize` on Android or iOS.
- Fix: an absolute path under `getApplicationDocumentsDirectory()`, as in Setup.

## Backend

LiteRT embeddings always run on CPU on native, and so do ONNX ones. `getActiveEmbedder(preferredBackend:)` is accepted for symmetry with `getActiveModel` and never applied; core logs one line per isolate saying so, in debug builds only. Read `EmbeddingModel.activeBackend` when it matters — that answer exists in release builds too. CPU is the correct answer rather than a fallback: LiteRT's GPU delegate compiles and then returns all-zero vectors for EmbeddingGemma's int4 weights, and the ONNX client appends no execution provider.

Web is not configurable either, and on the LiteRT web embedder its accelerator is not a single fact. `litert_embeddings.js` asks for `accelerator: 'webgpu'` and recompiles for `'wasm'` when the browser has none. LiteRT then has a SECOND fallback that raises nothing: a model that is not fully accelerated is partly delegated to WASM where the browser has JSPI, and recompiled for WASM entirely where it does not.

So two things are worth reading, and they answer different questions. `window.getLiteRtEmbeddingFullyAccelerated()` is known at compile time and is the only way to see the JSPI partial case, which keeps WebGPU buffers and therefore looks like a clean WebGPU run to everything downstream. `window.getLiteRtEmbeddingAccelerator()` is known after the first embedding — query or document — and says where the output buffer lived. `EmbeddingModel.activeBackend` is null on web for that reason: a synchronous getter cannot carry an answer that does not exist until the first run.

Both getters belong to the LiteRT web embedder. The ONNX web arm has no equivalent — it hands `onnxruntime-web` `['webgpu', 'wasm']` in one call and is never told which was kept — so calling them in an ONNX-web app fails with "not a function".

## Web

- Copy `web/rag/sqlite3.wasm` from the `flutter_gemma_rag_sqlite` package into the app as `web/rag/sqlite3.wasm`.
- Web embeddings need four module files side by side in the app's `web/`, all four from `flutter_gemma_litertlm/web/`: `litert_embeddings.js`, `sentencepiece.js`, `litert.js`, `tensorflow.js` — the first imports the other three by relative path, so three files alone give a 404 and an embedder that never initialises. They are one bundle in four pieces; never mix them across package versions.
- The LiteRT WASM runtime underneath comes from a pinned CDN copy by default (`flutter_gemma_litertlm` — `LiteRtWebRuntime.wasmPath`). To self-host, copy `node_modules/@litertjs/core/wasm/` into the app's `web/wasm/` and set `LiteRtWebRuntime.wasmPath = '/wasm/';` before the first embedding. Pin `@litertjs/core` to `LiteRtWebRuntime.pinnedVersion`: the runtime and `web/litert.js` are two halves of one release, and a mismatch fails at the first embedding with an error that never mentions versions.
- In `web/index.html`, before Flutter boots: `<script src="cache_api.js"></script>` first — it is not a module, and Dart's model cache calls its helpers (`cacheGetBlobUrl`, `cachePut`) to download and store the model, then hands the embedder a blob URL from that cache — then `<script type="module" src="litert_embeddings.js"></script>`.

Find a package's directory with `grep -A1 '"name": "flutter_gemma_rag_sqlite"' .dart_tool/package_config.json`.

## Chunking

Splitting documents, chunk size and overlap are the app's to decide. Keep each chunk within the embedding model's window — 512 tokens for `seq512`; a longer one is truncated without an error.

For ONNX embedding models see the flutter-gemma-onnx skill.
