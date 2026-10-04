# flutter_edge_ai_qdrant

> **Renamed from [`flutter_gemma_rag_qdrant`](https://pub.dev/packages/flutter_gemma_rag_qdrant).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_rag_qdrant/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

qdrant-edge on-device RAG vector store for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai).
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

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-rag`, covers embedding models, both vector stores, and the metadata filters — including the `filterSchema` trap that silently returns unfiltered results.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

await FlutterEdgeAi.initialize(
  vectorStore: QdrantVectorStore(),
);
```

Then use the unchanged RAG API:

```dart
await FlutterEdgeAiPlugin.instance.initializeVectorStore('rag_store'); // a directory
await FlutterEdgeAiPlugin.instance.addDocument(/* ... */);
final hits = await FlutterEdgeAiPlugin.instance.searchSimilar(query: query, topK: 5);
await FlutterEdgeAiPlugin.instance.flushVectorStore(); // after indexing — see below
```

`QdrantVectorStore` also honors the payload-aware `Filter` DSL on
`searchSimilar(..., filter: Filter(must: [FieldEquals(key: 'lang', value: 'en')], mustNot: [...]))`.

Field names here are almost unrestricted — payload keys are free-form UTF-8 —
with one exception: a name containing `.` is rejected, because qdrant reads it
as a nested payload path, so `doc.type` would mean "`type` inside `doc`" here
and a flat column on sqlite. Note this store accepts names `SqliteVectorStore`
refuses; if a schema must work on both, keep it inside sqlite's narrower set.

> The storage path passed to `initializeVectorStore` is treated as a **shard
> directory** (qdrant creates files under it), not a single `.db` file. Use a
> distinct path from any sqlite store so they don't collide on disk.

## Behavior notes

- **Call `flushVectorStore()` (or `FlutterEdgeAi.rag.flush()`) after indexing.**
  New points stay in the shard's in-memory segment until it is flushed or
  closed. A process that ends without either — an Android app killed in the
  background — loses them, and the corpus is embedded again on the next launch
  ([#492](https://github.com/DenisovAV/flutter_edge_ai/issues/492)). `close()`
  persists too, but logs a failed save; `flush()` throws it as
  `VectorStoreException`.
- **Cross-platform web is not supported** — `QdrantVectorStore` is native-only.
- `enableHnsw` is accepted but a no-op: qdrant decides indexing internally
  (brute-forces below ~20k points, which is already faster than the Dart HNSW
  for typical RAG corpora).
- `addDocument`'s `metadata` is forwarded as a raw JSON string into the payload;
  filtering by metadata fields requires valid JSON.
- Distance defaults to cosine.


## Upgrading from 1.x

**1.3 cannot read a store written by 1.2 or earlier.** The shard format changed with the
move to crate 0.8.0, and this release keeps its data in an owned
`qdrant_edge_v1/` subdirectory rather than directly at the path you pass to
`initialize()`.

`initialize()` throws a `QdrantLegacyStoreException` naming the situation — not
the first write, so a read-only session hits it too. It names the three entries
a 1.x shard owns (`edge_config.json`, `wal/`, `segments/`); remove those from
the directory yourself, then re-index.

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

final store = QdrantVectorStore();
try {
  await store.initialize(path);
} on QdrantLegacyStoreException catch (e) {
  // e.message names exactly what to remove. Do it with the file APIs you
  // already use for `path`, then initialize() again and re-index.
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
`initialize()` also throws the base type when a 2.0 shard is present but will
not open right now — a WAL held by another store, a permission problem — and
that is not a store you want to act destructively on.

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
