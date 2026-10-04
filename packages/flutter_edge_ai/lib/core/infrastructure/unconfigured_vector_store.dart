import 'package:flutter_edge_ai/core/services/vector_store_filter.dart';
import 'package:flutter_edge_ai/core/services/vector_store_repository.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';

/// Default `VectorStoreRepository` when no RAG package is wired in.
///
/// As of 1.0, flutter_edge_ai core ships NO built-in RAG backend on any platform
/// — RAG is opt-in. Add a RAG package and pass its store to
/// `FlutterEdgeAi.initialize(vectorStore: ...)`. Every method throws a clear,
/// actionable error naming the available packages so a consumer who calls RAG
/// without wiring a store knows exactly what to do.
class UnconfiguredVectorStore implements VectorStoreRepository {
  static Never _fail() => throw StateError(
    'No vector store is configured. flutter_edge_ai ships no built-in RAG '
    'backend. Add a RAG package to pubspec.yaml and pass its store to '
    'FlutterEdgeAi.initialize(vectorStore: ...):\n'
    '  • flutter_edge_ai_sqlite  → SqliteVectorStore() (native) / '
    'WebSqliteVectorStore() (web)\n'
    '  • flutter_edge_ai_qdrant  → QdrantVectorStore() (native only)',
  );

  @override
  bool get isInitialized => false;

  @override
  bool enableHnsw = true;

  @override
  Future<void> initialize(String databasePath) async => _fail();

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => _fail();

  @override
  Future<void> removeDocument({required String id}) async => _fail();

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async => _fail();

  @override
  Future<VectorStoreStats> getStats() async => _fail();

  @override
  Future<void> clear() async => _fail();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  // configure() and filterSchema are safe no-ops on the sentinel: the registry
  // calls configure() unconditionally at registration even when no RAG package
  // is wired, so it must never throw. The actionable _fail() error fires only
  // when an actual RAG operation (add/search/...) is attempted.
  @override
  FilterSchema get filterSchema => const FilterSchema();

  @override
  void configure(FilterSchema schema) {}
}
