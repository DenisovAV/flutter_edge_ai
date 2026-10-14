import 'island_decider_store.dart';

/// The web: no files, so deciders are kept in memory for the page's life.
IslandDeciderStore createIslandDeciderStore() => _page;

final _page = MemoryIslandDeciderStore();
