// Native Assets hook for flutter_edge_ai_any.
//
// Registers libany_shim (native/any_shim: a Go c-shared library over
// any-sync-sdk and any-store) as the CodeAsset the @Native bindings in
// lib/src/ffi/any_shim_bindings.dart resolve by asset id.
//
// The libraries come from a versioned GitHub Release (`native-any-v<X>`),
// checked against the SHA256 pinned below before they are extracted: the
// shape flutter_edge_ai_sqlite uses for sqlite-vec, whose hook this one is
// adapted from (its comments explain the cache marker, the Apple-only
// stage() and the dependency on the local prebuilt directory; they apply
// here unchanged).
//
// A local build wins when present (`native/any_shim/prebuilt/<target>/`, the
// output of `native/any_shim/build.sh <target>`). That is the maintainer
// path: a build can be tested before it is released. The prebuilt
// directory is gitignored and .pubignored.
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _packageName = 'flutter_edge_ai_any';

/// The asset id of the bindings' @DefaultAsset, minus `package:<name>/`.
const _assetName = 'src/ffi/any_shim_bindings.dart';

/// The libany_shim release these bytes are: the shim's own version
/// (`shimVersion` in native/any_shim/shim.go), not the SDK's; the SDK and
/// any-store versions it was built from are in its go.mod and in
/// `any_shim_version()`. A rebuild of an already published version takes a
/// letter suffix (`0.1.0-a`), as the `native-v*` tags do; different bytes
/// under a published tag are never uploaded.
const _bundleVersion = '0.1.0';

const _releaseTag = 'native-any-v$_bundleVersion';
const _markerFileName = '.flutter_edge_ai_any_shim_version';
const _releaseBase =
    'https://github.com/DenisovAV/flutter_edge_ai/releases/download/$_releaseTag';

/// SHA256 of each published archive (`checksums_any_shim.txt` on the
/// release carries the same). A registered checksum promises the platform:
/// a missing or mismatching archive then fails the build.
const Map<String, String> _checksums = {
  'any-shim-android_arm64.tar.gz':
      '3ac49f652677b1a538d7056aaca88f1669df4c90653f3e4bd5bff254465ef3ff',
  'any-shim-ios_arm64.tar.gz':
      'c26a5a9af951462fcfd307dae65a616d0b918958deee9173a77cf5f1ee7c52a3',
  'any-shim-ios_sim_arm64.tar.gz':
      'f2223150898deba3ed564abd2be9d3137110fe3528732d0acfbb9173c8473dc4',
  'any-shim-linux_arm64.tar.gz':
      'e341e1964a383c2306a821f7c1860487ad705fb61b080b82f0f429675b61cbcb',
  'any-shim-linux_x86_64.tar.gz':
      'd74e7a695012f1ff5e4ac9409d788b56991604737506950fec0644acb8795a5a',
  'any-shim-macos_arm64.tar.gz':
      'c1cfdd195226734c93e426ab829e56d2bda35ce9f1dda1f0556a6e801fea1c67',
  'any-shim-windows_x86_64.tar.gz':
      '0ddc6278c057c2b4ce4e04cfe819efc09e181d9e6ca49fb85a659ec07c5eb8e8',
};

String _archiveName(String dirName) => 'any-shim-$dirName.tar.gz';

// ============================================================================
// Per-platform name resolution
// ============================================================================

/// Resolve the prebuilt directory name for (OS, arch, iOS sdk). iOS
/// distinguishes device vs simulator via IOSSdk.
String? _prebuiltDirName(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  if (os == OS.iOS) {
    if (arch != Architecture.arm64) return null; // arm64 only
    return iOSSdk == IOSSdk.iPhoneSimulator ? 'ios_sim_arm64' : 'ios_arm64';
  }
  final archName = switch (arch) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => null,
  };
  if (archName == null) return null;
  final osName = switch (os) {
    OS.macOS => 'macos',
    OS.linux => 'linux',
    OS.windows => 'windows',
    OS.android => 'android',
    _ => null,
  };
  if (osName == null) return null;
  return '${osName}_$archName';
}

