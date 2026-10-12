import 'package:flutter_edge_ai/flutter_edge_ai.dart' show EmbeddingModality;

import 'vector_store.dart';
import 'filter.dart';

/// Describes a vector-store instance to create.
final class VectorStoreSpec {
  /// Throws [ArgumentError] when [providerId] or [location] is empty, when
  /// [filterSchema] is invalid, and when [allowLegacyProfileAdoption] is set
  /// for non-text [documents] (adoption applies to text bindings only).
  VectorStoreSpec({
    required this.providerId,
    required this.location,
    this.filterSchema = FilterSchema.empty,
    this.allowLegacyProfileAdoption = false,
    this.documents = EmbeddingModality.text,
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
