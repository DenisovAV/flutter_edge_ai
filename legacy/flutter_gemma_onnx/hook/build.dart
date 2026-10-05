// Native Assets hook for the ORT-GenAI text-generation arm (hardened plan
// Phase 3, Task 4). Modeled on `flutter_gemma_litertlm/hook/build.dart`
// (fetch → sha256 → extract → CodeAsset; marker/self-heal; Apple-only
// `stage()`), but sources from **Microsoft's own GitHub releases** — two
// separate repos, NOT the `native-vX` tag this repo publishes for LiteRT-LM
// — so it does not reuse `_NativeBundle`'s tag-based URL construction.
// Document this supply-chain divergence: unlike every other bundle in this
// monorepo, these two archives are never re-hosted by us.
//
// **macOS arm64, linux_x64, windows_x64, android_arm64, ios arm64 (v1)** —
// iOS is now landed too, but shaped differently from every other platform:
// Microsoft ships ONE self-contained artifact for iOS
// (`onnxruntime-genai-ios-<ver>.zip` → `onnxruntime-genai.xcframework`) whose
// framework binary STATICALLY links ORT and DYNAMICALLY EXPORTS BOTH APIs
// (`Oga*` for generation, `OrtGetApiBase` for the plain-ORT embedding arm) —
// verified via `nm -gU` + `otool -L` on the extracted binary (zero
// `LC_LOAD_DYLIB` on onnxruntime). So iOS registers exactly one CodeAsset
// (`ort: null` in `_OrtBundle`, see its doc) where every other platform
// registers two — there is no co-location problem to solve and no second
// "onnxruntime" archive to add; do not add one. Android's own archive is a
// differently-shaped AAR (a zip
// containing per-ABI `.so` files under `jni/<abi>/` — see [_archivesFor]'s
// doc) but the (host-verifiable) extraction is landed: only arm64-v8a is
// registered (ORT-GenAI's AAR ships no armeabi-v7a slice, so arm64-only is
// the only viable device ABI, not just policy). `stage()`'s canonical-rename
// copy applies on macOS/iOS (framework-name derivation) AND Linux
// (Microsoft's tarball ships the versioned `.so.X.Y.Z`, not the bare name
// `_candidateNames` dlopens) — Android is a no-op like Windows: both AARs'
// `.so` files already ship under the bare canonical name
// (`libonnxruntime.so`, `libonnxruntime-genai.so`) that `_candidateNames`
// bare-name dlopens on that platform, so CodeAssets register straight from
// the cache dir (matches `flutter_gemma_litertlm`'s Android posture, which
// ships 12+ flat CodeAssets with runtime bare-name cross-dlopen, device-
// proven). Windows stays a no-op for a different reason: its `.dll`s already
// ship under the bare canonical name AND active staging is what breaks
// Windows cancel/close (see CLAUDE.md's build-native scar).
//
// This hook is the SOLE owner of exactly one `libonnxruntime` (1.27.0) per
// design D1 — the embedding arm's `OrtFfiClient` (`ort_ffi_client.dart`)
// still resolves the dylib directly by platform default name /
// `FLUTTER_GEMMA_ORT_LIBRARY` for now; wiring it onto this CodeAsset is a
// follow-on (it shares the same package, so no cross-package marker
// coordination is needed the way litertlm/embeddings share libLiteRtLm).
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _packageName = 'flutter_gemma_onnx';

/// One archive to fetch, verify, and extract: a GitHub Release tarball for
/// one (library, platform) pair.
class _Archive {
  const _Archive({
    required this.url,
    required this.sha256,
    required this.extractedLibPath,
    required this.assetName,
    this.thinArch,
  });

  /// Full download URL (Microsoft's own release, not ours).
  final String url;

  /// Expected SHA256 of the downloaded `.tar.gz`/`.tgz` bytes.
  final String sha256;

  /// Path to the dylib INSIDE the extracted archive root, e.g.
  /// `lib/libonnxruntime.1.27.0.dylib` — deliberately the concrete
  /// versioned file, not a same-named-copy or a `.1.dylib` symlink (the
  /// symlink chain the vendor ships alongside it; other platforms' archives
  /// only have the true binary at the fully-versioned name).
  final String extractedLibPath;

