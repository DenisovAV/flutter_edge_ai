# flutter_edge_ai_sqlite

> **Renamed from [`flutter_gemma_rag_sqlite`](https://pub.dev/packages/flutter_gemma_rag_sqlite).**
> Version 1.5.0 also moves RAG orchestration and contracts into
> `flutter_edge_ai_rag`: replace the old dependency/imports, add
> `flutter_edge_ai_rag`, and register `SqliteVectorStoreProvider()` in
> `FlutterEdgeAiRag`. Existing profile-less stores require verified, explicit
> adoption or re-indexing. See the
> [migration guide](https://flutteredge.ai/docs/migration).

First-class SQLite vector-store provider for
[flutter_edge_ai_rag](https://pub.dev/packages/flutter_edge_ai_rag).
KNN runs **inside SQLite** via [`sqlite-vec`](https://github.com/asg017/sqlite-vec)
(`vec0` virtual table) — no Dart brute-force, no in-memory index.

Register `SqliteVectorStoreProvider` once; it selects the implementation:
- **Native** (Android/iOS/macOS/Linux/Windows): `SqliteVectorStore` — `package:sqlite3`
  (dart:ffi) + the per-platform `vec0` loadable extension.
- **Web**: `WebSqliteVectorStore` — `package:sqlite3/wasm.dart` driving a custom
  `sqlite3.wasm` with `sqlite-vec`/`vec0` statically linked.

Both arms speak the same `vec0` SQL dialect, so KNN and `Filter` behave
identically across all six platforms. A `vec0` table declares an `id TEXT
PRIMARY KEY`, so KNN returns the document id directly — no JOIN, no rowid bridge.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills from the Flutter Edge AI package graph. The
`flutter-edge-ai-rag` skill covers embedding models, both vector stores, and
metadata filters.

## Usage

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

final rag = FlutterEdgeAiRag(
  providers: [const SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(providerId: 'sqlite', location: databasePath),
  embeddingProfile: EmbeddingProfile(
    id: 'my-embedder-v1',
    dimension: 768,
  ),
);

await index.addVector(
  id: 'doc-1',
  content: 'Flutter Edge AI runs on-device.',
  embedding: documentVector,
);
final hits = await index.searchVector(embedding: queryVector);
await index.dispose();
```

For text RAG with the active core embedder, replace `embeddingProfile` with a
stable `activeEmbedderProfileId` and use `addText` / `searchText`. For a custom
embedder, pass `embedder:` to `open()`; neither path makes the RAG registry a
singleton. Dispose the index before `FlutterEdgeAi.dispose()` or before
disposing the borrowed custom embedder.

The provider removes the application-level `kIsWeb` branch. Use a stable
profile ID that versions the weights, tokenizer, pooling, normalization, and
document/query prefix contract. The profile is stored beside the vectors and
prevents a location from being reopened with an incompatible embedder.

Databases created before 1.5.0 contain vectors but no stored profile. Open a known
legacy database with `allowLegacyProfileAdoption: true` only after verifying
the exact embedder that created it; the RAG layer checks its dimension before
persisting the first profile. Leave the flag false for unverified data.

`searchSimilar` returns **cosine similarity** (1 = identical, higher = better),
sorted descending, filtered by `threshold` — the same contract as the qdrant
store (vec0 returns distance; the store converts `1 - distance` at the boundary).

`index.flush()` is a no-op on native: the connection
autocommits, so a statement that returned is on disk. On web it drains the
IndexedDB storage and waits for it. `sqlite3` 3.4.0 through 3.5.2 returned
early over a write batch already in flight (upstream
[sqlite3.dart#408](https://github.com/simolus3/sqlite3.dart/issues/408)), which
is why this package requires 3.6.0 and, with it, Flutter 3.47; `close()` drains
on every version. When neither OPFS nor IndexedDB is available
the store runs in memory, and `flush()` throws `VectorStoreException`.

On web, one `location` may be open by only one `WebSqliteVectorStore` at a
time. The store holds an exclusive [Web Lock](https://developer.mozilla.org/docs/Web/API/Web_Locks_API)
for its complete lifetime, so another tab, worker, or store instance fails
immediately with an actionable `VectorStoreException` instead of opening a
second IndexedDB/OPFS snapshot. Current Chrome, Edge, Firefox, and Safari
releases expose Web Locks. The API is feature-detected: a runtime or insecure
context without `navigator.locks` fails closed with `VectorStoreException`
before opening OPFS or IndexedDB, because it cannot safely coordinate another
tab or worker. Always call `index.dispose()` or `store.close()` before reopening
that location. The in-memory VFS remains a last resort only when Web Locks are
available but persistent browser storage is not; it cannot bind a durable
embedding profile, so `FlutterEdgeAiRag.open()` rejects it.

## Declared-column filters

`vec0` filters KNN only on **declared, typed metadata columns** (not arbitrary
JSON). Declare the filterable fields in `VectorStoreSpec.filterSchema`; the store
promotes those fields out of each document's metadata JSON into real columns and
translates `Filter` (`must`/`should`/`mustNot`) into a vec0 `WHERE`:

```dart
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'lang', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
      FilterField(name: 'archived', type: FilterFieldType.bool),
    ]),
  ),
  embeddingProfile: EmbeddingProfile(id: 'my-embedder-v1', dimension: 768),
);

// later, at query time:
final hits = await index.searchVector(
  embedding: queryVec,
  topK: 10,
  filter: Filter(
    must:    [FieldRange(key: 'year', gte: 2000)],
    mustNot: [FieldEquals(key: 'archived', value: true)],
  ),
);
```

`FilterField.name` must match `^[A-Za-z][A-Za-z0-9_]*$`, and must not be a name
vec0 already declares: `id`, `embedding`, `content`, `metadata`, and the hidden
`distance` and `k`. `configure()` throws an `ArgumentError` otherwise — at that
call, not at the first `addDocument`, which is when the table is really built.

The name becomes a real `vec0` column, and sqlite-vec's DDL grammar accepts no
quoted identifier form (`"doc-type"`, `[doc-type]` and `` `doc-type` `` all
fail), so a name outside that set is unrepresentable rather than merely
unescaped. qdrant accepts most of these names, so a schema written for it may be
refused here — this set is the portable one.

Filtering on an **undeclared** key is a safe no-op (never throws). With no
`filterSchema`, the store ignores filters entirely — identical to `filter: null`.
Supported operators: `=`, `!=`, `>`, `>=`, `<`, `<=`, `BETWEEN`, `IN`
(`FieldEquals`, `FieldRange`, `FieldMatchAny`); max 16 declared columns.

## Upgrading from 1.0.x

**1.1.0 does not read an index written by 1.0.x.** The switch to in-SQLite
`vec0` KNN moved the data from a plain `documents` table into a `vec_documents`
virtual table. Nothing errors on upgrade: `initialize()` succeeds, `getStats()`
reports 0 documents, `searchSimilar()` returns no hits, and the old rows sit
untouched in `documents`. This was not called out when 1.1.0 shipped.

Your data is intact and needs no re-embedding — 1.0.x stored the vector as a
`Float32` BLOB alongside the id, content and metadata. Move it once:

```dart
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';   // add sqlite3 to your own pubspec

final store = SqliteVectorStore();
await store.initialize(path);

final db = sqlite3.open(path);
final hasLegacy = db
    .select("SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='documents'")
    .isNotEmpty;

if (hasLegacy) {
  final rows = db.select(
    'SELECT id, content, embedding, metadata FROM documents',
  );
  if (rows.isNotEmpty) {
    final first = rows.first['embedding'] as Uint8List;
    await store.bindEmbeddingProfile(
      EmbeddingProfile(
        id: 'the-original-embedder-v1',
        dimension: first.length ~/ 4,
      ),
    );
  }
  for (final row in rows) {
    // 1.0.x wrote each element with setFloat32(..., Endian.little); read it
    // back the same way. ByteData.sublistView needs no 4-byte alignment,
    // which a raw asFloat32List view of the BLOB would.
    final bytes = ByteData.sublistView(row['embedding'] as Uint8List);
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
db.close();
```

Dropping the table is what makes the block a no-op on later launches. There is
no built-in migration call — this is a one-time fix for an upgrade that has
already happened. Full write-up in the
[migration guide](https://flutteredge.ai/docs/migration).

## Setup

**Native** needs no setup — the `vec0` loadable extension is fetched per platform
by this package's Native Assets hook (`hook/build.dart`), SHA256-verified, and
loaded automatically before any database is opened.

**New in 1.3.0:** that fetch is real. Until 1.2.0 the loadables were committed
into the package, so every install carried all seven platforms' binaries to use
one of them. They now come from this repository's `native-sqlite-vec-v*` GitHub
Release, which means the **first** build of each platform needs `github.com`
reachable; the library is cached under `~/.cache/flutter_gemma/native/`
(`~/Library/Caches/…` on macOS, `%LOCALAPPDATA%\…` on Windows) and later builds
do not go out again. `flutter_edge_ai_litertlm` has always worked this way. If you
build in an air-gapped environment, pre-populate that cache directory.

**Web** ships the custom `sqlite3.wasm` (with `sqlite-vec` linked in) as the
package web asset `web/rag/sqlite3.wasm`. Copy it into your app's web root so it
sits next to `index.html` at `rag/sqlite3.wasm` — that's the URL
`WasmSqlite3.loadFromUrl` fetches. Resolve the package directory with
`dart pub deps`/`flutter pub` (the path printed by your IDE) and copy the asset:

```sh
mkdir -p web/rag
# <pkg> = the flutter_edge_ai_sqlite directory in your pub cache / workspace
cp <pkg>/web/rag/sqlite3.wasm web/rag/sqlite3.wasm
```

OPFS persistence and `SharedArrayBuffer` require your web server to send the
cross-origin isolation headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

There is no CDN `<script>`, no wa-sqlite worker, and no `index.html` wiring
anymore.