/// The library's file name inside each archive (native/any_shim/build.sh).
String _bundledFileName(OS os) => switch (os) {
  OS.windows => 'any_shim.dll',
  OS.macOS || OS.iOS => 'libany_shim.dylib',
  _ => 'libany_shim.so',
};

// ============================================================================
// Cache
// ============================================================================

/// Cache root for downloaded archives: `<base>/any_shim`.
///
/// NAMESPACED but not versioned, matching `onnx_genai/` and `qdrant_edge/`
/// already on disk. Staleness is handled by [_markerFile] plus an explicit
/// wipe, which is this repo's convention and what
/// `hostNativeLibraryCandidates(cacheNamespace:)` — the shared locator the
/// host-side tests use — knows how to find. Putting the version in the path
/// instead works, but only the hook would know the layout: the locator would
/// look under `any_shim/<target>/` and find nothing.
Directory _cacheRoot() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final Directory base;
  if (Platform.isWindows) {
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    base = Directory('$localAppData\\flutter_gemma\\native');
  } else if (Platform.isMacOS) {
    base = Directory('$home/Library/Caches/flutter_gemma/native');
  } else {
    base = Directory('$home/.cache/flutter_gemma/native');
  }
  return Directory('${base.path}${Platform.pathSeparator}any_shim');
}

/// Records which bundle version populated [_cacheRoot].
File _markerFile() =>
    File('${_cacheRoot().path}${Platform.pathSeparator}$_markerFileName');

/// Drops cached libraries left by a DIFFERENT bundle version.
///
/// Without this the cache path — which carries no version — would keep serving
/// the previous release's files forever: the archive is only downloaded when
/// the library is absent, so a version bump alone would never be noticed. Same
/// Same idea as `_invalidateBundleCacheIfStale` in the litertlm hook, with a
/// simpler marker: that one carries JSON `{version, owner}` because three
/// packages share its bundle, and it treats a plain-text marker as LEGACY.
/// Nothing shares this one.
void _invalidateCacheIfStale() {
  final marker = _markerFile();
  final cached = marker.existsSync() ? marker.readAsStringSync().trim() : null;
  if (cached == _bundleVersion) return;

  final root = _cacheRoot();
  if (root.existsSync()) {
    for (final entry in root.listSync()) {
      // Only OUR per-platform directories, matched by name — litertlm filters
      // the same way. A bare "every subdirectory" also swept `.tmp-<target>-
      // <pid>`, which is a CONCURRENT invocation's staging directory: hooks run
      // per target, so an iOS-device and iOS-simulator build sharing one $HOME
      // could have one wipe the other's half-extracted archive mid-rename. The
      // victim then failed with "archive extracted but the library is not in it",
      // blaming the release for a local race.
      if (entry is! Directory) continue;
      if (!_targetDirName.hasMatch(
        entry.uri.pathSegments.where((p) => p.isNotEmpty).last,
      )) {
        continue;
      }
      entry.deleteSync(recursive: true);
    }
    if (cached != null) {
      stderr.writeln(
        'flutter_edge_ai_any: dropped cached libany_shim $cached '
        '(now pinned to $_bundleVersion)',
      );
    }
  }
  if (marker.existsSync()) marker.deleteSync();
}

/// The per-platform subdirectory names this hook owns inside [_cacheRoot].
final _targetDirName = RegExp(r'^(android|ios|linux|macos|windows)_');

bool _hasLib(Directory dir, OS os) => File(
  '${dir.path}${Platform.pathSeparator}${_bundledFileName(os)}',
).existsSync();

/// Local prebuilt first (the maintainer path — `build.sh` output is
/// testable before it is released), then the download cache.
Directory _localPrebuiltDir(String dirName, Uri packageRoot) =>
    Directory.fromUri(
      packageRoot.resolve('native/any_shim/prebuilt/$dirName/'),
    );

Directory? _resolveLibDir(String dirName, Uri packageRoot, OS os) {
  final localDir = _localPrebuiltDir(dirName, packageRoot);
  if (_hasLib(localDir, os)) {
    // Say so. The download path announces itself twice; this one used to be
    // silent, so a build log could not tell you which bytes were registered —
    // and a leftover prebuilt/ overrides the pinned release indefinitely.
    stderr.writeln(
      'flutter_edge_ai_any: using LOCAL prebuilt for $dirName '
      '(${localDir.path}) — the $_releaseTag pin is bypassed',
    );
    return localDir;
  }

  final cacheDir = Directory('${_cacheRoot().path}/$dirName');
  if (_hasLib(cacheDir, os)) return cacheDir;

  return null;
}