  /// CodeAsset name (package-relative, no extension) — becomes the
  /// framework/binary leaf name Flutter's macOS build wraps this dylib in
  /// (e.g. `onnxruntime` → `onnxruntime.framework/onnxruntime`). Must match
  /// what `GenAiFfiClient`'s worker-side loader opens
  /// (`DynamicLibrary.open('$assetName.framework/$assetName')` — see Task
  /// 4's framework-wrap risk note in `gen_ai_client.dart`).
  final String assetName;

  /// When set, the extracted binary is a fat Mach-O and must be thinned to
  /// this single architecture (via `lipo -thin`) before being staged as a
  /// CodeAsset. Used only for iOS's simulator slice (see `_archivesFor`'s
  /// iOS branch): Microsoft ships `ios-arm64_x86_64-simulator` as one fat
  /// arm64+x86_64 binary, but a CodeAsset needs a single-arch input — Native
  /// Assets's own lipo step merges per-arch outputs ACROSS separate hook
  /// invocations, not within one already-fat input. `lipo` is guaranteed
  /// present: this hook only ever runs on a macOS host when targeting iOS.
  final String? thinArch;

  String get archiveFileName => url.split('/').last;
}

/// Archives for this version pair, keyed by (os, arch[, iOSSdk]). macOS
/// arm64, linux_x64, windows_x64, android_arm64, and ios arm64 (device +
/// Apple-Silicon simulator) are landed (host-fetchable — the Android AAR
/// extraction and the iOS zip extraction are both build-time steps, no
/// device involved to GET the CodeAssets bundled; the device throughput/RAM
/// go/no-go is a separate, later gate on top of this — see
/// `OnnxEngine._isSupportedHost`'s doc). [iOSSdk] distinguishes device vs
/// simulator on iOS (exact `flutter_gemma_litertlm` precedent,
/// `_prebuiltDirName`) — unused for every other OS. Returns null for any
/// unsupported (os, arch) — notably Android x86_64 (emulator, out of scope),
/// Android armeabi-v7a (ORT-GenAI ships no such AAR slice), and iOS x86_64
/// (Intel-Mac simulator; ORT-GenAI's iOS xcframework only ships arm64 device
/// + an arm64/x86_64 simulator fat slice, never a bare x86_64-only one, and
/// `dart:ffi`'s `Abi` has no distinct simulator ABI anyway — see
/// `OnnxEngine._isSupportedHost`'s doc).
_OrtBundle? _archivesFor(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  if (os == OS.iOS) {
    // Only arm64 is supported. On Apple Silicon Macs, Flutter still invokes
    // the hook for x86_64 simulator slices; returning null skips them so
    // Native Assets's lipo step doesn't try to merge two arm64-only inputs
    // and fail with "same architectures and can't be in the same fat file"
    // (exact `flutter_gemma_litertlm` precedent).
    if (arch != Architecture.arm64) return null;
    const url =
        'https://github.com/microsoft/onnxruntime-genai/releases/'
        'download/v0.14.0/onnxruntime-genai-ios-0.14.0.zip';
    const sha256Hex =
        '6734735af0827d503031a9e17e034cafeb9b54311d333b3dc6aa1ed73476137f';
    if (iOSSdk == IOSSdk.iPhoneSimulator) {
      return const _OrtBundle(
        dirName: 'ios_sim_arm64',
        ort: null,
        genai: _Archive(
          url: url,
          sha256: sha256Hex,
          // Microsoft's simulator slice is a fat arm64+x86_64 binary — the
          // Apple-Silicon-only arm64 half is pulled out by `thinArch` below
          // before this file is staged as a CodeAsset.
          extractedLibPath:
              'onnxruntime-genai.xcframework/ios-arm64_x86_64-simulator/'
              'onnxruntime-genai.framework/onnxruntime-genai',
          assetName: 'onnxruntime-genai',
          thinArch: 'arm64',
        ),
      );
    }
    return const _OrtBundle(
      dirName: 'ios_arm64',
      ort: null,
      genai: _Archive(
        url: url,
        sha256: sha256Hex,
        extractedLibPath:
            'onnxruntime-genai.xcframework/ios-arm64/'
            'onnxruntime-genai.framework/onnxruntime-genai',
        assetName: 'onnxruntime-genai',
      ),
    );
  }
  if (os == OS.macOS && arch == Architecture.arm64) {
    return const _OrtBundle(
      dirName: 'macos_arm64',
      ort: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime/releases/download/'
            'v1.27.0/onnxruntime-osx-arm64-1.27.0.tgz',
        sha256:
            '545e81c58152353acb0d1e8bd6ce4b62f830c0961f5b3acfedc790ffd76e477a',
        extractedLibPath:
            'onnxruntime-osx-arm64-1.27.0/lib/libonnxruntime.1.27.0.dylib',
        assetName: 'onnxruntime',
      ),
      genai: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime-genai/releases/'
            'download/v0.14.0/onnxruntime-genai-0.14.0-osx-arm64.tar.gz',
        sha256:
            '56583c98e3939d2cfd5a3812471be44017ce2752776d389015ff583a8d758312',
        extractedLibPath:
            'onnxruntime-genai-0.14.0-osx-arm64/lib/libonnxruntime-genai.dylib',
        assetName: 'onnxruntime-genai',
      ),
    );
  }
  if (os == OS.linux && arch == Architecture.x64) {
    return const _OrtBundle(
      dirName: 'linux_x64',
      ort: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime/releases/download/'
            'v1.27.0/onnxruntime-linux-x64-1.27.0.tgz',
        sha256:
            '547e40a48f1fe73e3f812d7c88a948612c23f896b91e4e2ee1e232d7b468246f',
        extractedLibPath:
            'onnxruntime-linux-x64-1.27.0/lib/libonnxruntime.so.1.27.0',
        assetName: 'onnxruntime',
      ),
      genai: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime-genai/releases/'
            'download/v0.14.0/onnxruntime-genai-0.14.0-linux-x64.tar.gz',
        sha256:
            '7b37f13619ee01263278fb1c24a950e219d75c9fa90586b1623d3e8bab9076b0',
        extractedLibPath:
            'onnxruntime-genai-0.14.0-linux-x64/lib/libonnxruntime-genai.so',
        assetName: 'onnxruntime-genai',
      ),
    );
  }
  if (os == OS.windows && arch == Architecture.x64) {
    return const _OrtBundle(
      dirName: 'windows_x64',
      ort: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime/releases/download/'
            'v1.27.0/onnxruntime-win-x64-1.27.0.zip',
        sha256:
            'c5c81710938e68079ff1a192b04897faabe4b43830d48f39f27ecd4e16138bfc',
        extractedLibPath: 'onnxruntime-win-x64-1.27.0/lib/onnxruntime.dll',
        assetName: 'onnxruntime',
      ),
      genai: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime-genai/releases/'
            'download/v0.14.0/onnxruntime-genai-0.14.0-win-x64.zip',
        sha256:
            '8a303e52dc7be8fb2a5331929af451a25ac59774102d7fd09ef673adc85c5ebf',
        extractedLibPath:
            'onnxruntime-genai-0.14.0-win-x64/lib/onnxruntime-genai.dll',
        assetName: 'onnxruntime-genai',
      ),
    );
  }
  if (os == OS.android && arch == Architecture.arm64) {
    return const _OrtBundle(
      dirName: 'android_arm64',
      // Both archives are AARs — a zip containing per-ABI .so files under
      // jni/<abi>/, plus AndroidManifest.xml/classes.jar/*4j_jni.so
      // (ORT's Java wrapper) or *-genai-jni.so (GenAI's) noise this hook has
      // no use for — rather than a flat tarball like every other platform
      // here. [_Archive.extractedLibPath] pointing at the single concrete
      // `.so` inside `jni/arm64-v8a/` skips that Java-wrapper noise for
      // free, same mechanism as the macOS/Linux/Windows entries picking one
      // file out of their own archive's larger layout.
      //
      // NOT on the onnxruntime GitHub release (only Maven Central publishes
      // the Android AAR) — verified by checking v1.27.0's release assets.
      ort: _Archive(
        url:
            'https://repo1.maven.org/maven2/com/microsoft/onnxruntime/'
            'onnxruntime-android/1.27.0/onnxruntime-android-1.27.0.aar',
        sha256:
            '077dec5e2d821234c7dc0aba584bec8f999854b546c754cab93a90741c56fbeb',
        extractedLibPath: 'jni/arm64-v8a/libonnxruntime.so',
        assetName: 'onnxruntime',
      ),
      // NOT on Maven Central (probed com.microsoft.onnxruntime[.genai|-genai]
      // — all 404) — same GitHub-release supply chain as the desktop GenAI
      // archives above, just a differently-shaped AAR asset. GenAI's AAR
      // ships arm64-v8a + x86_64 only (no armeabi-v7a) — arm64 is the only
      // viable device ABI, not a policy choice.
      genai: _Archive(
        url:
            'https://github.com/microsoft/onnxruntime-genai/releases/'
            'download/v0.14.0/onnxruntime-genai-android-0.14.0.aar',
        sha256:
            'c2e9b967a1ecdf766246fbee8572c6637df01183cc263f9b954c01a9ec591f69',
        extractedLibPath: 'jni/arm64-v8a/libonnxruntime-genai.so',
        assetName: 'onnxruntime-genai',
      ),
    );
  }
  // ios x86_64 (Intel-Mac simulator; see this function's doc), android
  // x86_64/armeabi-v7a: no entry means the hook silently skips those
  // targets (matches flutter_gemma_litertlm's "no checksum registered →
  // skip" convention); GenAiFfiClient's own dlopen then fails loud at first
  // use with a clear "no such file".
  return null;
}

