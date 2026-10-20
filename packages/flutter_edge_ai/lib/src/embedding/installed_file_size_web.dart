// Web: a model's bytes live in the browser's storage (OPFS, the cache, a
// URL), and core does not read their size, so a decider's space id names the
// installed files by name alone there.

/// Always null on web.
Future<int?> installedFileSize(String path) async => null;
