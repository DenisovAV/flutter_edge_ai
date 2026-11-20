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

  // The published release (engine 0.8) read one qdrant store and wrote to the
  // other. Reading is harmless; writing breaks the shard for both engines,
  // which the README documents as a one-way upgrade. What this pins is that
  // the train then fails loudly instead of answering from the broken shard.
  test(
    'qdrant: a published read is harmless, a published write fails loudly',
    () async {
      final root = requireEnv('RAG_COMPAT_STORES');
      final rag = FlutterEdgeAiRag(
        providers: const [QdrantVectorStoreProvider()],
      );
      Future<RagIndex> open(String name) => rag.openVectors(
        spec: VectorStoreSpec(
          providerId: 'qdrant',
          location: qdrantDowngradeLocation(root, name),
        ),
        profile: compatProfile,
      );

      final read = await open('read');
      expect((await read.stats()).documentCount, compatDocuments.length);
      expect(
        [for (final h in await read.searchText(text: 'beta')) h.id],
        ['doc-b'],
      );
      await read.dispose();

      // Each read on its own must refuse: one that answers (even with []) is
      // the failure this check exists to catch, whatever the other one does.
      void expectFromShard(Object? error, String what) {
        expect(
          error,
          isA<VectorStoreException>(),
          reason:
              '$what on a shard the published release wrote to must '
              'not read as data',
        );
        // From the shard itself, not a refusal for another reason (binding,
        // profile) that would stop this check proving anything.
        final e = error! as VectorStoreException;
        final detail = '${e.message} ${e.cause}';
        expect(detail, isNot(contains('binding')), reason: what);
        expect(detail, isNot(contains('profile')), reason: what);
      }

      Future<Object?> failureOf(Future<Object?> Function() read) async {
        try {
          await read();
          return null;
        } on VectorStoreException catch (e) {
          return e;
        }
      }

      RagIndex? written;
      final openFailure = await failureOf(
        () async => written = await open('write'),
      );
      if (written == null) {
        // Refused at open: that is loud too.
        expectFromShard(openFailure, 'open');
      } else {
        final index = written!;
        try {
          expectFromShard(
            await failureOf(() => index.searchText(text: 'alpha')),
            'searchText',
          );
          expectFromShard(
            await failureOf(
              () => index.searchVector(embedding: const [1, 0, 0, 0]),
            ),
            'searchVector',
          );
        } finally {
          try {
            await index.dispose();
          } on VectorStoreException catch (_) {
            // Closing a broken shard may report it too; the reads decided.
          }
        }
      }
    },
  );
}
