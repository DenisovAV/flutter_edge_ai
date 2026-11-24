import 'package:flutter_edge_ai/flutter_edge_ai.dart' show EmbeddingModality;

import 'embedding.dart';
import 'filter.dart';
import 'profile_id.dart';
import 'text_search.dart';

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

/// The durable association of one vector-store location with one embedding
/// space ([profile]) and the one modality its documents have ([documents]).
///
/// A location holds documents of exactly one modality. Mixed corpora use one
/// index per modality: cross-modal scores are not on one scale, so merging
/// their results belongs to the app.
///
/// ### Storage encoding (for store implementations)
///
/// Every bound location has a version-1 profile record `(id, dimension)` —
/// the record flutter_edge_ai_rag 1.0 stores read and write — and it is
/// always written. It is the compare-and-set point for every version, old and
/// new. Its id is [v1RecordId]: the profile id for a text binding, and
/// `'<profile id>\u001F<modality>'` for an image or audio binding. Profile ids
/// cannot contain U+001F, so a qualified id never equals an id an older
/// version is asked to open, and every older reader refuses the location.
/// The one limit: an app on flutter_edge_ai_rag 1.0, which did not reserve
/// U+001F, could open an image or audio location as text by asking for the
/// qualified id itself — no realistic profile id contains that character.
///
/// An image or audio binding additionally writes a version-2 record
/// `(unqualified profile id, dimension, documents)`, cross-checked against the
/// version-1 record on every read:
///
/// | v1 record | v2 record | binding |
/// |---|---|---|
/// | absent | absent | unbound (`null`) |
/// | absent | present | corrupt |
/// | unqualified id | absent | text |
/// | unqualified id | present | corrupt |
/// | qualified id | present, agreeing | image / audio |
/// | qualified id | present, disagreeing | corrupt |
/// | qualified id | absent | corrupt, unless the store publishes the two records separately and can republish v2 from v1 |
/// | qualified id, unknown modality | any | written by a newer version |
///
/// "Corrupt" and "newer version" are [VectorStoreException]s.
final class VectorStoreBinding {
  const VectorStoreBinding({
    required this.profile,
    this.documents = EmbeddingModality.text,
  });

  final EmbeddingProfile profile;
  final EmbeddingModality documents;

  static const String _qualifierSeparator = '\u001F';

  /// For store implementations: the id written into the version-1 profile
  /// record. Text → `profile.id`; image or audio →
  /// `'${profile.id}\u001F${documents.name}'`.
  String get v1RecordId => switch (documents) {
    EmbeddingModality.text => profile.id,
    EmbeddingModality.image || EmbeddingModality.audio =>
      '${profile.id}$_qualifierSeparator${documents.name}',
  };

