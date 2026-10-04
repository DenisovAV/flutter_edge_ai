# flutter_edge_ai_sqlite

> **Renamed from [`flutter_gemma_rag_sqlite`](https://pub.dev/packages/flutter_gemma_rag_sqlite).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_rag_sqlite/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

First-class SQLite vector store for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai).
KNN runs **inside SQLite** via [`sqlite-vec`](https://github.com/asg017/sqlite-vec)
(`vec0` virtual table) — no Dart brute-force, no in-memory index.

Opt-in package implementing `VectorStoreRepository`:
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

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-rag`, covers embedding models, both vector stores, and the metadata filters — including the `filterSchema` trap that silently returns unfiltered results.

## Usage

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

await FlutterEdgeAi.initialize(
  vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
);
```

`searchSimilar` returns **cosine similarity** (1 = identical, higher = better),
sorted descending, filtered by `threshold` — the same contract as the qdrant
store (vec0 returns distance; the store converts `1 - distance` at the boundary).

`flush()` (`FlutterEdgeAi.rag.flush()`) is a no-op on native: the connection
autocommits, so a statement that returned is on disk. On web it drains the
IndexedDB storage and waits for it. `sqlite3` 3.4.0 through 3.5.2 returned
early over a write batch already in flight (upstream
[sqlite3.dart#408](https://github.com/simolus3/sqlite3.dart/issues/408)), which
is why this package requires 3.6.0 and, with it, Flutter 3.47; `close()` drains
on every version. When neither OPFS nor IndexedDB is available
the store runs in memory, and `flush()` throws `VectorStoreException`.

## Declared-column filters

`vec0` filters KNN only on **declared, typed metadata columns** (not arbitrary
JSON). Declare the filterable fields once at init via `filterSchema:`; the store
promotes those fields out of each document's metadata JSON into real columns and
translates `Filter` (`must`/`should`/`mustNot`) into a vec0 `WHERE`:

```dart
await FlutterEdgeAi.initialize(
  vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
  filterSchema: const FilterSchema(fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'year', type: FilterFieldType.number),
    FilterField(name: 'archived', type: FilterFieldType.bool),
  ]),
);

// later, at query time:
final hits = await store.searchSimilar(
  queryEmbedding: queryVec,
  topK: 10,
  filter: const Filter(
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
  for (final row
      in db.select('SELECT id, content, embedding, metadata FROM documents')) {
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
