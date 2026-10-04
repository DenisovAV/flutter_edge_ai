// Proves that RAG can initialize independently from FlutterEdgeAi.initialize:
// open a vector-only index, add two documents, remove one, and close it.
//
// Run: flutter test integration_test/rag_remove_document_test.dart -d macos
library;

import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'independent RagIndex removes one document and ignores an absent id',
    (tester) async {
      final dbPath =
          '${(await getTemporaryDirectory()).path}/e_removedoc_${DateTime.now().microsecondsSinceEpoch}.db';
      final rag = FlutterEdgeAiRag(
        providers: [const SqliteVectorStoreProvider()],
      );
      final index = await rag.open(
        spec: VectorStoreSpec(providerId: 'sqlite', location: dbPath),
        embeddingProfile: EmbeddingProfile(
          id: 'remove-document-test-v1',
          dimension: 3,
        ),
      );
      addTearDown(() async {
        await index.dispose();
        final file = File(dbPath);
        if (await file.exists()) await file.delete();
      });

      await index.addVector(
        id: 'a',
        content: 'apple',
        embedding: const [1.0, 0.0, 0.0],
      );
      await index.addVector(
        id: 'b',
        content: 'banana',
        embedding: const [0.0, 1.0, 0.0],
      );

      expect((await index.stats()).documentCount, 2);
      await index.remove(id: 'a');
      expect((await index.stats()).documentCount, 1);

      await index.remove(id: 'a');
      expect((await index.stats()).documentCount, 1);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
