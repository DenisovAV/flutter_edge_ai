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

  // After the published releases wrote to them without a text index, the
  // train's text search reflects exactly those writes: the index is
  // reconciled with vec0 on open, also by an open without enableTextSearch.
  test('sqlite text search reflects the published writes', () async {
    final root = requireEnv('RAG_COMPAT_STORES');
    useHostVec0();
    final rag = FlutterEdgeAiRag(
      providers: const [SqliteVectorStoreProvider()],
    );
    Future<Map<String, List<String>>> search(String name) async {
      final index = await rag.openVectors(
        spec: VectorStoreSpec(
          providerId: 'sqlite',
          location: textSearchLocation(root, name),
        ),
        profile: compatProfile,
      );
      final result = {
        for (final term in ['alpha', 'beta', 'gamma', 'delta'])
          term: [for (final h in await index.searchText(text: term)) h.id],
      };
      await index.dispose();
      return result;
    }

    expect(await search('edit'), {
      'alpha': <String>[],
      'beta': <String>[],
      'gamma': ['doc-a'],
      'delta': ['doc-c'],
    });
    expect(await search('clear'), {
      'alpha': <String>[],
      'beta': <String>[],
      'gamma': ['doc-a'],
      'delta': ['doc-b'],
    });
  });
}
