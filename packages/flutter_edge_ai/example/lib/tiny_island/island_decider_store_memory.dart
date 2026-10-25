import 'island_decider_store.dart';

/// Neither files nor OPFS: deciders are kept in memory for the app's life.
IslandDeciderStore createIslandDeciderStore() => _page;

final _page = MemoryIslandDeciderStore();
