import 'package:flutter_gemma/flutter_gemma.dart';

/// Non-web stub for [QdrantVectorStore]. qdrant-edge can't compile to WASM,
/// so on web every method throws; web RAG uses flutter_gemma_rag_sqlite's
/// WebSqliteVectorStore instead.
/// Mirror of the native arm's type so `on QdrantLegacyStoreException` compiles
/// on every platform. The stub never throws it — there is no store here to be
/// a 1.x one.
class QdrantLegacyStoreException extends VectorStoreException {
  const QdrantLegacyStoreException(super.message);
}

class QdrantVectorStore implements VectorStoreRepository {
  @override
  bool get isInitialized => false;

  @override
  bool enableHnsw = true;

  // qdrant-edge can't run on web, so there is nothing to make filterable —
  // [configure] is a no-op and the schema stays empty. (`implements` does not
  // inherit the abstract class's bodied defaults, so these must be declared.)
  @override
  FilterSchema get filterSchema => const FilterSchema();

  @override
  void configure(FilterSchema schema) {}

  @override
  Future<void> initialize(String databasePath) async =>
      throw UnimplementedError(
        'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
      );

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => throw UnimplementedError(
    'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
  );

  @override
  Future<void> removeDocument({required String id}) async =>
      throw UnimplementedError(
        'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
      );

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async => throw UnimplementedError(
    'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
  );

  @override
  Future<VectorStoreStats> getStats() async => throw UnimplementedError(
    'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
  );

  @override
  Future<void> clear() async => throw UnimplementedError(
    'QdrantVectorStore is native-only; qdrant-edge cannot run on web',
  );

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