/// The archive(s) that make up one platform's bundle, plus the bundle
/// version tag used for the cache marker. Every platform but iOS carries
/// TWO archives (`ort` + `genai`) — iOS's genai framework statically links
/// ORT and exports both APIs from the one binary (see this file's top doc),
/// so [ort] is `null` there. **Never add a second ORT asset for iOS** — that
/// would be redundant (a second copy of the same statically-linked symbols
/// under a different CodeAsset name) and defeats the whole point of iOS
/// shipping one self-contained artifact.
class _OrtBundle {
  const _OrtBundle({
    required this.dirName,
    required this.ort,
    required this.genai,
  });

  final String dirName;
  final _Archive? ort;
  final _Archive genai;

  /// Cache-invalidation key — bump whenever either archive's URL/sha changes.
  String get version =>
      ort == null ? 'genai-0.14.0' : 'ort-1.27.0_genai-0.14.0';

  List<_Archive> get archives => [?ort, genai];
}

// ============================================================================
// Cache layout (namespaced under this package — no cross-package sharing).
// ============================================================================

Directory _cacheBaseDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (Platform.isWindows) {
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    return Directory('$localAppData\\flutter_gemma\\native\\onnx_genai');
  }
  if (Platform.isMacOS) {
    return Directory('$home/Library/Caches/flutter_gemma/native/onnx_genai');
  }
  return Directory('$home/.cache/flutter_gemma/native/onnx_genai');
}

