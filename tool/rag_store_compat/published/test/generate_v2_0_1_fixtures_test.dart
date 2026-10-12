// Writes the v2_0_1 store fixtures with the PUBLISHED packages, so the
// fixtures are what an app on flutter_edge_ai_sqlite 2.0.1 /
// flutter_edge_ai_qdrant 2.0.1 left on disk, not a reconstruction of it.
//
// Run through ../generate_v2_0_1_fixtures.sh, which copies the result into
// packages/flutter_edge_ai_{sqlite,qdrant}/test/fixtures/v2_0_1/. The train's
// fixture tests (fixture_v2_0_1_test.dart in both packages) pin the same
// profile, documents and vectors as below.

import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

/// Two text documents, 4-dimensional, bound to one text profile.
final fixtureProfile = EmbeddingProfile(id: 'fixture-text-v1', dimension: 4);
const fixtureDocuments = [
  ('doc-a', 'alpha', <double>[1, 0, 0, 0], '{"lang":"en"}'),
  ('doc-b', 'beta', <double>[0, 1, 0, 0], '{"lang":"de"}'),
];

Future<void> _write(FlutterEdgeAiRag rag, String providerId, String at) async {
  final index = await rag.open(
    spec: VectorStoreSpec(providerId: providerId, location: at),
    embeddingProfile: fixtureProfile,
  );
  for (final (id, content, vector, metadata) in fixtureDocuments) {
    await index.addVector(
      id: id,
      content: content,
      embedding: vector,
      metadata: metadata,
    );
  }
  await index.flush();
  expect((await index.stats()).documentCount, fixtureDocuments.length);
  await index.dispose();
}

void main() {
  test(
    'writes a text-bound sqlite 2.0.1 store and qdrant 2.0.1 store',
    () async {
      final out = requireEnv('RAG_COMPAT_OUT');
      useHostVec0();
      final rag = FlutterEdgeAiRag(
        providers: const [
          SqliteVectorStoreProvider(),
          QdrantVectorStoreProvider(),
        ],
      );

      final sqlitePath = p.join(out, 'sqlite', 'text_store.db');
      Directory(p.dirname(sqlitePath)).createSync(recursive: true);
      await _write(rag, SqliteVectorStoreProvider.providerId, sqlitePath);

      final qdrantPath = p.join(out, 'qdrant', 'text_store');
      Directory(qdrantPath).createSync(recursive: true);
      await _write(rag, 'qdrant', qdrantPath);
    },
  );
}
