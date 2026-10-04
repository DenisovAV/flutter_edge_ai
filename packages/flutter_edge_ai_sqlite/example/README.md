# flutter_edge_ai_sqlite example

`flutter_edge_ai_sqlite` is an opt-in vector store for
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai) that works on every
platform: in-SQLite `sqlite-vec`/`vec0` KNN on native (`sqlite3` via dart:ffi)
and web (`package:sqlite3/wasm` + a custom `sqlite3.wasm`).
Register it once at startup, then use the unchanged RAG API on
`FlutterEdgeAiPlugin.instance`.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native uses SqliteVectorStore; web uses WebSqliteVectorStore.
  await FlutterEdgeAi.initialize(
    vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
  );

  final gemma = FlutterEdgeAiPlugin.instance;

  await gemma.initializeVectorStore('rag_store.db');

  // Add a document with a pre-computed embedding (e.g. from
  // flutter_edge_ai_embeddings).
  await gemma.addDocumentWithEmbedding(
    id: 'doc-1',
    content: 'Gemma runs fully on-device.',
    embedding: List<double>.filled(768, 0.0), // your real embedding here
    metadata: '{"lang":"en"}',
  );

  final hits = await gemma.searchSimilar(query: 'on-device LLM', topK: 5);
  for (final h in hits) {
    print('${h.id}: ${h.content} (score ${h.similarity})');
  }
}
```

On web, the custom `sqlite3.wasm` (with `sqlite-vec` linked in) is served as a
web asset — no CDN `<script>` is needed; see the
[package README](https://pub.dev/packages/flutter_edge_ai_sqlite) for the
wasm wiring. Native platforms need no setup (`sqlite3` bundles its own library;
the `vec0` extension is bundled via the package's Native Assets hook). A full runnable app wiring every engine and RAG store together lives
in the
[`flutter_edge_ai` example](https://github.com/DenisovAV/flutter_edge_ai/tree/main/packages/flutter_edge_ai/example).