File _markerFile(_OrtBundle bundle) =>
    File('${_cacheBaseDir().path}/${bundle.dirName}/.version');

String? _readMarkerVersion(_OrtBundle bundle) {
  final m = _markerFile(bundle);
  if (!m.existsSync()) return null;
  try {
    final decoded = jsonDecode(m.readAsStringSync()) as Map<String, dynamic>;
    final v = decoded['version'];
    return v is String ? v : null;
  } catch (_) {
    return null;
  }
}

void _writeMarker(_OrtBundle bundle) {
  _markerFile(
    bundle,
  ).writeAsStringSync(jsonEncode({'version': bundle.version}));
}

/// Local in-tree prebuilt override — `native/onnx_genai/prebuilt/<dirName>/`,
/// e.g. for a developer who already has the spike's downloaded dylibs and
/// wants to iterate on the hook without re-fetching from GitHub. Absent in
/// normal use; falls through to the cache / download path.
Directory? _localPrebuiltDir(Uri packageRoot, _OrtBundle bundle) {
  final dir = Directory.fromUri(
    packageRoot.resolve('native/onnx_genai/prebuilt/${bundle.dirName}/'),
  );
  final hasBoth = bundle.archives.every(
    (a) => _stagedSourceFile(dir, a).existsSync(),
  );
  return hasBoth ? dir : null;
}