// ============================================================================
// Download + verify + extract
// ============================================================================

Future<Directory?> _downloadAndExtract(String dirName, OS os) async {
  final archiveName = _archiveName(dirName);
  final expectedChecksum = _checksums[archiveName];
  if (expectedChecksum == null) {
    // No checksum registered — the ONLY legitimate reason this returns null.
    // The build proceeds without the CodeAsset and the runtime fails at first
    // use with a clear dlopen error. Every other failure below THROWS: a
    // registered checksum promises the platform is supported, so failing to
    // produce the library is a broken build, not a skip — and a hook that
    // returns null there reports success, ships an app with no native library,
    // and surfaces as an opaque crash on the user's device (#316's shape).
    stderr.writeln(
      'flutter_edge_ai_any: no libany_shim for $dirName — $_releaseTag pins '
      'no archive for it and there is no local build. Build one with '
      'native/any_shim/build.sh $dirName.',
    );
    return null;
  }

  final cacheRoot = _cacheRoot();
  final targetDir = Directory('${cacheRoot.path}/$dirName');
  final archiveFile = File('${cacheRoot.path}/$archiveName');

  try {
    if (!cacheRoot.existsSync()) cacheRoot.createSync(recursive: true);

    final url = '$_releaseBase/$archiveName';
    stderr.writeln(
      'flutter_edge_ai_any: downloading libany_shim $_bundleVersion '
      'for $dirName from $url ...',
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError(
          'flutter_edge_ai_any: could not download libany_shim for '
          '$dirName — HTTP ${response.statusCode} from $url.\n'
          'This platform HAS a registered checksum, so the archive is expected '
          'to exist. Check network access to github.com, or that release tag '
          '"$_releaseTag" still carries $archiveName.',
        );
      }
      final sink = archiveFile.openWrite();
      await response.pipe(sink);
    } finally {
      client.close();
    }

    final bytes = await archiveFile.readAsBytes();
    final actualChecksum = sha256.convert(bytes).toString();
    if (actualChecksum != expectedChecksum) {
      archiveFile.deleteSync();
      // An integrity failure has no benign reading, so this is the one case
      // that must never degrade to "build succeeded". It means the bytes
      // GitHub served are not the bytes this package version was built against
      // — a re-uploaded tag (#316), a corrupted transfer, or a MITM.
      throw StateError(
        'flutter_edge_ai_any: CHECKSUM MISMATCH for $archiveName.\n'
        '  expected $expectedChecksum\n'
        '  actual   $actualChecksum\n'
        'The archive served by $_releaseBase does not match what libany_shim '
        '$_bundleVersion was pinned to. Re-run to rule out a corrupt transfer; '
        'if it persists, the release asset was replaced after publication and '
        'the pin can no longer be satisfied — do NOT work around it by '
        'clearing the checksum.',
      );
    }

    // Extract into a sibling temp dir on the SAME filesystem, then rename into
    // place. A torn extract leaves only the temp dir, never a half-populated
    // targetDir that the next run would mistake for a complete one.
    final tmpDir = Directory('${cacheRoot.path}/.tmp-$dirName-$pid');
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync(recursive: true);
    try {
      final result = await Process.run('tar', [
        '-xzf',
        archiveFile.path,
        '-C',
        tmpDir.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'flutter_edge_ai_any: failed to extract $archiveName '
          '(tar exit ${result.exitCode}): ${result.stderr}',
        );
      }
      if (!_hasLib(tmpDir, os)) {
        throw StateError(
          'flutter_edge_ai_any: $archiveName extracted but '
          '${_bundledFileName(os)} is not in it. The archive on $_releaseTag '
          'is not the one this hook expects.',
        );
      }
      if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
      tmpDir.renameSync(targetDir.path);
    } finally {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    }

    archiveFile.deleteSync();
    // The marker is written by the caller, once a target has resolved by
    // EITHER path — see the note there.
    stderr.writeln(
      'flutter_edge_ai_any: libany_shim $dirName ready (checksum verified)',
    );
    return targetDir;
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError(
      'flutter_edge_ai_any: could not prepare libany_shim for $dirName: $e',
    );
  }
}

