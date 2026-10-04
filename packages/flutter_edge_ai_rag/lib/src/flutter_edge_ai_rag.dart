import 'embedding.dart';
import 'rag_index.dart';
import 'vector_store.dart';
import 'vector_store_provider.dart';

/// Instance-scoped RAG factory and vector-store provider registry.
///
/// This is deliberately independent from `FlutterEdgeAi.initialize()`: apps
/// may create multiple registries and indexes, use different embedders, or run
/// vector-only workflows without initializing an inference engine.
class FlutterEdgeAiRag {
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

  /// Opens an independently-owned RAG index.
  ///
  /// [embedder] is borrowed and never closed. When omitted, the active Flutter
  /// Edge AI embedder is resolved lazily by the first text operation, provided
  /// [activeEmbedderProfileId] declares its stable embedding-space identity.
  /// Vector operations never trigger embedder resolution. Pass
  /// [embeddingProfile] for a new vector-only index; otherwise raw vector
  /// operations remain disabled until a text operation has safely bound and
  /// persisted its profile.
  Future<RagIndex> open({
    required VectorStoreSpec spec,
    RagEmbedder? embedder,
    EmbeddingProfile? embeddingProfile,
    String? activeEmbedderProfileId,
  }) async {
    _validateEmbeddingArguments(
      embedder: embedder,
      embeddingProfile: embeddingProfile,
      activeEmbedderProfileId: activeEmbedderProfileId,
    );
    final provider = _resolveProvider(spec);
    VectorStoreRepository? store;
    try {
      store = await provider.createStore(spec);
      store.configure(spec.filterSchema);
      await store.initialize(spec.location);
      final storedProfile = await store.readEmbeddingProfile();
      final stats = await store.getStats();
      _validateStoredProfile(storedProfile, stats);

      var boundProfile = storedProfile;
      if (embeddingProfile != null) {
        if (storedProfile != null) {
          if (storedProfile != embeddingProfile) {
            throw StateError(
              'Vector store "${spec.location}" is bound to $storedProfile, '
              'not the requested $embeddingProfile. Use a different location.',
            );
          }
        } else {
          _validateLegacyAdoption(
            spec: spec,
            stats: stats,
            profile: embeddingProfile,
          );
          await store.bindEmbeddingProfile(embeddingProfile);
          final persisted = await store.readEmbeddingProfile();
          if (persisted != embeddingProfile) {
            throw StateError(
              'Vector-store provider did not persist the requested '
              '$embeddingProfile.',
            );
          }
          boundProfile = embeddingProfile;
        }
      }
      return createRagIndex(
        store: store,
        embedder:
            embedder ??
            (activeEmbedderProfileId == null
                ? const _MissingActiveEmbedderIdentity()
                : FlutterEdgeAiActiveEmbedder(
                    profileId: activeEmbedderProfileId,
                  )),
        initialProfile: boundProfile,
        allowLegacyProfileAdoption: spec.allowLegacyProfileAdoption,
      );
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

  static void _validateEmbeddingArguments({
    required RagEmbedder? embedder,
    required EmbeddingProfile? embeddingProfile,
    required String? activeEmbedderProfileId,
  }) {
    if (activeEmbedderProfileId != null &&
        activeEmbedderProfileId.trim().isEmpty) {
      throw ArgumentError.value(
        activeEmbedderProfileId,
        'activeEmbedderProfileId',
        'must not be empty',
      );
    }
    if (embedder != null && activeEmbedderProfileId != null) {
      throw ArgumentError(
        'activeEmbedderProfileId applies only to the default active embedder; '
        'a custom RagEmbedder declares its own profile.',
      );
    }
    if (embeddingProfile != null &&
        activeEmbedderProfileId != null &&
        embeddingProfile.id != activeEmbedderProfileId) {
      throw ArgumentError(
        'embeddingProfile.id (${embeddingProfile.id}) must match '
        'activeEmbedderProfileId ($activeEmbedderProfileId).',
      );
    }
  }

  static void _validateStoredProfile(
    EmbeddingProfile? profile,
    VectorStoreStats stats,
  ) {
    if (profile != null &&
        stats.documentCount > 0 &&
        stats.vectorDimension != profile.dimension) {
      throw StateError(
        'The persisted $profile conflicts with the store\'s '
        '${stats.vectorDimension}D vectors. Refusing to open corrupted data.',
      );
    }
  }

  static void _validateLegacyAdoption({
    required VectorStoreSpec spec,
    required VectorStoreStats stats,
    required EmbeddingProfile profile,
  }) {
    if (stats.documentCount == 0) return;
    if (!spec.allowLegacyProfileAdoption) {
      throw StateError(
        'Vector store "${spec.location}" contains legacy vectors without an '
        'embedding profile. Reopen with allowLegacyProfileAdoption: true only '
        'after verifying which embedding model created them.',
      );
    }
    if (stats.vectorDimension != profile.dimension) {
      throw StateError(
        'Cannot adopt ${stats.vectorDimension}D legacy vectors as $profile.',
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

class _MissingActiveEmbedderIdentity implements RagEmbedder {
  const _MissingActiveEmbedderIdentity();

  Never _missing() => throw StateError(
    'Text RAG with the active Flutter Edge AI embedder requires an explicit '
    'activeEmbedderProfileId in FlutterEdgeAiRag.open(). Use a stable ID that '
    'versions the weights, tokenizer, pooling, normalization, and prefix '
    'contract; source paths and URLs are not model identities.',
  );

  @override
  Future<EmbeddingProfile> get profile => Future.error(_missing());

  @override
  Future<List<double>> embedDocument(String text) => Future.error(_missing());

  @override
  Future<List<double>> embedQuery(String text) => Future.error(_missing());
}
