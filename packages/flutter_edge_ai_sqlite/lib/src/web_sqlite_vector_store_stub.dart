import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

/// Web stub for VectorStoreRepository
///
/// This stub is used on non-web platforms where dart:js_interop is not available.
/// The actual web implementation is in web_sqlite_vector_store.dart.
class WebSqliteVectorStore implements VectorStoreRepository {
  WebSqliteVectorStore({
    bool forceBrowserLocksUnavailableForTesting = false,
    Future<void> Function()? durabilityFenceForTesting,
  });

  @override
  bool get isInitialized => false;

  @override
  Future<void> initialize(String databasePath) async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<EmbeddingProfile?> readEmbeddingProfile() async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<void> bindEmbeddingProfile(EmbeddingProfile profile) async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<void> removeDocument({required String id}) async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<VectorStoreStats> getStats() async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<void> clear() async {
    throw UnimplementedError(
      'WebSqliteVectorStore is only available on web; use SqliteVectorStore',
    );
  }

  @override
  Future<void> flush() async {
    // No-op for stub
  }

  @override
  Future<void> close() async {
    // No-op for stub
  }

  @override
  FilterSchema get filterSchema => const FilterSchema();

  @override
  void configure(FilterSchema schema) {}
}