// ============================================================================
// Apple minimum-OS gate
// ============================================================================

/// Throws unless [lib] is an iOS Mach-O declaring minos 13.0.
///
/// Flutter hardcodes `MinimumOSVersion 13.0` into the Native-Assets framework
/// wrapper it generates for iOS (`targetIOSVersion` in flutter_tools'
/// `ios/native_assets.dart` — verified against Flutter 3.44.0; it has moved
/// 11 -> 12 -> 13 historically). App Store Connect compares each framework's
/// BINARY against ITS OWN wrapper plist, so any other value is ITMS-90208
/// whatever the app's deployment target is. macOS is exempt: its Native-Assets
/// wrapper never gets the key at all.
///
/// This runs HERE, on the bytes about to be registered, rather than only in a
/// host test. The previous guard read a directory the release is packed from,
/// which meant it ran on a maintainer's machine or not at all — the same shape
/// as the bug it was written for, where normalization protected a tarball
/// nobody consumes while the shipped bytes went unchecked. Running it in the
/// hook makes CI's iOS build the enforcement point.
void _assertIosMinos(File lib, IOSSdk? sdk) {
  const lcVersionMinIphoneos = 0x25;
  const lcBuildVersion = 0x32;
  final wantPlatform = sdk == IOSSdk.iPhoneSimulator
      ? 7
      : 2; // IOSSIMULATOR/IOS

  final b = ByteData.sublistView(lib.readAsBytesSync());
  if (b.lengthInBytes < 32) {
    throw StateError('flutter_edge_ai_any: ${lib.path} is not a Mach-O.');
  }
  final ncmds = b.getUint32(16, Endian.little);
  var off = 32;
  for (var i = 0; i < ncmds; i++) {
    if (off + 8 > b.lengthInBytes) break;
    final cmd = b.getUint32(off, Endian.little);
    final size = b.getUint32(off + 4, Endian.little);
    if (size == 0) break;
    if (cmd == lcBuildVersion && off + 16 <= b.lengthInBytes) {
      final platform = b.getUint32(off + 8, Endian.little);
      final v = b.getUint32(off + 12, Endian.little);
      final minos = '${v >> 16}.${(v >> 8) & 0xff}';
      if (platform != wantPlatform || minos != '13.0') {
        throw StateError(
          'flutter_edge_ai_any: ${lib.path} declares platform $platform '
          'minos $minos; expected platform $wantPlatform minos 13.0. An iOS '
          'slice with any other value is App Store rejection ITMS-90208. '
          'Rebuild it with native/any_shim/build.sh, which stamps 13.0, and '
          're-release under a new tag.',
        );
      }
      return;
    }
    if (cmd == lcVersionMinIphoneos) {
      throw StateError(
        'flutter_edge_ai_any: ${lib.path} carries the legacy '
        'LC_VERSION_MIN_IPHONEOS instead of LC_BUILD_VERSION; '
        'native/any_shim/build.sh does not produce that. This binary was not '
        'built by it.',
      );
    }
    off += size;
  }
  throw StateError(
    'flutter_edge_ai_any: ${lib.path} has no version load command, so its '
    'minimum OS cannot be checked. Refusing to bundle it.',
  );
}

