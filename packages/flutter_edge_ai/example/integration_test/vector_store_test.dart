import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Integration tests for the public RAG index over SQLite.
///
/// Tests full stack: RagIndex -> sqlite3 Dart FFI -> sqlite-vec.
/// Run: flutter test integration_test/vector_store_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final rag = FlutterEdgeAiRag(providers: [const SqliteVectorStoreProvider()]);
  RagIndex? currentIndex;
  String? currentPath;

  Future<RagIndex> openIndex({int dimension = 3}) async {
    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}/test_vector_store_${DateTime.now().microsecondsSinceEpoch}.db';
    final index = await rag.open(
      spec: VectorStoreSpec(providerId: 'sqlite', location: path),
      embeddingProfile: EmbeddingProfile(
        id: 'vector-store-${dimension}d-test-v1',
        dimension: dimension,
      ),
    );
    currentIndex = index;
    currentPath = path;
    return index;
  }

  Future<void> cleanupStore() async {
    final index = currentIndex;
    currentIndex = null;
    await index?.dispose();
    final path = currentPath;
    currentPath = null;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort: Windows may briefly retain a native file handle.
      }
    }
  }

  tearDown(cleanupStore);

  group('RagIndex SQLite integration', () {
    testWidgets('initializes an empty store', (tester) async {
      final index = await openIndex();
      final stats = await index.stats();
      expect(stats.documentCount, 0);
      expect(stats.vectorDimension, 0);
    });

    testWidgets('adds a document with a vector', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Hello, world!',
        embedding: const [1.0, 0.0, 0.0],
        metadata: '{"source": "test"}',
      );

      final stats = await index.stats();
      expect(stats.documentCount, 1);
      expect(stats.vectorDimension, 3);
    });

    testWidgets('searches similar documents', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Document about cats',
        embedding: const [1.0, 0.0, 0.0],
      );
      await index.addVector(
        id: 'doc2',
        content: 'Document about dogs',
        embedding: const [0.9, 0.1, 0.0],
      );
      await index.addVector(
        id: 'doc3',
        content: 'Document about cars',
        embedding: const [0.0, 1.0, 0.0],
      );

      final results = await index.searchVector(
        embedding: const [1.0, 0.0, 0.0],
        topK: 2,
        threshold: 0.5,
      );

      expect(results, hasLength(2));
      expect(results[0].id, 'doc1');
      expect(results[0].similarity, closeTo(1.0, 0.01));
      expect(results[1].id, 'doc2');
      expect(results[1].similarity, greaterThan(0.9));
    });

    testWidgets('reports stats', (tester) async {
      final index = await openIndex();
      for (var i = 0; i < 5; i++) {
        await index.addVector(
          id: 'doc$i',
          content: 'Document $i',
          embedding: [i.toDouble(), 0.0, 0.0],
        );
      }

      final stats = await index.stats();
      expect(stats.documentCount, 5);
      expect(stats.vectorDimension, 3);
    });

    testWidgets('clears documents', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Document 1',
        embedding: const [1.0, 0.0, 0.0],
      );
      expect((await index.stats()).documentCount, 1);

      await index.clear();
      expect((await index.stats()).documentCount, 0);
      expect(index.embeddingProfile?.dimension, 3);
    });

    testWidgets('rejects a mismatched vector dimension', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Document 1',
        embedding: const [1.0, 0.0, 0.0],
      );

      await expectLater(
        index.addVector(
          id: 'doc2',
          content: 'Document 2',
          embedding: const [1.0, 0.0, 0.0, 0.0],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    testWidgets('round-trips float vectors', (tester) async {
      final index = await openIndex(dimension: 5);
      const original = [0.123456789, -0.987654321, 0.5, 0.0, 1.0];
      await index.addVector(
        id: 'doc1',
        content: 'Test document',
        embedding: original,
      );

      final results = await index.searchVector(embedding: original, topK: 1);
      expect(results, hasLength(1));
      expect(results[0].id, 'doc1');
      expect(results[0].similarity, closeTo(1.0, 0.0001));
    });

    testWidgets('returns stored metadata', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Document with metadata',
        embedding: const [1.0, 0.0, 0.0],
        metadata: '{"author": "Alice", "date": "2024-11-18"}',
      );
      await index.addVector(
        id: 'doc2',
        content: 'Document without metadata',
        embedding: const [0.9, 0.1, 0.0],
      );

      final results = await index.searchVector(
        embedding: const [1.0, 0.0, 0.0],
        topK: 2,
      );
      expect(results, hasLength(2));
      expect(results[0].metadata, contains('Alice'));
      expect(results[1].metadata, isNull);
    });

    testWidgets('applies similarity threshold', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Very similar',
        embedding: const [1.0, 0.0, 0.0],
      );
      await index.addVector(
        id: 'doc2',
        content: 'Somewhat similar',
        embedding: const [0.7, 0.7, 0.0],
      );
      await index.addVector(
        id: 'doc3',
        content: 'Not similar',
        embedding: const [0.0, 1.0, 0.0],
      );

      final high = await index.searchVector(
        embedding: const [1.0, 0.0, 0.0],
        topK: 10,
        threshold: 0.8,
      );
      expect(high.map((result) => result.id), ['doc1']);

      final low = await index.searchVector(
        embedding: const [1.0, 0.0, 0.0],
        topK: 10,
      );
      expect(low, hasLength(3));
    });

    testWidgets('upserts a document by id', (tester) async {
      final index = await openIndex();
      await index.addVector(
        id: 'doc1',
        content: 'Original content',
        embedding: const [1.0, 0.0, 0.0],
        metadata: '{"version": 1}',
      );
      await index.addVector(
        id: 'doc1',
        content: 'Updated content',
        embedding: const [0.0, 1.0, 0.0],
        metadata: '{"version": 2}',
      );

      expect((await index.stats()).documentCount, 1);
      final results = await index.searchVector(
        embedding: const [0.0, 1.0, 0.0],
        topK: 1,
      );
      expect(results.single.content, 'Updated content');
      expect(results.single.metadata, contains('version": 2'));
    });
  });
}
