# flutter_edge_ai_sqlite example

`flutter_edge_ai_sqlite` is an opt-in vector-store provider for
[`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag) that works on every
platform: in-SQLite `sqlite-vec`/`vec0` KNN on native (`sqlite3` via dart:ffi)
and web (`package:sqlite3/wasm` + a custom `sqlite3.wasm`).
Register it once and open independently owned RAG indexes.

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

Future<void> buildIndex() async {
  final rag = FlutterEdgeAiRag(
    providers: [const SqliteVectorStoreProvider()],
  );
  final index = await rag.open(
    spec: VectorStoreSpec(providerId: 'sqlite', location: 'rag_store.db'),
    embeddingProfile: EmbeddingProfile(
      id: 'my-embedder-v1',
      dimension: 768,
    ),
  );

  // Add a document with a pre-computed embedding (e.g. from
  // flutter_edge_ai_litertlm or flutter_edge_ai_onnx).
  await index.addVector(
    id: 'doc-1',
    content: 'Flutter Edge AI runs fully on-device.',
    embedding: List<double>.filled(768, 0.0), // your real embedding here
    metadata: '{"lang":"en"}',
  );

  final hits = await index.searchVector(
    embedding: List<double>.filled(768, 0.0), // your real query vector
    topK: 5,
  );
  for (final h in hits) {
    print('${h.id}: ${h.content} (score ${h.similarity})');
  }
  await index.dispose();
}
```

On web, the custom `sqlite3.wasm` (with `sqlite-vec` linked in) is served as a
web asset — no CDN `<script>` is needed; see the
[package README](https://pub.dev/packages/flutter_edge_ai_sqlite) for the
wasm wiring. Native platforms need no setup (`sqlite3` bundles its own library;
the `vec0` extension is bundled via the package's Native Assets hook). A full runnable app wiring every engine and RAG store together lives
in the
[`flutter_edge_ai` example](https://github.com/DenisovAV/flutter_edge_ai/tree/main/packages/flutter_edge_ai/example).
