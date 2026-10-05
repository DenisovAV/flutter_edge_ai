# flutter_gemma_rag_sqlite example

`flutter_gemma_rag_sqlite` is an opt-in vector store for
[`flutter_gemma`](https://pub.dev/packages/flutter_gemma) that works on every
platform: in-SQLite `sqlite-vec`/`vec0` KNN on native (`sqlite3` via dart:ffi)
and web (`package:sqlite3/wasm` + a custom `sqlite3.wasm`).
Register it once at startup, then use the unchanged RAG API on
`FlutterGemmaPlugin.instance`.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_rag_sqlite/flutter_gemma_rag_sqlite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native uses SqliteVectorStore; web uses WebSqliteVectorStore.
  await FlutterGemma.initialize(
    vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
  );

  final gemma = FlutterGemmaPlugin.instance;

  await gemma.initializeVectorStore('rag_store.db');

  // Add a document with a pre-computed embedding (e.g. from
  // flutter_gemma_embeddings).
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
[package README](https://pub.dev/packages/flutter_gemma_rag_sqlite) for the
wasm wiring. Native platforms need no setup (`sqlite3` bundles its own library;
the `vec0` extension is bundled via the package's Native Assets hook). A full runnable app wiring every engine and RAG store together lives
in the
[`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example).
