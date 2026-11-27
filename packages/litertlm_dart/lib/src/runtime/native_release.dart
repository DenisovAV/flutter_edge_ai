// The native release this package's hook fetches: the one place the version
// is written. The hook pins the archives' SHA256s against it; the host-side
// dev lookup (runtime/host_native_library.dart) finds the hook's cache by it.

/// The `native-v*` release suffix (LiteRT-LM 0.20.0, our first build on it).
const liteRtLmNativeVersion = '0.20.0';

/// The GitHub release tag the archives come from.
const liteRtLmNativeReleaseTag = 'native-v$liteRtLmNativeVersion';
