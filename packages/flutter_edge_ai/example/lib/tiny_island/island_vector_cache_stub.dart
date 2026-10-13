import 'island_vector_cache.dart';

/// The web: vectors live for the page's life (no files here, and 2.8 MB is
/// too much for local storage).
IslandVectorCache createIslandVectorCache() => _memory;

final _memory = MemoryIslandVectorCache();
