// Writes, with THIS checkout's packages, the stores the published releases
// must refuse (and one text store per backend they must still open), plus the
// manifest the published side reads. Run by ../run_downgrade_harness.sh.

import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('writes every harness store and the manifest', () async {
    final root = requireEnv('RAG_COMPAT_STORES');
    useHostVec0();
    final rag = FlutterEdgeAiRag(
      providers: const [
        SqliteVectorStoreProvider(),
        QdrantVectorStoreProvider(),
      ],
    );

    for (final store in compatStores) {
      final location = locationOf(root, store);
      expect(
        FileSystemEntity.typeSync(location),
        FileSystemEntityType.notFound,
        reason: 'the harness writes into a fresh directory',
      );
      final index = await rag.openVectors(
        spec: VectorStoreSpec(
          providerId: store.backend,
          location: location,
          documents: store.documents,
        ),
        profile: compatProfile,
      );
      for (final (id, content, vector) in compatDocuments.take(
        store.documentCount,
      )) {
        await index.addVector(id: id, content: content, embedding: vector);
      }
      await index.flush();
      expect((await index.stats()).documentCount, store.documentCount);
      await index.dispose();
    }
    writeManifest(root);
  });
}
