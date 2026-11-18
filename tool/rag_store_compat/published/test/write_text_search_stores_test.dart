// The published releases (flutter_edge_ai_rag 1.0.0, flutter_edge_ai_sqlite
// 2.0.1) know nothing about the text index the train adds next to vec0. They
// open such a store as an ordinary text store and write vec0 only. The train
// must then see exactly these writes in its text search
// (verify_train_stores_test.dart). Run by ../run_downgrade_harness.sh.

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

final _profile = EmbeddingProfile(id: 'compat-v1', dimension: 4);

Future<RagIndex> _open(String name) {
  final root = requireEnv('RAG_COMPAT_STORES');
  return FlutterEdgeAiRag(providers: const [SqliteVectorStoreProvider()]).open(
    spec: VectorStoreSpec(
      providerId: 'sqlite',
      location: p.join(root, 'sqlite_text_search_$name.db'),
    ),
    embeddingProfile: _profile,
  );
}

void main() {
  test('edit: upsert, remove and add without the text index', () async {
    useHostVec0();
    final index = await _open('edit');
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
    expect((await index.stats()).documentCount, 2);
    await index.dispose();
  });

  test('clear: clear and re-add the same ids and count', () async {
    useHostVec0();
    final index = await _open('clear');
    await index.clear();
    await index.addVector(
      id: 'doc-a',
      content: 'gamma',
      embedding: const [1, 0, 0, 0],
    );
    await index.addVector(
      id: 'doc-b',
      content: 'delta',
      embedding: const [0, 1, 0, 0],
    );
    await index.flush();
    expect((await index.stats()).documentCount, 2);
    await index.dispose();
  });
}
