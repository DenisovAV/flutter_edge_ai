export 'island_decider_store_memory.dart'
    if (dart.library.js_interop) 'island_decider_store_web.dart'
    if (dart.library.io) 'island_decider_store_io.dart';

/// Where fitted Tiny Island deciders are kept between visits, as the JSON of
/// `Decider.toArtifact()`, so a visit with the same model and catalog loads
/// the decider (`EmbeddingModel.loadDecider`) instead of embedding the 920
/// option texts and 144 calibration requests again.
///
/// Natively: one file per model in the app's CACHE directory — never in
/// application support, which iCloud and Android Auto Backup copy; the OS may
/// purge it, which costs one refit. On the web: one file per model in the
/// origin private file system (OPFS); a stored decider is about 0.8 MB, more
/// than local storage should hold.
abstract interface class IslandDeciderStore {
  /// Where the artifacts live, for the status line.
  String get where;

  /// The artifact stored for [model] under [fingerprint], or null when there
  /// is none. Throws when one is there but cannot be read (a damaged file is
  /// reported, then replaced by the next [write]).
  Future<Map<String, Object?>?> read({
    required String model,
    required String fingerprint,
  });

  /// Stores [artifact] for [model] under [fingerprint], replacing what was
  /// there, then removes [model]'s artifacts stored under other fingerprints
  /// (older catalogs). Throws when the artifact could not be stored; returns
  /// a problem to show when it was stored but an older one could not be
  /// removed, else null.
  Future<String?> write({
    required String model,
    required String fingerprint,
    required Map<String, Object?> artifact,
  });
}

/// Keeps artifacts for the life of the app: the web's store, and tests'.
final class MemoryIslandDeciderStore implements IslandDeciderStore {
  final _artifacts = <String, (String, Map<String, Object?>)>{};

  @override
  String get where => 'memory, for this page';

  @override
  Future<Map<String, Object?>?> read({
    required String model,
    required String fingerprint,
  }) async => switch (_artifacts[model]) {
    (final stored, final artifact) when stored == fingerprint => artifact,
    _ => null,
  };

  @override
  Future<String?> write({
    required String model,
    required String fingerprint,
    required Map<String, Object?> artifact,
  }) async {
    _artifacts[model] = (fingerprint, artifact);
    return null;
  }
}
