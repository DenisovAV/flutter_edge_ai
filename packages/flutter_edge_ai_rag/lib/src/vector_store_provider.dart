import 'vector_store.dart';
import 'filter.dart';

/// Describes a vector-store instance to create.
class VectorStoreSpec {
  VectorStoreSpec({
    required this.providerId,
    required this.location,
    this.filterSchema = const FilterSchema(),
    this.allowLegacyProfileAdoption = false,
  }) {
    if (providerId.trim().isEmpty) {
      throw ArgumentError.value(providerId, 'providerId', 'must not be empty');
    }
    if (location.trim().isEmpty) {
      throw ArgumentError.value(location, 'location', 'must not be empty');
    }
    FilterField.validateSchema(filterSchema);
  }

  final String providerId;
  final String location;
  final FilterSchema filterSchema;

  /// Explicit migration attestation for a nonempty legacy store without
  /// persisted [EmbeddingProfile] metadata.
  ///
  /// When true, the first profile may be bound only after its dimension is
  /// verified against the existing vectors. Leave false unless the caller has
  /// independently established that those vectors came from that exact model.
  final bool allowLegacyProfileAdoption;
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
