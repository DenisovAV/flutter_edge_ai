import 'package:flutter_edge_ai/flutter_edge_ai.dart' show EmbeddingModality;

import 'embedding.dart';
import 'rag_index.dart';
import 'vector_store.dart';
import 'vector_store_provider.dart';

/// Instance-scoped RAG factory and vector-store provider registry.
///
/// This is deliberately independent from `FlutterEdgeAi.initialize()`: apps
/// may create multiple registries and indexes, use different embedders, or run
/// vector-only workflows without initializing an inference engine.
final class FlutterEdgeAiRag {
  FlutterEdgeAiRag({required List<VectorStoreProvider> providers})
    : _providers = _sortAndValidate(providers);

  final List<VectorStoreProvider> _providers;

  /// Whether a registered provider currently reports support for [spec].
  ///
  /// Probe failures are treated as unavailable so feature detection itself
  /// never throws.
  bool canOpen(VectorStoreSpec spec) {
    for (final provider in _providers) {
      if (provider.id != spec.providerId) continue;
      try {
        if (provider.canHandle(spec)) return true;
      } catch (_) {
        // A broken or platform-incompatible probe is simply unavailable here.
      }
    }
    return false;
  }

  /// Opens an independently-owned RAG index whose documents [embedder]
  /// embeds.
  ///
  /// Resolves the embedder's profile now — with
  /// [FlutterEdgeAiActiveEmbedder] that loads the model, so install the
  /// embedder before calling this. [embedder] must embed `spec.documents`
  /// ([ArgumentError] otherwise). The location is then bound to
  /// `(profile, spec.documents)`: an unbound location is bound now, and a
  /// location bound to anything else is refused with a [StateError] — use a
  /// different location for every embedding profile and document modality.
  /// An unbound location that already holds documents is adopted only for
  /// text and only with `spec.allowLegacyProfileAdoption` and a matching
  /// dimension.
  ///
  /// [embedder] is borrowed and never closed: dispose the index before the
  /// embedder.
  ///
  /// Every error, argument errors included, arrives as a failed future.
  Future<RagIndex> open({
    required VectorStoreSpec spec,
    required RagEmbedder embedder,
  }) async {
    final provider = _resolveProvider(spec);
    final modalities = embedder.modalities;
    if (!modalities.contains(spec.documents)) {
      throw ArgumentError.value(
        embedder,
        'embedder',
        'embeds ${_names(modalities)}, not the ${spec.documents.name} '
            'documents of "${spec.location}"',
      );
    }
    final profile = await embedder.resolveProfile();
    return _openBound(
      provider: provider,
      spec: spec,
      binding: VectorStoreBinding(profile: profile, documents: spec.documents),
      embedder: embedder,
    );
  }

  /// Opens a vector-only index (`addVector` / `searchVector`) bound to
  /// [profile] and `spec.documents`, with the same binding rules as [open].
  ///
  /// Raw numbers cannot identify their embedding space, so the profile is
  /// required: name the pipeline that produced the vectors.
  Future<RagIndex> openVectors({
    required VectorStoreSpec spec,
    required EmbeddingProfile profile,
  }) async {
    final provider = _resolveProvider(spec);
    return _openBound(
      provider: provider,
      spec: spec,
      binding: VectorStoreBinding(profile: profile, documents: spec.documents),
      embedder: null,
    );
  }

