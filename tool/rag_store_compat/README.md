# RAG store compatibility harness

Two scratch packages, outside the workspace, that pin what an app that has not
upgraded runs against what the train writes (design R5 §6.5–6.6, train gate 6
of §9.3).

| Directory | Resolves | Used for |
|---|---|---|
| `published/` | hosted `flutter_edge_ai_rag` 1.0.0, `flutter_edge_ai_sqlite` 2.0.1, `flutter_edge_ai_qdrant` 2.0.1 (exact pins, `pubspec.lock` committed) | writing the v2_0_1 fixtures; refusing the train's image/audio stores |
| `train/` | this checkout's rag, sqlite, qdrant and core (path overrides) | writing the stores the published side opens; re-reading them afterwards |

- `run_downgrade_harness.sh` — the gate. The train writes, per backend, a text
  store, an image store with two documents, an empty image store and an audio
  store, all bound to the same profile. The published releases must refuse
  every image/audio store — opening with the profile, with
  `allowLegacyProfileAdoption`, through an embedder (no text operation may
  succeed), and the store-level rebind — while still opening and searching the
  text stores. The train then re-reads every store: binding and documents
  unchanged. Two more SQLite stores carry a text index
  (`enableTextSearch`); the published releases write to them without knowing
  it (an upsert, a remove and an add; a clear and a re-add of the same ids and
  count), and the train's text search must reflect exactly those writes.
  Two qdrant stores (qdrant_edge 0.9, with a text index) go to the published
  qdrant release: it only reads one, which must stay intact, and writes to
  the other, on which the train must then fail with `VectorStoreException`
  rather than answer (the move to 0.9 is one-way, see the qdrant README).
- `generate_v2_0_1_fixtures.sh` — regenerates the committed fixtures read by
  `packages/flutter_edge_ai_{sqlite,qdrant}/test/fixture_v2_0_1_test.dart`.

Both need network on the first run (hosted packages; the vec0 and qdrant
native libraries the hooks download) and a macOS or Linux host. Neither is part
of `tool/test_all.sh`.