// ============================================================================
// Download + verify + extract
// ============================================================================

Future<bool> _downloadVerifyExtract(_Archive archive, Directory destDir) async {
  final cacheRoot = destDir.parent; // .../onnx_genai/<dirName>/
  if (!cacheRoot.existsSync()) cacheRoot.createSync(recursive: true);
  final archiveFile = File('${cacheRoot.path}/${archive.archiveFileName}');

  try {
    stderr.writeln('flutter_gemma_onnx: downloading ${archive.url} ...');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(archive.url));
      // GitHub release assets 302-redirect to an S3-style signed URL; a
      // plain HttpClient request follows redirects by default, but be
      // explicit since a silent non-follow would produce a 3-byte HTML body
      // that "downloads" successfully and then fails the sha256 check with
      // a confusing mismatch instead of a clear HTTP-status error.
      request.followRedirects = true;
      final response = await request.close();
      if (response.statusCode != 200) {
        stderr.writeln(
          'flutter_gemma_onnx: download failed (HTTP ${response.statusCode}) '
          'for ${archive.url}',
        );
        await response.drain<void>();
        return false;
      }
      final sink = archiveFile.openWrite();
      await response.pipe(sink);
    } finally {
      client.close();
    }

    final bytes = await archiveFile.readAsBytes();
    final actual = sha256.convert(bytes).toString();
    if (actual != archive.sha256) {
      stderr.writeln(
        'flutter_gemma_onnx: checksum mismatch for ${archive.archiveFileName}\n'
        '  expected: ${archive.sha256}\n'
        '  actual:   $actual',
      );
      archiveFile.deleteSync();
      return false;
    }
    stderr.writeln(
      'flutter_gemma_onnx: checksum verified (${archive.archiveFileName})',
    );

    final tmpDir = Directory('${cacheRoot.path}/.tmp-extract-$pid');
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync(recursive: true);
    try {
      // Windows archives (ORT/ORT-GenAI's own release layout) are PKZIP, not
      // tar.gz — `-z` unconditionally forces a gzip decompress pass, which
      // fails outright on a real .zip (true of both GNU tar and bsdtar).
      // Android's two archives are AARs, which are ALSO PKZIP under the
      // hood (an AAR is just a zip with a fixed internal layout) — same
      // "not gzip" problem, just a different file extension.
      final lowerName = archive.archiveFileName.toLowerCase();
      final isZip = lowerName.endsWith('.zip') || lowerName.endsWith('.aar');
      final ProcessResult result;
      if (isZip && !Platform.isWindows) {
        // Portable choice for zip/AAR extraction OFF Windows: macOS's `tar`
        // is bsdtar and CAN read zip via `-xf`, but Linux ships GNU tar,
        // which cannot — this hook runs on both when cross-building for
        // Android, so `unzip` (present on every macOS/Linux dev box and CI
        // image already used to build Android APKs) is used unconditionally
        // instead of tar for zip/AAR content on non-Windows hosts.
        result = await Process.run('unzip', [
          '-o',
          archiveFile.path,
          '-d',
          tmpDir.path,
        ]);
      } else {
        // Every Windows box since 10 (build 17063) ships `tar.exe` as
        // bsdtar, which auto-detects the container format (including zip)
        // from `-xf` alone — this hook only ever needs `.zip`/`.aar`
        // handling ON Windows for the desktop archives (Android is never
        // built from a Windows host in this repo's flow), so bsdtar's
        // availability there is guaranteed, not an assumption about the
        // host. Non-zip archives (macOS/Linux `.tar.gz`/`.tgz`) always use
        // `-xzf` regardless of host OS.
        result = await Process.run('tar', [
          if (isZip) '-xf' else '-xzf',
          archiveFile.path,
          '-C',
          tmpDir.path,
        ]);
      }
      if (result.exitCode != 0) {
        stderr.writeln(
          'flutter_gemma_onnx: extract failed for ${archive.archiveFileName}: '
          '${result.stderr}',
        );
        return false;
      }
      final extracted = File('${tmpDir.path}/${archive.extractedLibPath}');
      if (!extracted.existsSync()) {
        stderr.writeln(
          'flutter_gemma_onnx: extracted archive is missing the expected '
          'lib at ${archive.extractedLibPath} — archive layout changed?',
        );
        return false;
      }
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      final destFileName = extracted.uri.pathSegments.last;
      final destPath = '${destDir.path}/$destFileName';
      extracted.copySync(destPath);

      final thinArch = archive.thinArch;
      if (thinArch != null) {
        // iOS's simulator slice ships as a fat arm64+x86_64 Mach-O — pull
        // the single arch this hook targets out to a distinct temp path
        // first (rather than `-output` the same path in place) so a failed
        // lipo run can't leave a half-written file behind.
        final thinnedPath = '$destPath.thin';
        final thinResult = await Process.run('lipo', [
          '-thin',
          thinArch,
          destPath,
          '-output',
          thinnedPath,
        ]);
        if (thinResult.exitCode != 0) {
          stderr.writeln(
            'flutter_gemma_onnx: lipo -thin $thinArch failed for $destPath: '
            '${thinResult.stderr}',
          );
          return false;
        }
        final infoResult = await Process.run('lipo', ['-info', thinnedPath]);
        final infoOut = infoResult.stdout.toString().trim();
        if (infoResult.exitCode != 0 || !infoOut.contains(thinArch)) {
          stderr.writeln(
            'flutter_gemma_onnx: lipo -info after thinning did not report '
            '"$thinArch" for $thinnedPath: $infoOut',
          );
          return false;
        }
        File(thinnedPath).renameSync(destPath);
        stderr.writeln(
          'flutter_gemma_onnx: thinned $destFileName to $thinArch ($infoOut)',
        );
      }
    } finally {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    }
    archiveFile.deleteSync();
    return true;
  } catch (e) {
    stderr.writeln(
      'flutter_gemma_onnx: fetch failed for ${archive.archiveFileName}: $e',
    );
    if (archiveFile.existsSync()) archiveFile.deleteSync();
    return false;
  }
}