  Future<RagIndex> _openBound({
    required VectorStoreProvider provider,
    required VectorStoreSpec spec,
    required VectorStoreBinding binding,
    required RagEmbedder? embedder,
  }) async {
    VectorStoreRepository? store;
    try {
      store = await provider.createStore(spec);
      store.configure(spec.filterSchema);
      await store.initialize(spec.location);
      final stored = await store.readBinding();
      final stats = await store.getStats();
      _validateStoredBinding(stored, stats);

      if (stored != null) {
        if (stored != binding) {
          throw StateError(
            'Vector store "${spec.location}" is bound to $stored, not '
            '$binding. Use a different location.',
          );
        }
      } else {
        _validateLegacyAdoption(spec: spec, stats: stats, binding: binding);
        await store.bind(binding);
        final persisted = await store.readBinding();
        if (persisted != binding) {
          throw StateError(
            'Vector-store provider "${provider.id}" did not persist the '
            'requested $binding (read back: $persisted).',
          );
        }
      }
      return createRagIndex(store: store, embedder: embedder, binding: binding);
    } catch (error, stackTrace) {
      if (store != null) {
        try {
          await store.close();
        } catch (_) {
          // Cleanup must not replace the configuration/initialization error.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static String _names(Set<EmbeddingModality> modalities) =>
      '{${[for (final modality in modalities) modality.name].join(', ')}}';

  static void _validateStoredBinding(
    VectorStoreBinding? binding,
    VectorStoreStats stats,
  ) {
    if (binding != null &&
        stats.documentCount > 0 &&
        stats.vectorDimension != binding.profile.dimension) {
      throw StateError(
        'The persisted $binding conflicts with the store\'s '
        '${stats.vectorDimension}D vectors. Refusing to open corrupted data.',
      );
    }
  }

  static void _validateLegacyAdoption({
    required VectorStoreSpec spec,
    required VectorStoreStats stats,
    required VectorStoreBinding binding,
  }) {
    if (stats.documentCount == 0) return;
    if (binding.documents != EmbeddingModality.text) {
      throw StateError(
        'Vector store "${spec.location}" contains legacy vectors without an '
        'embedding profile. They are text vectors, so they cannot be opened '
        'as ${binding.documents.name} documents. Use a different location.',
      );
    }
    if (!spec.allowLegacyProfileAdoption) {
      throw StateError(
        'Vector store "${spec.location}" contains legacy vectors without an '
        'embedding profile. Reopen with allowLegacyProfileAdoption: true only '
        'after verifying which embedding model created them.',
      );
    }
    if (stats.vectorDimension != binding.profile.dimension) {
      throw StateError(
        'Cannot adopt ${stats.vectorDimension}D legacy vectors as '
        '${binding.profile}.',
      );
    }
  }

  VectorStoreProvider _resolveProvider(VectorStoreSpec spec) {
    for (final provider in _providers) {
      if (provider.id != spec.providerId) continue;
      try {
        if (provider.canHandle(spec)) return provider;
      } catch (_) {
        // Probe failures have the same meaning as in canOpen: this provider
        // is unavailable, but a lower-priority implementation may work.
      }
    }

    final registered =
        _providers.map((provider) => provider.id).toSet().toList()..sort();
    final registeredText = registered.isEmpty ? 'none' : registered.join(', ');
    throw StateError(
      'No vector-store provider can handle providerId "${spec.providerId}" '
      'at "${spec.location}". Register the matching provider package when '
      'constructing FlutterEdgeAiRag. Registered provider IDs: '
      '$registeredText.',
    );
  }

  static List<VectorStoreProvider> _sortAndValidate(
    List<VectorStoreProvider> providers,
  ) {
    final entries = <_ProviderEntry>[];
    for (var index = 0; index < providers.length; index++) {
      final provider = providers[index];
      if (provider.id.trim().isEmpty) {
        throw ArgumentError.value(
          provider.id,
          'provider.id',
          'must not be empty',
        );
      }
      if (provider.name.trim().isEmpty) {
        throw ArgumentError.value(
          provider.name,
          'provider.name',
          'must not be empty',
        );
      }
      entries.add(_ProviderEntry(provider, index));
    }
    entries.sort((left, right) {
      final priority = right.provider.priority.compareTo(
        left.provider.priority,
      );
      return priority != 0 ? priority : left.index.compareTo(right.index);
    });
    return List.unmodifiable(entries.map((entry) => entry.provider));
  }
}

class _ProviderEntry {
  const _ProviderEntry(this.provider, this.index);

  final VectorStoreProvider provider;
  final int index;
}