  /// For store implementations: the inverse of [v1RecordId]. An unqualified
  /// [id] is a text binding.
  ///
  /// Throws [VectorStoreException] when the qualifier names a modality this
  /// version does not know (the location was written by a newer version), or
  /// when the record does not form a valid [EmbeddingProfile].
  static VectorStoreBinding fromV1Record({
    required String id,
    required int dimension,
  }) {
    final separator = id.indexOf(_qualifierSeparator);
    final profileId = separator < 0 ? id : id.substring(0, separator);
    final documents = separator < 0
        ? EmbeddingModality.text
        : switch (id.substring(separator + 1)) {
            'image' => EmbeddingModality.image,
            'audio' => EmbeddingModality.audio,
            _ => null,
          };
    if (documents == null) {
      throw VectorStoreException(
        'The vector store is bound to "${printableId(id)}", whose document '
        'modality this version of flutter_edge_ai_rag does not know: it was '
        'written by a newer version. Use a different location.',
      );
    }
    final EmbeddingProfile profile;
    try {
      profile = EmbeddingProfile(id: profileId, dimension: dimension);
    } on ArgumentError catch (error) {
      throw VectorStoreException(
        'The vector store binding record "${printableId(id)}" '
        '(${dimension}D) is not a valid embedding profile: ${error.message}. '
        'flutter_edge_ai_rag 1.0 accepted control characters in profile ids; '
        'since 1.1 an id may not contain U+0000-U+001F, so a location bound '
        'to such an id cannot be opened by this version.',
        error,
      );
    }
    return VectorStoreBinding(profile: profile, documents: documents);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VectorStoreBinding &&
          other.profile == profile &&
          other.documents == documents;

  @override
  int get hashCode => Object.hash(profile, documents);

  @override
  String toString() =>
      'VectorStoreBinding(profile: $profile, documents: ${documents.name})';
}

/// Storage contract implemented by pluggable vector-store packages: extend
/// it (`final class MyStore extends VectorStoreRepository`).
abstract base class VectorStoreRepository {
  /// Configures filterable metadata before [initialize].
  void configure(FilterSchema schema);

  Future<void> initialize(String location);

  /// Reads the binding durably associated with this location: its embedding
  /// profile and the modality of its documents.
  ///
  /// Returns null only when the location has never been bound, including
  /// legacy databases created before profile metadata existed. A record
  /// written before flutter_edge_ai_rag 1.1 reads as a text binding.
  /// Implementations must read this from the same persistent location as the
  /// vectors, following the encoding documented on [VectorStoreBinding];
  /// keeping it only in process memory would allow incompatible vectors after
  /// reopen.
  Future<VectorStoreBinding?> readBinding();

  /// Durably and atomically binds this location to [binding].
  ///
  /// A compare-and-set: binding the same binding again is a no-op; any
  /// difference — profile id, dimension or documents — throws
  /// [VectorStoreException]. It must never overwrite an existing binding. The
  /// orchestrator validates legacy dimensions before the first bind; this
  /// method supplies the final storage-level guarantee, also against writers
  /// of older versions (see [VectorStoreBinding]).
  Future<void> bind(VectorStoreBinding binding);

  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  });

  Future<void> removeDocument({required String id});

  /// Whether this store implements [removeDocumentsWhere]. Defaults to false.
  bool get supportsRemoveWhere => false;

  /// Removes every document whose metadata matches [filter] and returns how
  /// many it removed. Each removed document also leaves the location's text
  /// index, when it has one.
  ///
  /// `RagIndex` calls this only with a non-empty [filter] whose fields are all
  /// declared in [filterSchema], and with no other operation on the index
  /// running, so the count is exactly what was removed. An implementation
  /// throws [ArgumentError] rather than remove every document when [filter]
  /// is empty or constrains nothing (a range with no bound, a range on a text
  /// field, excluding an empty set, or only undeclared fields).
  ///
  /// Throws [UnsupportedError] when [supportsRemoveWhere] is false: the
  /// default implementation throws it whatever the filter.
  Future<int> removeDocumentsWhere(Filter filter) => Future.error(
    UnsupportedError('$runtimeType does not implement removeWhere.'),
  );

  /// Conditions on fields not declared in [filterSchema] have no effect at
  /// this level; `RagIndex` refuses them before calling this. [threshold] may
  /// be negative: hybrid search passes `-double.maxFinite` to keep every
  /// candidate.
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  });

  /// Whether this store implements [searchText]. Defaults to false.
  ///
  /// A capability of the store type, not of one location: `FlutterEdgeAiRag`
  /// reads it before [initialize], and refuses a spec with
  /// `enableTextSearch` when it is false, so a store without text search
  /// creates nothing on disk for that spec.
  ///
  /// A store that returns true reads `VectorStoreSpec.enableTextSearch` when
  /// its provider creates it. With the flag it creates the location's text
  /// index if it is missing; without it, it still keeps an existing text index
  /// in step with every write, so the index never goes stale.
  bool get supportsTextSearch => false;

  /// Ranks this location's documents for [text] by the store's own text
  /// relevance, higher first, and returns at most [topK].
  ///
  /// [text] is plain user text, never an engine query syntax. A [text] with no
  /// searchable term returns an empty list. [filter] applies as in
  /// [searchSimilar]. Each id appears at most once, with the same content and
  /// metadata [searchSimilar] returns for it.
  ///
  /// Throws [StateError] when this location has no text index, and
  /// [UnsupportedError] when [supportsTextSearch] is false (the default).
  Future<List<TextSearchResult>> searchText({
    required String text,
    required int topK,
    Filter? filter,
  }) => Future.error(
    UnsupportedError('$runtimeType does not implement text search.'),
  );

  Future<VectorStoreStats> getStats();

  /// Removes documents while preserving the binding.
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
