// The published flutter_edge_ai_qdrant 2.0.1 (engine 0.8) on qdrant stores the
// train wrote with qdrant_edge 0.9 and a text index: it reads one and writes to
// the other. verify_train_stores_test.dart then checks what the train sees.
// Run by ../run_downgrade_harness.sh.

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

final _profile = EmbeddingProfile(id: 'compat-v1', dimension: 4);

Future<RagIndex> _open(String name) {
  final root = requireEnv('RAG_COMPAT_STORES');
  return FlutterEdgeAiRag(providers: const [QdrantVectorStoreProvider()]).open(
    spec: VectorStoreSpec(
      providerId: 'qdrant',
      location: p.join(root, 'qdrant_text_search_$name'),
    ),
    embeddingProfile: _profile,
  );
}

void main() {
  test('read: opens and searches without writing', () async {
    final index = await _open('read');
    expect((await index.stats()).documentCount, 2);
    final hits = await index.searchVector(embedding: const [0, 1, 0, 0]);
    expect(hits.first.id, 'doc-b');
    await index.dispose();
  });

  test('write: an upsert, a remove and an add', () async {
    final index = await _open('write');
    await index.addVector(
      id: 'doc-a',
      content: 'gamma',
      embedding: const [1, 0, 0, 0],
    );
    await index.remove(id: 'doc-b');
    await index.addVector(
      id: 'doc-c',
      content: 'delta',
      embedding: const [0, 0, 1, 0],
    );
    await index.flush();
    await index.dispose();
  });
}
