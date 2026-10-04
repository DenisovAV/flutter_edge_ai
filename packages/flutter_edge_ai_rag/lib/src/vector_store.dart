import 'embedding.dart';
import 'filter.dart';

/// A single retrieval hit from a vector store query.
class RetrievalResult {
  const RetrievalResult({
    required this.id,
    required this.content,
    required this.similarity,
    this.metadata,
  });

  final String id;
  final String content;
  final double similarity;
  final String? metadata;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetrievalResult &&
          other.id == id &&
          other.content == content &&
          other.similarity == similarity &&
          other.metadata == metadata;

  @override
  int get hashCode => Object.hash(id, content, similarity, metadata);

  @override
  String toString() =>
      'RetrievalResult(id: $id, similarity: $similarity, metadata: $metadata)';
}

/// Summary statistics for a vector store.
class VectorStoreStats {
  const VectorStoreStats({
    required this.documentCount,
    required this.vectorDimension,
  });

  final int documentCount;
  final int vectorDimension;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VectorStoreStats &&
          other.documentCount == documentCount &&
          other.vectorDimension == vectorDimension;

  @override
  int get hashCode => Object.hash(documentCount, vectorDimension);

  @override
  String toString() =>
      'VectorStoreStats(documentCount: $documentCount, vectorDimension: $vectorDimension)';
}

/// Storage contract implemented by pluggable vector-store packages.
abstract interface class VectorStoreRepository {
  /// Configures filterable metadata before [initialize].
  void configure(FilterSchema schema);

  Future<void> initialize(String location);

  /// Reads the embedding-space identity durably associated with this store.
  ///
  /// Returns null only when the location has never been bound, including
  /// legacy databases created before profile metadata existed. Implementations
  /// must read this from the same persistent location as the vectors; keeping
  /// it only in process memory would allow incompatible vectors after reopen.
  Future<EmbeddingProfile?> readEmbeddingProfile();

  /// Durably and atomically binds this store to [profile].
  ///
  /// Binding the same profile again is idempotent. An implementation MUST
  /// reject an attempt to replace a different existing profile, even when the
  /// dimensions match. It must never silently overwrite profile metadata.
  /// The orchestrator validates legacy dimensions before first binding, while
  /// this method supplies the final storage-level compare-and-set guarantee.
  Future<void> bindEmbeddingProfile(EmbeddingProfile profile);

  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  });

  Future<void> removeDocument({required String id});

  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  });

  Future<VectorStoreStats> getStats();

  /// Removes documents while preserving the embedding-profile binding.
  ///
  /// One persistent location represents one embedding space for its lifetime.
  /// To change profiles, create a different location rather than clearing and
  /// rebinding this one.
  Future<void> clear();

  /// Persists pending writes without closing the store.
  Future<void> flush();

  /// Releases storage resources. Implementations must make this idempotent.
  Future<void> close();

  bool get isInitialized;

  FilterSchema get filterSchema;
}

class VectorStoreException implements Exception {
  const VectorStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'VectorStoreException: $message${cause != null ? '\nCause: $cause' : ''}';
}
