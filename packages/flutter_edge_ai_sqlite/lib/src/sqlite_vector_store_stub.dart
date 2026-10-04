import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

/// Stub for SqliteVectorStore on web/WASM platforms.
/// Web uses WebSqliteVectorStore (package:sqlite3/wasm + vec0) instead.
class SqliteVectorStore implements VectorStoreRepository {
  SqliteVectorStore({Future<void> Function()? durabilityFenceForTesting});

  /// Present only so the stub keeps the same surface as the native class.
  ///
  /// A member added to the native arm and not here is an error `flutter test`
  /// never sees and `flutter build web` reports much later — the stub drift
  /// this repo has been bitten by before, so the two arms are kept in step by
  /// hand.
  ///
  /// (An earlier version of this comment claimed analysis resolves the
  /// conditional export to THIS file. It does not: the analyzer sees the VM
  /// SDK, which has dart:ffi, so it picks the native arm. The conclusion holds
  /// for the web BUILD, not for analysis.)
  static String? debugOverrideDylibPath;

  @override
  bool get isInitialized => false;

  @override
  FilterSchema get filterSchema => FilterSchema.empty;

  @override
  void configure(FilterSchema schema) {}

  @override
  Future<void> initialize(String databasePath) async =>
      throw UnimplementedError(
        'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
      );

  @override
  Future<EmbeddingProfile?> readEmbeddingProfile() async =>
      throw UnimplementedError(
        'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
      );

  @override
  Future<void> bindEmbeddingProfile(EmbeddingProfile profile) async =>
      throw UnimplementedError(
        'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
      );

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => throw UnimplementedError(
    'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
  );

  @override
  Future<void> removeDocument({required String id}) async =>
      throw UnimplementedError(
        'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
      );

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async => throw UnimplementedError(
    'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
  );

  @override
  Future<VectorStoreStats> getStats() async => throw UnimplementedError(
    'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
  );

  @override
  Future<void> clear() async => throw UnimplementedError(
    'SqliteVectorStore is not available on web; use WebSqliteVectorStore',
  );

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
