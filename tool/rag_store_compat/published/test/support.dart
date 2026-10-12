// Shared by the published-side harness suites. No setUp anywhere: every check
// runs inside a test body, so a failing precondition is a failing test.

import 'dart:io';

import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

/// Points the published SQLite store at the vec0 loadable its own hook
/// downloaded (`flutter test` bundles nothing, so the store cannot find it by
/// its bundled name). `$VEC0_DYLIB` wins. Same lookup rule as core's
/// `hostNativeLibraryCandidates`, which core 2.2.0 does not export.
void useHostVec0() {
  final path = vec0HostPath();
  if (!File(path).existsSync()) {
    throw StateError(
      'vec0 loadable not found at $path. Run `flutter test` once so the '
      'flutter_edge_ai_sqlite hook downloads it, or set VEC0_DYLIB.',
    );
  }
  // ignore: invalid_use_of_visible_for_testing_member
  SqliteVectorStore.debugOverrideDylibPath = path;
}

String vec0HostPath() {
  final override = Platform.environment['VEC0_DYLIB'];
  if (override != null && override.isNotEmpty) return override;
  final home = Platform.environment['HOME'] ?? '';
  if (Platform.isMacOS) {
    return '$home/Library/Caches/flutter_gemma/native/sqlite_vec/'
        'macos_arm64/libvec0.dylib';
  }
  if (Platform.isLinux) {
    final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
    final dir = arch == 'aarch64' || arch == 'arm64'
        ? 'linux_arm64'
        : 'linux_x86_64';
    return '$home/.cache/flutter_gemma/native/sqlite_vec/$dir/libvec0.so';
  }
  throw UnsupportedError(
    'The store compatibility harness runs on macOS and Linux hosts.',
  );
}

/// Required environment variable, or a failure naming it.
String requireEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('Set $name (see tool/rag_store_compat/README.md).');
  }
  return value;
}
