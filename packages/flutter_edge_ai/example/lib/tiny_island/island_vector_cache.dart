import 'dart:typed_data';

export 'island_vector_cache_stub.dart'
    if (dart.library.io) 'island_vector_cache_io.dart';

/// Where the embedding stand-in keeps the option vectors it computed, so the
/// catalog is embedded once per model and catalog, not at every visit.
abstract interface class IslandVectorCache {
  /// The vectors stored under [key], or null when there are none.
  Future<Float32List?> read(String key);

  /// Stores [vectors] under [key].
  Future<void> write(String key, Float32List vectors);
}

/// Keeps vectors for the life of the app (the web, and tests).
final class MemoryIslandVectorCache implements IslandVectorCache {
  final _entries = <String, Float32List>{};

  @override
  Future<Float32List?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, Float32List vectors) async =>
      _entries[key] = vectors;
}
