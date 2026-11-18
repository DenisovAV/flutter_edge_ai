import 'package:flutter_edge_ai/flutter_edge_ai.dart' show EmbeddingModality;

import 'vector_store.dart';
import 'filter.dart';

/// Describes a vector-store instance to create.
final class VectorStoreSpec {
  /// Throws [ArgumentError] when [providerId] or [location] is empty, when
  /// [filterSchema] is invalid, and when [allowLegacyProfileAdoption] is set
  /// for non-text [documents] (adoption applies to text bindings only), and
  /// when [enableTextSearch] is set for non-text [documents].
  VectorStoreSpec({
    required this.providerId,
    required this.location,
    this.filterSchema = FilterSchema.empty,
    this.allowLegacyProfileAdoption = false,
    this.documents = EmbeddingModality.text,
    this.enableTextSearch = false,
  }) {
    if (providerId.trim().isEmpty) {
      throw ArgumentError.value(providerId, 'providerId', 'must not be empty');
    }
    if (location.trim().isEmpty) {
      throw ArgumentError.value(location, 'location', 'must not be empty');
    }
    FilterField.validateSchema(filterSchema);
    if (allowLegacyProfileAdoption && documents != EmbeddingModality.text) {
      throw ArgumentError.value(
        allowLegacyProfileAdoption,
        'allowLegacyProfileAdoption',
        'applies to text bindings only; legacy vectors are text vectors, so '
            'they cannot be adopted as ${documents.name} documents',
      );
    }
    if (enableTextSearch && documents != EmbeddingModality.text) {
      throw ArgumentError.value(
        enableTextSearch,
        'enableTextSearch',
        'applies to text documents only; the content of a ${documents.name} '
            'document is a reference to the medium, not searchable text',
      );
    }
  }

  final String providerId;
  final String location;
  final FilterSchema filterSchema;

  /// Explicit migration attestation for a nonempty legacy store without a
  /// persisted binding. Text bindings only.
  ///
  /// When true, the first profile may be bound only after its dimension is
  /// verified against the existing vectors. Leave false unless the caller has
  /// independently established that those vectors came from that exact model.
  final bool allowLegacyProfileAdoption;

  /// The one modality this location's documents have. It is persisted with
  /// the profile as a [VectorStoreBinding], so a location opened for images
  /// refuses to open for text, and the other way round.
  final EmbeddingModality documents;

  /// Gives this location a text index, creating it if it is missing, so
  /// `RagIndex.searchText` and `RagIndex.searchHybrid` work. Text documents
  /// only.
  ///
  /// A persistent property of the location, not a per-open switch: once
  /// created, the text index is kept in step with every write, also by opens
  /// that leave this false, and there is no way to remove it (use a new
  /// location). Opening fails with [VectorStoreException] when the provider's
  /// store has no text search (`VectorStoreRepository.supportsTextSearch`).
  final bool enableTextSearch;
}

/// Factory for fresh vector-store instances.
///
/// Multiple providers may share an [id]. The first matching provider after
/// sorting by descending [priority] and stable registration order wins.
abstract interface class VectorStoreProvider {
  String get id;
  String get name;
  int get priority;

  bool canHandle(VectorStoreSpec spec);

  Future<VectorStoreRepository> createStore(VectorStoreSpec spec);
}
