## 2.0.1
- Allow `code_assets` 2.x, which other native plugins now require (#603).

## 2.0.0
- **Breaking:** now a `flutter_edge_ai_rag` storage provider; a location binds one embedding profile.

## 1.4.0
- Renamed from `flutter_gemma_rag_sqlite`.
- Require sqlite3 3.6.0 (needs Flutter 3.47): web `flush()` awaits in-flight writes.

## 1.3.2
- Add `flush()`; on web it drains IndexedDB — only partly on sqlite3 >=3.4 (#492).

## 1.3.1
- Fix web inserts failing on a numeric metadata value or a missing number field.
- Fix web filters with a `mustNot` upper bound returning the negative values they exclude.

## 1.3.0
- Fetch `vec0` from the `native-sqlite-vec-v*` release, so an updated library reaches the build.
- Fix `isInitialized` reporting true after an `initialize()` that threw.
- Fix re-initializing onto another database keeping the old vector size.
- Fix the web store reporting an empty corpus, and a successful delete, over data it could not read.
- Fix the iOS `vec0` declaring the wrong minimum OS (App Store ITMS-90208).
- Document the 1.0.x index break and how to move the old rows.

## 1.2.0
- **Breaking:** reject schema names vec0 cannot represent, including `distance` and `k`.
- Fix `mustNot` and unpushable filters silently returning fewer rows than `topK`, or none.
- Fix a document missing one declared metadata field being un-insertable.
- Fix `FieldMatchAny` on a number field throwing instead of matching.
- Fix the web arm rejecting integer metadata the native arm accepts.

## 1.1.0
- Un-deprecated: first-class on-device vector store on all 6 platforms with in-SQLite KNN via `sqlite-vec`/`vec0`; removed Dart brute-force + HNSW.
- **Breaking:** a 1.0.x index is not carried over; see the migration guide.
- Declared-column `Filter` (must/should/mustNot) via `configure(FilterSchema)`; undeclared keys no-op. Requires `flutter_gemma ^1.1.0`.
- Web rewritten on `package:sqlite3/wasm.dart` + a custom `sqlite3.wasm` (vec0 statically linked); wa-sqlite worker dropped.
- Per-platform `vec0` loadable bundled in-package via Native Assets; Android `.so` rebuilt 16 KB-aligned for Android 15 / Play targetSdk 35+ (#319).
- `enableHnsw` is now a deprecated no-op (search runs in SQLite).

## 1.0.1
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0.0; RAG logging routed through `gemmaLog` (silent in release builds).

## 1.0.0-rc.1
- Initial release: SQLite + HNSW on-device RAG vector store for flutter_gemma.
- Provides `SqliteVectorStore` (native, sqlite3) and `WebSqliteVectorStore` (web, wa-sqlite); implements VectorStoreRepository.
- All platforms (native sqlite3 + web wa-sqlite).