/// Extracted lib's on-disk filename inside [destDir] for [archive] — the
/// concrete versioned filename copied out of the archive (e.g.
/// `libonnxruntime.1.27.0.dylib`), not the canonical asset name.
File _stagedSourceFile(Directory destDir, _Archive archive) {
  final fileName = archive.extractedLibPath.split('/').last;
  return File('${destDir.path}/$fileName');
}

// ============================================================================
// Entry point
// ============================================================================

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final codeConfig = input.config.code;
    final os = codeConfig.targetOS;
    final arch = codeConfig.targetArchitecture;
    // iOS distinguishes device vs simulator via IOSSdk — exact
    // flutter_gemma_litertlm precedent (`_prebuiltDirName`/`codeConfig.iOS.
    // targetSdk`). `null`/unused on every other OS.
    final iOSSdk = os == OS.iOS ? codeConfig.iOS.targetSdk : null;

    final bundle = _archivesFor(os, arch, iOSSdk: iOSSdk);
    if (bundle == null) return; // unsupported target this phase — see doc.

    // Both Android AARs (onnxruntime-android + onnxruntime-genai-android)
    // declare minSdkVersion=24 in their own AndroidManifest.xml. There is no
    // Gradle module here to force a manifest-merger floor (unlike
    // flutter_gemma_builtin_ai's minSdk-26 module), so an app with a lower
    // minSdk builds cleanly and only fails at runtime `dlopen` — and only on
    // API 21-23 devices, the hardest kind of bug to catch pre-release. So
    // fail the build here — and actually fail it. This used to write the
    // diagnostic and `return`, which produced a GREEN build that dies at the
    // first dlopen on every device, i.e. exactly the outcome the paragraph
    // above says it exists to prevent.
    if (os == OS.android && codeConfig.android.targetNdkApi < 24) {
      throw StateError(
        'flutter_gemma_onnx: ORT / ORT-GenAI require Android minSdk 24 '
        '(this build targets minSdk ${codeConfig.android.targetNdkApi}). '
        "Raise android/app/build.gradle(.kts)'s `minSdk` to 24 or higher "
        'before using OnnxEngine()/OnnxEmbeddingBackend() on Android.',
      );
    }

    final cacheDir = Directory('${_cacheBaseDir().path}/${bundle.dirName}');
    final localDir = _localPrebuiltDir(input.packageRoot, bundle);
    final storedVersion = _readMarkerVersion(bundle);
    final useCache = localDir == null && storedVersion == bundle.version;

    Directory libDir;
    if (localDir != null) {
      libDir = localDir;
    } else if (useCache && cacheDir.existsSync()) {
      libDir = cacheDir;
    } else {
      // (Re)fetch every archive whose version changed or is missing.
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      for (final archive in bundle.archives) {
        final ok = await _downloadVerifyExtract(archive, cacheDir);
        if (!ok) {
          // NOT a `return`. `_downloadVerifyExtract` answers false for a failed
          // download AND for a checksum mismatch, and returning there produced
          // a build that exits 0 with no ORT / ORT-GenAI CodeAsset — the #316
          // shape, and the opposite of what the rag_sqlite and litertlm hooks
          // do with the same condition. An integrity failure in particular has
          // no benign reading.
          throw StateError(
            'flutter_gemma_onnx: could not obtain ${archive.archiveFileName} '
            'for ${bundle.dirName} — see the diagnostics above (download '
            'failure or CHECKSUM MISMATCH). This platform is registered as '
            'supported, so a missing library is a broken build, not a skip.',
          );
        }
      }
      _writeMarker(bundle);
      libDir = cacheDir;
    }

    // APPLE-ONLY stage(): copy each dylib into the hook's outputDirectory
    // before registering it as a CodeAsset. Without this, Native Assets
    // would register the CodeAsset straight from the cache dir (which is
    // also listed as a build dependency below) — Xcode's "Flutter Assemble"
    // Run Script then takes a directoryTreeSignature over that input dir,
    // which now contains its own output, producing "Cycle inside Flutter
    // Assemble". Exact same fix as flutter_gemma_litertlm's hook; see that
    // file's longer note. Apple-only in this package (macOS + iOS); Linux
    // gets a related-but-different rename below, Windows/Android are no-ops.
    // CRITICAL (codex Phase-1 finding, confirmed via a real `flutter build
    // macos`): Flutter's macOS/iOS asset-bundling derives each `.framework`'s
    // NAME from the STAGED FILE'S OWN FILENAME, not from the CodeAsset's
    // `name:` field — a naive `stage()` that preserves
    // `libonnxruntime.1.27.0.dylib`'s on-disk name produces
    // `onnxruntime1270.framework/onnxruntime1270` (dots collapsed out of the
    // version suffix), which GenAI's bare-name
    // `dlopen("libonnxruntime.dylib")` and `GenAiFfiClient`'s own
    // `'onnxruntime.framework/onnxruntime'` candidate can never match. On iOS
    // this is a no-op RENAME rather than a version-suffix collapse (the
    // extracted `onnxruntime-genai` leaf is already un-versioned — see
    // `_archivesFor`'s iOS branch — so `destFileName` here is just adding
    // the `lib`/`.dylib` wrapping) but the SAME derivation mechanism applies:
    // Flutter's iOS embedder also names the `.framework` after the staged
    // file. [destFileName] renames the staged copy to the CANONICAL bare
    // name (`libonnxruntime.dylib` / `libonnxruntime-genai.dylib`) so the
    // derived framework is `<name>.framework/<name>` — verified end-to-end
    // on macOS below; codesigning on iOS is Flutter's embed-phase re-sign of
    // every Native-Assets framework with the app identity (same as
    // litertlm's iOS dylibs) — nothing extra needed in this hook.
    //
    // LINUX gets the same treatment for a different reason: Microsoft's own
    // Linux tarballs ship the concrete versioned file
    // (`libonnxruntime.so.1.27.0`), not the bare `libonnxruntime.so` name
    // `GenAiFfiClient`'s `_candidateNames` bare-name dlopen looks for — copy
    // + rename closes that gap, same as the macOS framework-name fix above.
    // WINDOWS stays a no-op: its .dll archives already ship under the bare
    // canonical name (`onnxruntime.dll`), so no rename is needed — and
    // CLAUDE.md's build-native scar warns that ACTIVE staging on Windows
    // (splitting companion DLLs) is what hangs cancel/close, so this
    // deliberately does not opt Windows in even though it would be a no-op
    // byte-for-byte copy today.
    // `stage()` sees every archive this hook registers, so it also records what
    // was READ. `output.dependencies` lists `libDir` below, but a DIRECTORY
    // entry is hashed as the sorted list of child NAMES only (`_hashDirectory`
    // in package:native_assets_builder — verified against 0.13.0:
    // `recursive: false`, no content, no mtime; private, so re-check after a
    // Flutter SDK bump), so replacing a library in place leaves the hash
    // identical and the
    // hook is skipped. Files are content-hashed; listing them is what makes a
    // re-fetched or hand-replaced runtime reach the next build. The directory
    // entry stays, to notice an archive appearing or disappearing.
    final consumed = <Uri>[];

    Uri stage(File src, String destFileName) {
      consumed.add(src.uri);
      if (os != OS.macOS && os != OS.iOS && os != OS.linux) return src.uri;
      final destUri = input.outputDirectory.resolve(destFileName);
      final dest = File.fromUri(destUri);
      if (!dest.existsSync() || !_sameBytes(src, dest)) {
        dest.parent.createSync(recursive: true);
        src.copySync(destUri.toFilePath());
      }
      return destUri;
    }

    for (final archive in bundle.archives) {
      final src = _stagedSourceFile(libDir, archive);
      if (!src.existsSync()) {
        // Was a `continue` "to be safe". It is not safe: it drops one library
        // out of a multi-library bundle and reports success, so ORT-GenAI can
        // ship without the ORT it dlopens by bare name.
        throw StateError(
          'flutter_gemma_onnx: ${archive.assetName} is missing from '
          '${libDir.path} after resolution. The directory is present but '
          'incomplete — most often a cache left over from an interrupted '
          'extract. Delete it and build again.',
        );
      }
      final canonicalFileName = switch (os) {
        OS.linux || OS.android => 'lib${archive.assetName}.so',
        OS.windows => '${archive.assetName}.dll',
        _ => 'lib${archive.assetName}.dylib',
      };
      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: 'src/native/${archive.assetName}',
          linkMode: DynamicLoadingBundled(),
          file: stage(src, canonicalFileName),
        ),
      );
    }
    output.dependencies.add(libDir.uri);
    output.dependencies.addAll(consumed);
    // And the branch that did NOT win — see the same note in the litertlm and
    // rag_sqlite hooks. Naming a directory that does not exist is free: it
    // hashes to a sentinel and flips the moment it appears.
    final localCandidate = _localPrebuiltDir(input.packageRoot, bundle);
    if (localCandidate != null && localCandidate.uri != libDir.uri) {
      output.dependencies.add(_watchableAncestor(localCandidate).uri);
    }
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
/// Byte-identical in `flutter_gemma_rag_sqlite` and `flutter_gemma_litertlm`;
/// the packages publish independently and cannot share it.
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
