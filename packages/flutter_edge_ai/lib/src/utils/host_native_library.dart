// Finding a native library on the HOST, for dev and test runs.
//
// In a real app nothing here is used: the library is in the app bundle and
// dlopen resolves it by its bundled name. On the host there is no bundle, so
// every package that runs native code under `flutter test` has to look for the
// file itself — and three of them had written that search separately
// (litert_bindings.dart, vec0_locator.dart, and a qdrant locator that is gone
// since rag_qdrant 1.3.0 handed native loading to the qdrant_edge SDK). The
// copies had already stopped agreeing, which is how this kind of duplication
// always ends and why the rule now lives in one place.
//
// TWO ORDERING RULES, both bought with incidents rather than chosen:
//
//   1. The hook's download cache comes before any local build artifact. The
//      cache is version-validated by hook/build.dart (`_readMarker` /
//      `_invalidateBundleCacheIfStale`); a local prebuilt is gitignored, made
//      by a hand-run build script, and carries no version marker. They hold the
//      same bytes today. After the next `native-v*` bump a stale local copy
//      would silently shadow the refreshed download, and host tests would run
//      against a different native version than the app ships.
//
//   2. Package-relative paths are walked UP from the working directory rather
//      than assumed. Assuming cost nine red speech tests once: the error named
//      a path and said "not found", so it read as "the library was never built"
//      rather than "I looked in the wrong place", and nobody questioned it.
//
// An explicit environment override stays ahead of both — it is an instruction
// from whoever started the run, and an override that can be overridden is not
// one.
library;

import 'dart:io';

/// Root the Native Assets hooks cache downloaded bundles under.
///
/// Mirrors `_cacheBaseDir()` in the hooks. Null when the platform's home
/// directory is not readable, in which case the cache is simply not a
/// candidate — callers still have their local paths.
String? hostNativeCacheBase() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'];
    return (local == null || local.isEmpty)
        ? null
        : '$local\\flutter_gemma\\native';
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  if (Platform.isMacOS) return '$home/Library/Caches/flutter_gemma/native';
  return '$home/.cache/flutter_gemma/native';
}

/// Host platform subdirectory used by both the hooks' cache layout and the
/// in-repo `prebuilt/` trees.
///
/// Linux ships both x86_64 and arm64, so this asks `uname -m` rather than
/// guessing: on an arm64 host the x86_64 file also exists, and preferring it by
/// existence hands the caller an incompatible ELF.
String? hostNativeDirName() {
  if (Platform.isMacOS) return 'macos_arm64';
  if (Platform.isWindows) return 'windows_x86_64';
  if (Platform.isLinux) {
    final arch = _unameMachine();
    if (arch == 'aarch64' || arch == 'arm64') return 'linux_arm64';
    return 'linux_x86_64';
  }
  return null;
}

String? _unameMachine() {
  try {
    final r = Process.runSync('uname', const ['-m']);
    if (r.exitCode != 0) return null;
    return r.stdout.toString().trim();
  } on ProcessException {
    return null;
  }
}

/// Platform-correct file name for a library called [baseName].
String hostNativeLibraryFileName(String baseName) {
  if (Platform.isMacOS || Platform.isIOS) return 'lib$baseName.dylib';
  if (Platform.isWindows) return '$baseName.dll';
  return 'lib$baseName.so';
}

/// Every path to try for a host-side native library, in order.
///
/// [envOverride] is the value of a caller-specific environment variable, or
/// null. [cacheNamespace] is the bundle's subdirectory under the cache root —
/// null for the flat layout LiteRT uses. [relativePaths] are package-relative,
/// and each is tried at every level walked up from the working directory.
///
/// Returns the list rather than the first hit so callers can name every path
/// they tried: a wrong working directory and a genuinely absent library
/// otherwise produce the same message, which is what made the search look like
/// a build failure.
List<String> hostNativeLibraryCandidates({
  required String libFileName,
  String? envOverride,
  String? cacheNamespace,
  List<String> relativePaths = const [],
  int walkUpLevels = 8,
}) {
  final out = <String>[];
  if (envOverride != null && envOverride.isNotEmpty) out.add(envOverride);

  final base = hostNativeCacheBase();
  final host = hostNativeDirName();
  if (base != null && host != null) {
    final ns = cacheNamespace == null ? '' : '$cacheNamespace/';
    out.add('$base/$ns$host/$libFileName');
  }

  if (relativePaths.isNotEmpty) {
    var dir = Directory.current.absolute;
    for (var hop = 0; hop < walkUpLevels; hop++) {
      for (final rel in relativePaths) {
        out.add('${dir.path}/$rel');
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  return out;
}

/// First candidate that exists, as an absolute path, or null.
String? firstExistingPath(List<String> candidates) {
  for (final p in candidates) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}
