// Covers the FlutterEdgeAi.rag.* namespace and removeDocument (interface →
// platform shell → vectorStoreRepository): add 2 docs, remove one, assert the
// store reports one left, and that removing an absent id is a no-op.
//
// Run: flutter test integration_test/rag_remove_document_test.dart -d macos
library;

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late String dbPath;

  setUpAll(() async {
    await FlutterEdgeAi.initialize(
      vectorStore: SqliteVectorStore(),
      inferenceEngines: const [LiteRtLmEngine()],
      embeddingBackends: const [LiteRtEmbeddingBackend()],
      embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    );
    dbPath = '${(await getTemporaryDirectory()).path}/e_removedoc.db';
  });

  testWidgets(
    'FlutterEdgeAi.rag namespace + removeDocument',
    (t) async {
      await FlutterEdgeAi.rag.initialize(dbPath);
      await FlutterEdgeAi.rag.clear();

      await FlutterEdgeAi.rag.addDocumentWithEmbedding(
        id: 'a',
        content: 'apple',
        embedding: [1.0, 0.0, 0.0],
      );
      await FlutterEdgeAi.rag.addDocumentWithEmbedding(
        id: 'b',
        content: 'banana',
        embedding: [0.0, 1.0, 0.0],
      );

      var stats = await FlutterEdgeAi.rag.stats();
      print('[E] after add: count=${stats.documentCount}');
      expect(stats.documentCount, 2);

      // The new plumbed path: rag.removeDocument → plugin → shell → repo.
      await FlutterEdgeAi.rag.removeDocument(id: 'a');

      stats = await FlutterEdgeAi.rag.stats();
      print('[E] after removeDocument(a): count=${stats.documentCount}');
      expect(stats.documentCount, 1, reason: 'exactly one doc removed');

      // removing an absent id is a no-op (must not throw)
      await FlutterEdgeAi.rag.removeDocument(id: 'a');

      await FlutterEdgeAi.rag.clear();
      try {
        await ServiceRegistry.instance.vectorStoreRepository.close();
      } catch (_) {}
      final f = File(dbPath);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
