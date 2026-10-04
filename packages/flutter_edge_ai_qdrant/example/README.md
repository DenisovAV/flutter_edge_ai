# flutter_edge_ai_qdrant example

`flutter_edge_ai_qdrant` is an opt-in vector store for
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai). Register it once at
startup, then use the unchanged RAG API on `FlutterEdgeAiPlugin.instance`.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opt into the qdrant-edge native vector store.
  await FlutterEdgeAi.initialize(
    vectorStore: QdrantVectorStore(),
  );

  final gemma = FlutterEdgeAiPlugin.instance;

  // `path` is a shard DIRECTORY (qdrant creates files under it), not a .db file.
  await gemma.initializeVectorStore('rag_store');

  // Add documents with pre-computed embeddings (e.g. from
  // flutter_edge_ai_embeddings). `metadata` is a raw JSON string.
  await gemma.addDocumentWithEmbedding(
    id: 'doc-1',
    content: 'Gemma runs fully on-device.',
    embedding: List<double>.filled(768, 0.0), // your real embedding here
    metadata: '{"lang":"en"}',
  );

  // Plain similarity search.
  final hits = await gemma.searchSimilar(query: 'on-device LLM', topK: 5);
  for (final h in hits) {
    print('${h.id}: ${h.content} (score ${h.similarity})');
  }

  // Payload-aware filtering (native only).
  final enHits = await gemma.searchSimilar(
    query: 'on-device LLM',
    topK: 5,
    filter: Filter(must: [FieldEquals(key: 'lang', value: 'en')]),
  );
  print('English hits: ${enHits.length}');
}
```

See the [package README](https://pub.dev/packages/flutter_edge_ai_qdrant) for
platform support and behavior notes. A full runnable app that wires every engine
and RAG store together lives in the
[`flutter_edge_ai` example](https://github.com/DenisovAV/flutter_edge_ai/tree/main/packages/flutter_edge_ai/example).