// ============================================================================
// Entry point
// ============================================================================

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final codeConfig = input.config.code;
    final os = codeConfig.targetOS;

    // Native platforms only: there is no web build of any-sync.
    if (os != OS.macOS &&
        os != OS.linux &&
        os != OS.windows &&
        os != OS.iOS &&
        os != OS.android) {
      return;
    }

    final arch = codeConfig.targetArchitecture;
    final iOSSdk = os == OS.iOS ? codeConfig.iOS.targetSdk : null;
    final dirName = _prebuiltDirName(os, arch, iOSSdk: iOSSdk);
    if (dirName == null) {
      // E.g. armeabi-v7a, which Flutter builds for Android by default.
      stderr.writeln(
        'flutter_edge_ai_any: no libany_shim for ${os.name} ${arch.name}; '
        'this app will fail at the first any-sync call on such a device.',
      );
      return;
    }

    // Watch the local prebuilt directory on every path, the empty one too:
    // a hook output with no dependency is never rebuilt, so a library built
    // with build.sh after a run that found none would be ignored until
    // `flutter clean`.
    output.dependencies.add(
      _watchableAncestor(_localPrebuiltDir(dirName, input.packageRoot)).uri,
    );

    _invalidateCacheIfStale();

    var libDir = _resolveLibDir(dirName, input.packageRoot, os);
    libDir ??= await _downloadAndExtract(dirName, os);
    if (libDir == null) return; // nothing registered for this target

    // Record the pin whenever a target resolves, not only when it was
    // downloaded. With the write confined to the download path, a local
    // prebuilt left the marker absent, so the NEXT target read `null !=
    // _bundleVersion` and wiped every cached directory — silently, since the
    // "dropped cached X" line is suppressed when there was no previous value.
    // One local prebuilt meant re-downloading every other target on every
    // build.
    _markerFile().parent.createSync(recursive: true);
    _markerFile().writeAsStringSync(_bundleVersion);

    final srcUri = libDir.uri.resolve(_bundledFileName(os));
    if (os == OS.iOS) _assertIosMinos(File.fromUri(srcUri), iOSSdk);

    // APPLE-ONLY staging (Xcode "Cycle inside Flutter Assemble"): copy the
    // dylib into the hook's outputDirectory so the registered output asset
    // does not live inside the directory we also declare as an input.
    // Windows/Linux register straight from the resolved dir. Mirrors the
    // litertlm hook, including the reason staging stops at Apple.
    Uri stage(Uri uri) {
      if (os != OS.macOS && os != OS.iOS) return uri;
      final src = File.fromUri(uri);
      final destUri = input.outputDirectory.resolve(uri.pathSegments.last);
      final dest = File.fromUri(destUri);
      // Compare CONTENT, not length: the staged directory is named after the
      // build CONFIG alone, so it is reused across an upgrade and across a
      // local rebuild, and a size-only guard keeps the previous binary
      // whenever the replacement happens to be the same size.
      if (!dest.existsSync() || !_sameBytes(src, dest)) {
        dest.parent.createSync(recursive: true);
        src.copySync(destUri.toFilePath());
      }
      return destUri;
    }

    output.assets.code.add(
      CodeAsset(
        package: _packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: stage(srcUri),
      ),
    );
    // The FILE, not its directory: a directory dependency is hashed as the
    // sorted list of child NAMES only, so it cannot see a library change.
    output.dependencies.add(srcUri);
    // A change in WHICH file wins is seen through the local prebuilt
    // directory, a dependency since before the lookup.
  });
}

/// Byte-for-byte comparison of two existing files.
///
/// `stage()` compares CONTENT rather than `lengthSync()`. The staged directory
/// is named after the build CONFIG alone — no package version, no package root
/// — so the same path is reused across an upgrade and across a local native
/// rebuild. A size-only guard therefore keeps the previous binary whenever the
/// replacement happens to be the same size, which is exactly what re-stamping
/// a Mach-O load command produces.
///
/// Byte-identical in `flutter_edge_ai_litertlm` and `flutter_edge_ai_onnx`; the
/// packages publish independently and cannot share it.
bool _sameBytes(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) return false;
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

/// The nearest ancestor of [dir] that exists — or [dir] itself when it does.
///
/// `output.dependencies` has TWO readers with different tolerances.
/// package:native_assets_builder hashes a missing directory to a sentinel and
/// is perfectly happy. Flutter writes the same paths into a depfile and its
/// tooling LISTS them, so naming a directory that is not there aborts the build
/// with `PathNotFoundException: Directory listing failed` — measured, on a
/// clean clone where the gitignored `prebuilt/` does not exist.
///
/// Walking up preserves what naming it was for: creating the missing level
/// changes the child-name list of whichever ancestor we did name, so the hook
/// re-runs and notices the local prebuilt appearing.
Directory _watchableAncestor(Directory dir) {
  var d = dir;
  while (!d.existsSync()) {
    final parent = d.parent;
    if (parent.path == d.path) return d; // filesystem root
    d = parent;
  }
  return d;
}
