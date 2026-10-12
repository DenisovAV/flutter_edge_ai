// After the published releases tried every way to open, adopt and rebind the
// train's stores, each still has the binding and the documents the train wrote:
// an older writer cannot rebind (R5 §6.5). Run by ../run_downgrade_harness.sh.

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  for (final store in compatStores) {
    test(
      '${store.backend} ${store.name}: binding and documents intact',
      () async {
        final root = requireEnv('RAG_COMPAT_STORES');
        useHostVec0();
        final rag = FlutterEdgeAiRag(
          providers: const [
            SqliteVectorStoreProvider(),
            QdrantVectorStoreProvider(),
          ],
        );
        final index = await rag.openVectors(
          spec: VectorStoreSpec(
            providerId: store.backend,
            location: locationOf(root, store),
            documents: store.documents,
          ),
          profile: compatProfile,
        );
        expect(index.documents, store.documents);
        expect(index.embeddingProfile, compatProfile);
        expect((await index.stats()).documentCount, store.documentCount);
        if (store.documentCount > 0) {
          final hits = await index.searchVector(embedding: const [0, 1, 0, 0]);
          expect(hits.first.id, 'doc-b');
        }
        await index.dispose();
      },
    );
  }
}
