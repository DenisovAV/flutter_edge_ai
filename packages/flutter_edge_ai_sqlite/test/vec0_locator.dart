// Locates the prebuilt vec0 loadable extension for host-side tests.
//
// Every suite here needs the same artifact, and each used to spell the lookup
// itself — one defaulting to `/tmp/vec0_poc/vec0.dylib`, a path left over from
// the migration proof-of-concept. Nothing puts a file there, so the keystone
// test was red on every machine where someone had not hand-downloaded one, and
// 23 more suites skipped themselves for the same reason. Since CI ran only
// packages/flutter_edge_ai, nobody saw either.
//
// The artifact is fetched by hook/build.dart into the shared download cache
// (`<cache>/sqlite_vec/<plat>/`), so that is the first place to look; a local
// `native/sqlite_vec/prebuilt/<plat>/` from build_local.sh comes next.
// $VEC0_DYLIB still wins, for pointing at a different build.
//
// NOTE this is the opposite of the hook's order, which prefers the local
// prebuilt (see `_resolveLibDir`). Core's shared helper puts the cache first
// deliberately — `host_native_library.dart` records that a stale local copy
// silently shadowing a refreshed download cost an incident. So on a machine
// holding both, `flutter test` exercises the checksum-verified release bytes
// while `flutter build` registers the local ones. The hook now says so on
// stderr when it takes the local path; do not read the two orders as agreeing.
//
// Naming the cache is not optional decoration: `flutter test` gets no Native
// Assets bundling, so this list IS how the suites find the library. When the
// loadables moved out of the package and this still said there was no cache to
// search, every store suite skipped itself and only the keystone gate noticed.
library;

import 'dart:io';

import 'package:flutter_edge_ai/core/utils/host_native_library.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

String get _libName => hostNativeLibraryFileName('vec0');

/// Every path considered, in order. Exposed so a failure message can name them
/// all — "not found" and "looked in the wrong place" must not read alike.
List<String> get vec0Candidates {
  final host = hostNativeDirName();
  return hostNativeLibraryCandidates(
    libFileName: _libName,
    envOverride: Platform.environment['VEC0_DYLIB'],
    cacheNamespace: 'sqlite_vec',
    relativePaths: host == null
        ? const []
        : [
            'native/sqlite_vec/prebuilt/$host/$_libName',
            'packages/flutter_edge_ai_sqlite/native/sqlite_vec/prebuilt/$host/$_libName',
          ],
  );
}

/// First candidate that exists, or null when none does.
String? get vec0Path => firstExistingPath(vec0Candidates);

/// Reason string for `skip:` when the extension is genuinely unavailable, or
/// null when it is present. Names every path tried, and the working directory,
/// because a wrong CWD and a missing file otherwise produce the same message.
String? get vec0SkipReason {
  if (vec0Path != null) return null;
  return 'vec0 loadable extension not found. Looked in: '
      '${vec0Candidates.join(", ")} (cwd: ${Directory.current.path}). '
      'Run from the package directory, or set \$VEC0_DYLIB.';
}

/// Points both vector stores at the libraries the shared locator found.
///
/// Call from `setUp`/`setUpAll` in any suite that opens a store. Before this
/// existed each suite needed `$VEC0_DYLIB` exported by tool/test_all.sh, so a
/// plain `flutter test` in this package failed on a dlopen with nothing to
/// suggest the environment was the problem — and the qdrant side had a
/// programmatic override while the sqlite side did not, so a test could
/// configure one store and had to configure the other through the process
/// environment.
void useHostNativeLibraries() {
  final vec0 = vec0Path;
  if (vec0 != null) {
    // ignore: invalid_use_of_visible_for_testing_member
    SqliteVectorStore.debugOverrideDylibPath = vec0;
  }
}
