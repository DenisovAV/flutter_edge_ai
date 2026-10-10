## 2.0.1
- Allow `code_assets` 2.x, which other native plugins now require (#603).

## 2.0.0
- **Breaking:** now a `flutter_edge_ai_rag` storage provider; a location binds one embedding profile.

## 1.3.2
- Renamed from `flutter_gemma_rag_qdrant`.
- Use qdrant_edge 0.8.0-dev.4 to prevent native result and argument leaks.
- README: how to install the agent skills that cover this package.

## 1.3.1
- Add `flush()`; without it an index was lost when the process ended (#492).

## 1.3.0
- **Breaking:** moved onto the official `qdrant_edge` UniFFI SDK.
- **Breaking:** a 1.x store is not readable — remove its files, then re-index.
- **Breaking:** `clear()` empties the shard in place; it never deletes files.
- **Breaking:** `clear()` cannot reset the vector size; switching embedders needs a new path.
- Android x86_64 is now provisioned alongside arm64 (emulators, Chromebooks).
- A re-opened store now reports its contents without waiting for a write.
- A shard that cannot be opened is reported instead of read as empty.
- A shard held open elsewhere is reported as such, not as damaged.
- Concurrent `addDocument` calls no longer race each other's shard open.
- `configure()` rejects a field name that collides with a stored payload key.

## 1.2.0
- Encode filters by the declared field type, so both backends answer alike.
- **Breaking:** reject a field name containing `.` — qdrant reads it as a nested path.
- Fix numeric equality never matching a float payload (`4` vs `4.0`).
- Fix an unbounded `FieldRange` excluding every non-numeric document instead of matching all.

## 1.1.0
- Fix metadata filtering: declared `FilterSchema` fields are promoted to top-level payload keys, so `Filter` predicates actually match (previously narrowed to zero).
- Implement `configure(FilterSchema)`; requires `flutter_gemma ^1.1.0`.
- Correct the "~75×" search-speed claim to the re-measured ~5–11× vs the new in-SQLite vec0 store (was vs the deleted Dart brute-force path).

## 1.0.1
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0.0.
- Rebuild Android `.so` with 16KB page alignment for Android 15 / Play target SDK 35+ (#319; native tag qdrant-edge-v0.7.3).

## 1.0.0-rc.1
- Initial release: qdrant-edge on-device RAG vector store for flutter_gemma (native FFI; ~75× faster search than the legacy Dart brute-force sqlite store).
- Provides `QdrantVectorStore`; implements VectorStoreRepository. Honors the payload-aware `Filter` DSL.
- Native platforms only (Android, iOS, macOS, Linux, Windows); no web (use flutter_gemma_rag_sqlite).
