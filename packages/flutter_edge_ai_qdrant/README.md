# flutter_edge_ai_qdrant

> **Renamed from [`flutter_gemma_rag_qdrant`](https://pub.dev/packages/flutter_gemma_rag_qdrant).**
> Version 2.0.0 also moves the RAG API into `flutter_edge_ai_rag`: replace the
> old dependency/imports, add `flutter_edge_ai_rag`, and register
> `QdrantVectorStoreProvider()` in `FlutterEdgeAiRag`. Existing profile-less
> stores require explicit legacy adoption with a verified, stable profile ID.
> See the [migration guide](https://flutteredge.ai/docs/migration).

qdrant-edge on-device vector-store provider for
[flutter_edge_ai_rag](https://pub.dev/packages/flutter_edge_ai_rag).
Opt-in package implementing `VectorStoreRepository` on top of the official
[`qdrant_edge`](https://pub.dev/packages/qdrant_edge) UniFFI Dart SDK
(a binding over the `qdrant-edge` Rust crate). qdrant's HNSW index makes it the fastest **native** RAG store —
roughly **5–11× faster search** than the in-SQLite `sqlite-vec`/`vec0` store at
1k–10k docs, and further ahead as the corpus grows (see
[benchmark](https://github.com/DenisovAV/flutter_edge_ai/blob/main/docs/benchmarks/rag_sqlite_vec_vs_qdrant.md)).
(The earlier "~75×" figure was against the now-deleted Dart brute-force store.)
For web, or when exact KNN with identical results across platforms matters more
than peak speed, use `flutter_edge_ai_sqlite`.

**Native only** (Android, iOS, macOS, Linux, Windows). For web, use
[`flutter_edge_ai_sqlite`](https://pub.dev/packages/flutter_edge_ai_sqlite)
(`WebSqliteVectorStore`).

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the Flutter Edge AI agent skills, including `flutter-edge-ai-rag` for
embedding profiles, vector stores, and metadata filters.

## Usage

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:path_provider/path_provider.dart';

final rag = FlutterEdgeAiRag(
  providers: [QdrantVectorStoreProvider()],
);

final dir = await getApplicationDocumentsDirectory();
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'qdrant',
    location: '${dir.path}/rag_store', // a directory
  ),
  embeddingProfile: EmbeddingProfile(
    id: 'my-embedder-v1',
    dimension: 4,
  ),
);

await index.addVector(
  id: 'intro',
  content: 'Flutter runs on-device.',
  embedding: const [1.0, 0.0, 0.0, 0.0],
);
final hits = await index.searchVector(
  embedding: const [1.0, 0.0, 0.0, 0.0],
);
await index.flush();
await index.dispose();
```

`providerId` is the string `'qdrant'` (`QdrantVectorStoreProvider().id`); unlike
`SqliteVectorStoreProvider`, there is no static `providerId` constant.

This vector-only form is independent from the main inference runtime. To use
`addText` and `searchText`, initialize `FlutterEdgeAi`, install an active
embedding model, and open the index with a stable identity for that model:

```dart
final textIndex = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'qdrant',
    location: '${dir.path}/text_rag_store',
  ),
  activeEmbedderProfileId:
      'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
      'retrieval-prefix-meanpool-l2-v1',
);
```

The ID must version the weights, tokenizer, pooling, normalization, and
document/query prefix contract; a mutable file path or URL is not an identity.
The index borrows the active or custom embedder, so dispose the index before
disposing that embedder or calling `FlutterEdgeAi.dispose()`.

`QdrantVectorStore` also honors the payload-aware `Filter` DSL on
`searchSimilar` and `RagIndex.searchText`/`searchVector`. It remains exported
as a low-level `VectorStoreRepository` for applications that need direct vector
operations.
Low-level callers must first call `bindEmbeddingProfile()` with the stable ID
and dimension for their embedding space; add, search, remove, and clear refuse
an unbound location. `getStats()` remains available before binding so migration
code can inspect a legacy store before explicitly adopting it.

Field names here are almost unrestricted — payload keys are free-form UTF-8 —
with one exception: a name containing `.` is rejected, because qdrant reads it
as a nested payload path, so `doc.type` would mean "`type` inside `doc`" here
and a flat column on sqlite. Note this store accepts names `SqliteVectorStore`
refuses; if a schema must work on both, keep it inside sqlite's narrower set.

> `VectorStoreSpec.location` is an absolute path to a **shard
> directory** (qdrant creates files under it), not a single `.db` file; build it
> from `getApplicationDocumentsDirectory()`. Use a distinct path from any sqlite
> store so they don't collide on disk.

## Behavior notes

- **Call `RagIndex.flush()` after indexing.**
  New points stay in the shard's in-memory segment until it is flushed or
  closed. A process that ends without either — an Android app killed in the
  background — loses them, and the corpus is embedded again on the next launch
  ([#492](https://github.com/DenisovAV/flutter_edge_ai/issues/492)). `close()`
  persists too, but logs a failed save; `flush()` throws it as
  `VectorStoreException`.
- **Cross-platform web is not supported** — `QdrantVectorStore` is native-only.
- `addDocument`'s `metadata` is forwarded as a raw JSON string into the payload;
  filtering by metadata fields requires valid JSON.
- Distance defaults to cosine.
- Every location is durably bound to one `EmbeddingProfile`.

## Adopting an existing profile-less store

A nonempty `qdrant_edge_v1` shard created before 2.0.0 has vectors but no durable
embedding profile. `FlutterEdgeAiRag` refuses to guess. After independently
verifying the exact model that created the vectors, adopt it explicitly once:

```dart
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'qdrant',
    location: '${dir.path}/rag_store',
    allowLegacyProfileAdoption: true,
  ),
  embeddingProfile: EmbeddingProfile(
    id: 'embeddinggemma-300m-v1',
    dimension: 768,
  ),
);
```

The binding survives `clear()`, close, and reopen. To use a different
embedding space, create a different location.


## Upgrading the older shard layout

**The current package cannot read a store written by 1.2 or earlier.** The shard format changed with the
move to crate 0.8.0, and this release keeps its data in an owned
`qdrant_edge_v1/` subdirectory rather than directly at the path you pass as
`location`.

`rag.open()` throws a `QdrantLegacyStoreException` naming the situation — it
comes from the store's `initialize()`, not the first write, so a read-only
session hits it too. It names the three entries a 1.x shard owns
(`edge_config.json`, `wal/`, `segments/`); remove those from the directory
yourself, then re-index.

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

final RagIndex index;
try {
  index = await rag.open(
    spec: VectorStoreSpec(providerId: 'qdrant', location: path),
    embeddingProfile: profile,
  );
} on QdrantLegacyStoreException catch (e) {
  // e.message names exactly what to remove. Do it with the file APIs you
  // already use for `path`, then call rag.open() again and re-index.
  rethrow;
}
```

**This release never deletes a file it cannot read.** `clear()` empties the
shard in place — the SDK's own `EdgeShard.clear()` — so it does not remove the
directory, and it refuses outright when a 1.x layout is present. The previous
design deleted directories to erase an index, and twice removed files that
belonged to the caller rather than to the store; the deletion is gone, and with
it that whole class of mistake.

Catch `QdrantLegacyStoreException`, never the base `VectorStoreException`:
`rag.open()` also throws the base type when a current-layout
(`qdrant_edge_v1/`, 1.3.0 and later) shard is present but will not open right
now — a WAL held by another store, a permission problem — and that is not a
store you want to act destructively on.

## Platforms

| Platform | Support |
|----------|---------|
| Android (arm64, x64) | ✅ |
| iOS (arm64, simulator) | ✅ |
| macOS (arm64) | ✅ |
| Linux | ✅ |
| Windows (x64) | ✅ |
| Web | ❌ — use `flutter_edge_ai_sqlite` (`WebSqliteVectorStore`) |

An unsupported native target (e.g. Intel macOS, Windows arm64, 32-bit Android)
has no prebuilt archive for the SDK's hook to fetch. The hook prints a warning
naming the slice and skips it, so the build still produces the supported ABIs —
**armeabi-v7a is in `flutter build apk`/`appbundle`'s default set**, and failing
there would break the standard Android release build of every consuming app.
Code that reaches the engine on a skipped ABI fails to load the library at
runtime; restrict the ABI set if you want that to be impossible:

```
flutter build apk --target-platform android-arm64,android-x64
```

The native binary is provisioned by the `qdrant_edge` SDK's own Native Assets
build hook (SHA256-verified per-platform archive) — this package has no
native code, build script, or download logic of its own.
