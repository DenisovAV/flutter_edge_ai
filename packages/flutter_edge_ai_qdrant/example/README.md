# flutter_edge_ai_qdrant example

`flutter_edge_ai_qdrant` is an opt-in native vector-store provider for
[`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag).

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final rag = FlutterEdgeAiRag(
    providers: [QdrantVectorStoreProvider()],
  );

  // An absolute path to a shard directory, not a .db file.
  final dir = await getApplicationDocumentsDirectory();
  final index = await rag.open(
    spec: VectorStoreSpec(
      providerId: 'qdrant',
      location: '${dir.path}/rag_store',
      filterSchema: FilterSchema(
        fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
      ),
    ),
    embeddingProfile: EmbeddingProfile(
      id: 'my-embedder-v1',
      dimension: 4,
    ),
  );

  await index.addVector(
    id: 'doc-1',
    content: 'Gemma runs fully on-device.',
    embedding: const [1.0, 0.0, 0.0, 0.0],
    metadata: '{"lang":"en"}',
  );

  final hits = await index.searchVector(
    embedding: const [1.0, 0.0, 0.0, 0.0],
    topK: 5,
  );
  for (final h in hits) {
    print('${h.id}: ${h.content} (score ${h.similarity})');
  }

  // Payload-aware filtering (native only).
  final enHits = await index.searchVector(
    embedding: const [1.0, 0.0, 0.0, 0.0],
    topK: 5,
    filter: Filter(must: [FieldEquals(key: 'lang', value: 'en')]),
  );
  print('English hits: ${enHits.length}');

  await index.flush();
  await index.dispose();
}
```

This example is vector-only and does not initialize the main inference
runtime. For `addText` and `searchText`, first initialize `FlutterEdgeAi` and
install its active embedding model, then pass a stable
`activeEmbedderProfileId` to `rag.open()`. The ID must version the weights,
tokenizer, pooling, normalization, and document/query prefix contract.

For an existing nonempty store created without profile metadata, pass an
explicit `EmbeddingProfile` and set `allowLegacyProfileAdoption: true` only
after verifying which embedding model created those vectors.

See the [package README](https://pub.dev/packages/flutter_edge_ai_qdrant) for
platform support and behavior notes. A full runnable app that wires every engine
and RAG store together lives in the
[`flutter_edge_ai` example](https://github.com/DenisovAV/flutter_edge_ai/tree/main/packages/flutter_edge_ai/example).
