import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _packageName = 'flutter_edge_ai_litertlm';

/// The owner recorded in the native-cache marker. The cache is shared by every
/// project on the machine, and one still on the pre-rename `flutter_gemma_litertlm` reads the
/// same marker: recording the old name keeps both of them bundling the
/// library, and [_isMarkerOwner] accepts either name.
const _markerOwner = 'flutter_gemma_litertlm';
bool _isMarkerOwner(String owner) =>
    owner == _markerOwner || owner == _packageName;

// ============================================================================
// Native bundles
// ============================================================================

/// One unit of "fetch a tarball per platform from a GitHub Release, verify
/// SHA256, extract, register the dylibs as CodeAssets". Currently there are
/// two: LiteRT-LM (inference + embedding via LiteRT C API) and qdrant-edge
/// (vector store FFI shim).
///
/// New bundles can be added by appending to [_bundles] without modifying the
/// per-platform/cache/download/extract machinery below.
class _NativeBundle {
  /// Filesystem namespace under [_cacheBaseDir]. Must be unique across bundles
  /// (e.g. `litertlm`, `qdrant_edge`).
  final String namespace;

  /// Release tag suffix; full tag is built as either `native-vX` (LiteRT) or
  /// `qdrant-edge-vX` (qdrant) — see [releaseTagPrefix].
  final String version;

  /// Prefix of the GitHub Release tag: full tag = `$releaseTagPrefix$version`.
  /// LiteRT uses `native-v`, qdrant uses `qdrant-edge-v`.
  final String releaseTagPrefix;

  /// Prefix of each platform archive: full name = `$archivePrefix-$dirName.tar.gz`.
  /// LiteRT: `litertlm`, qdrant: `qdrant-edge`.
  final String archivePrefix;

  /// SHA256 of each archive, keyed by full archive filename
  /// (e.g. `litertlm-linux_x86_64.tar.gz`).
  final Map<String, String> checksums;

  /// Name of the main shared library to register as a CodeAsset (e.g.
  /// `LiteRtLm`, `vec0`). Platform-appropriate extension is added
  /// via [_dylibFileName].
  final String mainLibName;

  /// Companion libraries to register alongside [mainLibName]. May be empty
  /// (qdrant has none). LiteRT has Metal/OpenCL/WebGPU accelerators etc.
  final List<String> companions;

  /// Companions to skip on a specific OS. LiteRT skips Apple companion
  /// dylibs on macOS because of a Native Assets install_name_tool slack
  /// issue (#247) — the Podfile post_install handles them instead.
  final Set<OS> skipCompanionsOn;

  /// Additional libraries to register on Windows only (no `lib` prefix).
  /// LiteRT: lib-prefixed copies for PE imports + DXC runtime + Intel NPU
  /// dispatch. qdrant: none.
  final List<String> windowsExtraLibs;

  /// Additional libraries to register on Android only (no `lib` prefix,
  /// `.so` suffix added automatically). LiteRT: Qualcomm NPU dispatch +
  /// QNN runtime stack (HTP + System + per-SoC Stub libs).
  final List<String> androidExtraLibs;

  /// When `true`, per-platform subdirectories live directly under
  /// [_cacheBaseDir] (`<cacheBase>/macos_arm64/...`). When `false`, they live
  /// under a per-bundle namespace (`<cacheBase>/<namespace>/macos_arm64/...`).
  ///
  /// LiteRT uses flat=true for backwards compatibility — `example/macos/Podfile`
  /// and `example/ios/Podfile` post_install scripts (plus the Xcode
  /// `project.pbxproj` build phase) hardcode the flat path. Any new bundle
  /// must use flat=false to avoid colliding with LiteRT files.
  final bool useFlatLayout;

  const _NativeBundle({
    required this.namespace,
    required this.version,
    required this.releaseTagPrefix,
    required this.archivePrefix,
    required this.checksums,
    required this.mainLibName,
    required this.markerFileName,
    this.companions = const [],
    this.skipCompanionsOn = const {},
    this.windowsExtraLibs = const [],
    this.androidExtraLibs = const [],
    this.useFlatLayout = false,
  });

  /// Name of the marker file that stores the cached bundle version. For LiteRT
  /// (flat layout) it's `.flutter_gemma_native_version` at the cache root, kept
  /// stable for backwards compatibility. For namespaced bundles it's
  /// `.version` inside the bundle's namespace subdirectory.
  final String markerFileName;

  String get releaseTag => '$releaseTagPrefix$version';
  String get releaseBase =>
      'https://github.com/DenisovAV/flutter_edge_ai/releases/download/$releaseTag';

  /// Directory containing this bundle's per-platform subdirectories. For flat
  /// layout that's the cache root itself; for namespaced bundles it's the
  /// `<cacheBase>/<namespace>/` subdir.
  Directory cacheRoot() => useFlatLayout
      ? _cacheBaseDir()
      : Directory('${_cacheBaseDir().path}/$namespace');

  /// Absolute path of the marker file that tracks the cached version of this
  /// bundle. Always lives at [cacheRoot] root (alongside the per-platform
  /// subdirs).
  File markerFile() => File('${cacheRoot().path}/$markerFileName');

  String archiveName(String dirName) => '$archivePrefix-$dirName.tar.gz';

  /// All filenames this bundle owns on disk inside one per-platform subdir.
  /// Used by [_invalidateBundleCacheIfStale] to wipe only this bundle's files
  /// when running in flat layout (LiteRT shares its dir with future bundles).
  Iterable<String> ownedFileNames(OS os) sync* {
    yield _dylibFileName(os, mainLibName);
    // StreamProxy is bundled with LiteRT only — but we let the file-existence
    // check at use sites decide. Listing it here is harmless either way.
    yield _dylibFileName(os, 'StreamProxy');
    for (final c in companions) {
      yield _dylibFileName(os, c);
    }
    if (os == OS.windows) {
      for (final w in windowsExtraLibs) {
        yield _dylibFileName(os, w);
      }
    }
    if (os == OS.android) {
      for (final a in androidExtraLibs) {
        yield _dylibFileName(os, a);
      }
    }
  }
}

/// LiteRT-LM native library version and release info.
///
/// 0.17.0 — built from LiteRT-LM `e9fd8c53` (v0.17.0) with LiteRT `9fe5be45`.
/// All 7 platforms rebuilt; the zlib mirror patch is gone (the v0.17.0
/// WORKSPACE lists the mirrors itself).
/// The GPU samplers' `Create` gained a leading `runtime_c_api` argument —
/// upstream refreshed the prebuilt samplers with it, so nothing to patch here.
/// The 4 `tbb*_debug.dll` files 0.16.0 still carried are dropped on purpose
/// (#437: release TBB only).
///
/// 0.16.0 — built from LiteRT-LM `924e79c9` with LiteRT `0ff28117`. There is no
/// native-v0.15.0; the jump is 0.14.0 → 0.16.0. All 7 platforms rebuilt.
///
/// Fixes the Android OpenCL per-turn leak (#348/#402, upstream #2699). Upstream
/// changed `LiteRtLmStreamCallback` from 4 args to a 2-arg opaque chunk with no
/// compat path — libStreamProxy resolves the shape at runtime.
///
/// Windows GPU works again: our build had been passing
/// `--define=litert_link_capi_so=true`, a name upstream deleted. Bazel accepts
/// unknown defines silently, so the LiteRt runtime linked statically and
/// conflicted with the separately shipped WebGPU accelerator once Dawn was split
/// out. Corrected to `litert_runtime_link_mode=dynamic` +
/// `resolve_symbols_in_exec=false` (both documented as mandatory for GPU).
///
/// Both NPU dispatch stacks are now BUILT FROM THE PIN, not carried forward —
/// carrying them is what broke NPU on both platforms. Intel ships a version
/// matched OpenVino (2026.3.0.dev20260622); Qualcomm ships a dispatch rebuilt
/// from the derived LiteRT ref together with the 10 QNN runtime libs refreshed
/// from the same QAIRT 2.44.0.260225 (the stale pair failed with
/// `Qnn System library version 1.8.0 is mismatched`, minimum 1.11.0).
///
/// Apple: `-Wl,-headerpad_max_install_names` (Native Assets re-runs
/// install_name_tool on every pub get), macOS `-mmacosx-version-min=11.0` —
/// libStreamProxy.dylib had been inheriting the build host and shipped minos
/// 26.0 since native-v0.14.0. iOS vtool minos 13.0 (#245).
/// Android: `-Wl,-z,max-page-size=16384` (Google Play 16KB).
const _litertlmBundle = _NativeBundle(
  namespace: 'litertlm',
  version: '0.17.1-a',
  releaseTagPrefix: 'native-v',
  archivePrefix: 'litertlm',
  mainLibName: 'LiteRtLm',
  // Flat layout: example/macos/Podfile, example/ios/Podfile, and the macOS
  // Xcode `project.pbxproj` build phase all hardcode
  // `${HOME}/Library/Caches/flutter_gemma/native/<platform>` without a bundle
  // namespace. Keep flat=true here until we migrate those user-facing scripts
  // in a dedicated PR (tracked: roadmap entry in CHANGELOG for 0.16.0).
  useFlatLayout: true,
  markerFileName: '.flutter_gemma_native_version',
  // 0.17.1 is upstream v0.17.1 (5e58e9a0), one commit over v0.17.0: tool-call
  // arguments declared `"type": "integer"` reach the app as integers instead
  // of 1000.0. Every platform is rebuilt from that source — Apple and Android
  // locally, both Linux and Windows in CI — and the LiteRT pin is unchanged
  // (9fe5be45), so the C API embeddings and speech bind to did not move.
  //
  // libGemmaModelConstraintProvider still comes from upstream MAIN (4453b286),
  // not from the tag: v0.17.1 ships the same pre-ComputeMask provider v0.17.0
  // did, and against a runtime built from its own source every tool call
  // segfaults in CompositeLogitMask::Apply. Both build scripts and both CI
  // workflows assert the two sides agree before compiling anything.
  //
  // The Android bundle also carries the Qualcomm Skel blobs with p_align
  // raised to 16 KB: the QAIRT SDK ships them at 0x1000, androidExtraLibs puts
  // them in every consumer APK, and Google Play rejects the app for it (#529).
  // build_qualcomm_dispatch.sh does the bump; verify_tarball_manifest.sh
  // refuses to publish an Android archive that still has one below 16 KB.
  //
  // 0.17.1-a changes two Android files and nothing else: upstream's OpenCL and
  // GPU accelerators import AHardwareBuffer_* weakly without libandroid.so in
  // DT_NEEDED, bionic binds them to NULL, and Mali GPUs crash at engine_create
  // (#545). build_android.sh step 8c adds the NEEDED entry and step 8d refuses a
  // library whose imports its own NEEDED chain cannot reach. The other six
  // archives are byte-identical to native-v0.17.1.
  // These sums must equal both the bytes GitHub
  // serves and the `checksums_litertlm.txt` published on the release — a stale
  // txt sent a user down the wrong path while debugging a mismatch (#316).
  checksums: {
    'litertlm-linux_x86_64.tar.gz':
        '3f7854efdd73c893d48bc43df66102fda5c1de63179295275a37acb9427a949e',
    'litertlm-linux_arm64.tar.gz':
        'c2e784185840534aeb10e78b19b3771e1eab699e193ce72a6ec6dc67fc0eb47e',
    'litertlm-windows_x86_64.tar.gz':
        'e505e247b07313c05bbc957b7c33c82f6adb6c6c78eecae03a590319c7d049e2',
    'litertlm-macos_arm64.tar.gz':
        '37c64a2e7cd4d5c06ad150b866ee71f39cc84ccd159cf9e2db30792ef0e71d49',
    'litertlm-ios_arm64.tar.gz':
        '8aaf35425790d527728dde4736579c660af08f9baddfd0161a868cfb302626de',
    'litertlm-ios_sim_arm64.tar.gz':
        'a95766deae012c8441ef1e1d2e2501d3db3bbbde6b014cceccc5cde98bb94836',
    'litertlm-android_arm64.tar.gz':
        '745b89b606eb712a78f06aed41daca1370eae79b00e0a36054c8e775c0251768',
  },
  companions: [
    'GemmaModelConstraintProvider',
    'LiteRtMetalAccelerator', // macOS + iOS GPU (Metal)
    'LiteRtTopKMetalSampler', // macOS + iOS device GPU sampler (Metal)
    'LiteRtGpuAccelerator', // Android GPU
    'LiteRtOpenClAccelerator', // Android OpenCL
    'LiteRtWebGpuAccelerator', // Linux/Windows GPU (WebGPU → Vulkan/DX12)
    'LiteRtTopKOpenClSampler', // Android OpenCL GPU sampler — honors seed
    'LiteRtTopKWebGpuSampler', // Linux/Windows GPU sampler
    'LiteRt', // Linux/Windows core runtime
    'webgpu_dawn', // Linux/Windows Dawn WebGPU (split to a shared lib in v0.14.0)
  ],
  // On macOS, skip the upstream Apple companion dylibs from Native Assets
  // bundling (#247). The companion dylibs Google ships in
  // `prebuilt/macos_arm64/` (`libGemmaModelConstraintProvider.dylib`,
  // `libLiteRtMetalAccelerator.dylib`; the Metal sampler is not shipped at
  // all) were linked without `-Wl,-headerpad_max_install_names`, leaving only
  // 32 bytes of slack in the load-commands area. Dart Native Assets'
  // JIT path (`dart run`, `dart build_runner`, `flutter test` on a pure
  // Dart library) calls `install_name_tool -id <absolute_path>` with paths
  // 80–110 chars long, which doesn't fit and aborts the whole bundling
  // step. By dropping these from the asset list, Native Assets never
  // touches them — instead `example/macos/Podfile` post_install copies
  // each dylib into `App.app/Contents/Frameworks/<X>.framework/` itself
  // and patches LiteRtLm.dylib's `LC_LOAD_DYLIB` reference to the new
  // framework path. iOS / Linux / Windows / Android are unaffected: their
  // Native Assets paths (Xcode build phases on iOS, no install_name_tool
  // on Linux/Windows/Android) don't trigger the bug.
  skipCompanionsOn: {OS.macOS},
  // Windows: LiteRtLm.dll references companion DLLs by their original
  // Google filenames with "lib" prefix (libLiteRt.dll etc.) via PE imports.
  // Native Assets uses no prefix on Windows (LiteRt.dll), so we ship both
  // names from the CI artifact — register the lib-prefixed copies here
  // so the PE loader can resolve imports at LoadLibrary time. Plus the
  // DirectXShaderCompiler runtime (WebGPU/DX12) and the Intel NPU
  // dispatch (LiteRtDispatch.dll + OpenVino + TBB).
  windowsExtraLibs: [
    'libGemmaModelConstraintProvider',
    'libLiteRt',
    'libLiteRtTopKWebGpuSampler',
    'libLiteRtWebGpuAccelerator',
    'libwebgpu_dawn', // lib-prefixed for the accelerator's PE import (v0.14.0)
    // DXC runtime
    'dxil',
    'dxcompiler',
    // Intel NPU dispatch (~102 MB, only enables PreferredBackend.npu on
    // LunarLake/PantherLake — model still loads on CPU/GPU without it).
    //
    // THIS LIST AND THE WORKFLOW'S `$ovWanted` ARE ONE SET IN TWO PLACES.
    // The tarball is what CI assembles; this is what becomes a CodeAsset and
    // lands next to the app binary. A name present there and absent here
    // extracts to the cache and is never shipped — which is exactly how
    // openvino_intel_npu_compiler(.dll/_loader.dll) went missing at v0.16.0:
    // 78.8 MB of the stack, allow-listed and `throw`-guarded in CI, silently
    // not bundled, so openvino_intel_npu_plugin could not resolve its compiler
    // and backend=npu stayed broken in the release that set out to fix it.
    // Change one, change the other.
    'LiteRtDispatch',
    'openvino',
    'openvino_intel_npu_plugin',
    'openvino_intel_npu_compiler',
    'openvino_intel_npu_compiler_loader',
    'openvino_tensorflow_lite_frontend',
    // Release TBB only. The debug variants were being registered into user
    // apps — 1.8 MB of parallel debug builds sitting beside the release set,
    // which is the mis-binding hazard the workflow's allow-list exists to
    // avoid, reintroduced one layer down.
    'tbb12',
    'tbbbind_2_5',
    'tbbmalloc',
    'tbbmalloc_proxy',
  ],
  // Android NPU: Qualcomm dispatch bridge + QNN HTP runtime + per-SoC Stubs.
  //
  // No longer extracted from Google AI Edge Gallery APKs — that is what let
  // them drift. `build_qualcomm_dispatch.sh` builds the dispatch from the
  // LiteRT ref derived from the pin, and refreshes all ten QNN runtime libs
  // from the same QAIRT the dispatch was compiled against (2.44.0.260225).
  // The extracted set had QNN System API 1.8.0 against a dispatch requiring
  // 1.11.0, which fails engine_create with an opaque null on real hardware.
  //
  // sm8550=V73, sm8650=V75, sm8750=V79, sm8850=V81.
  // Stub libs are the CPU-side bridge; Skel libs run on Hexagon DSP via FastRPC.
  androidExtraLibs: [
    'LiteRtDispatch_Qualcomm',
    'QnnHtp',
    'QnnSystem',
    'QnnHtpV73Stub',
    'QnnHtpV73Skel',
    'QnnHtpV75Stub',
    'QnnHtpV75Skel',
    'QnnHtpV79Stub',
    'QnnHtpV79Skel',
    'QnnHtpV81Stub',
    'QnnHtpV81Skel',
  ],
);

const _bundles = [_litertlmBundle];

// ============================================================================
// Per-platform name resolution
// ============================================================================

/// Resolve prebuilt directory name for the given OS + architecture.
/// iOS distinguishes device vs simulator via IOSSdk.
String? _prebuiltDirName(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  if (os == OS.iOS) {
    // Only arm64 is supported. On Apple Silicon Macs, Flutter still invokes
    // the hook for x86_64 simulator slices; returning null skips them so
    // Native Assets's lipo step doesn't try to merge two arm64-only inputs
    // and fail with "same architectures and can't be in the same fat file".
    if (arch != Architecture.arm64) return null;
    if (iOSSdk == IOSSdk.iPhoneSimulator) {
      return 'ios_sim_arm64';
    }
    return 'ios_arm64';
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

// ============================================================================
// Cache layout
// ============================================================================

/// Platform-appropriate base directory for all native caches. Per-bundle
/// subdirectories live underneath (e.g. `<cacheBase>/litertlm/macos_arm64/`).
///
/// The path is **not** versioned because example/macos/Podfile and
/// example/ios/Podfile read companion dylibs from a stable location;
/// version invalidation happens via per-bundle `.version` marker files
/// (see [_invalidateBundleCacheIfStale]).
Directory _cacheBaseDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (Platform.isWindows) {
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    return Directory('$localAppData\\flutter_gemma\\native');
  }
  if (Platform.isMacOS) {
    return Directory('$home/Library/Caches/flutter_gemma/native');
  }
  return Directory('$home/.cache/flutter_gemma/native');
}

/// Reads the JSON marker for [bundle]. Returns null if absent, malformed, or
/// LEGACY plain-text (pre-protocol) — all treated as "not present" so the next
/// step re-fetches and rewrites the marker as JSON (self-heal).
({String version, String owner})? _readMarker(_NativeBundle bundle) {
  final m = bundle.markerFile();
  if (!m.existsSync()) return null;
  try {
    final decoded = jsonDecode(m.readAsStringSync()) as Map<String, dynamic>;
    final v = decoded['version'];
    final o = decoded['owner'];
    if (v is String && o is String) return (version: v, owner: o);
    return null;
  } catch (_) {
    return null; // legacy plain-text or corrupt → treat as absent
  }
}

/// Writes the JSON marker {version, owner}. owner = [_markerOwner].
/// COMMIT POINT: call LAST, only after the dylib files are fully in place.
void _writeMarker(_NativeBundle bundle) {
  bundle.markerFile().writeAsStringSync(
    jsonEncode({'version': bundle.version, 'owner': _markerOwner}),
  );
}

/// Wipe stale per-platform cached files when a bundle's version changes. Cheap
/// (one marker read) and idempotent: if the JSON marker matches this bundle's
/// version, do nothing; if missing, legacy plain-text, or a mismatched version,
/// delete this bundle's files in every per-platform subdir. The next
/// `_resolveLibDir` falls through to `_downloadAndExtract` for whatever platform
/// the build targets. WIPE-ONLY — does NOT write the marker; `_writeMarker` is
/// the commit point in `_processBundle`, called only AFTER the dylib is in place
/// (so an interrupted fetch leaves no marker → clean refetch next build).
///
/// For namespaced bundles (`useFlatLayout=false`) we sweep entire per-platform
/// subdirs — nobody else owns them. For flat-layout LiteRT we delete only the
/// files listed by [_NativeBundle.ownedFileNames] so a hypothetical second
/// flat bundle wouldn't be wiped collaterally.
void _invalidateBundleCacheIfStale(_NativeBundle bundle) {
  final cacheRoot = bundle.cacheRoot();
  if (!cacheRoot.existsSync()) {
    cacheRoot.createSync(recursive: true);
  }
  final stored = _readMarker(bundle);
  if (stored != null && stored.version == bundle.version) return;

  final platformPattern = RegExp(r'^(linux|macos|ios|android|windows)_');
  for (final entity in cacheRoot.listSync()) {
    if (entity is! Directory) continue;
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!platformPattern.hasMatch(name)) continue;

    if (bundle.useFlatLayout) {
      // Shared dir — delete only files this bundle owns. Iterate every OS
      // (we don't know which one the subdir was populated for; just attempt
      // all names — `deleteSync` is a no-op when the file is absent).
      for (final os in OS.values) {
        for (final fileName in bundle.ownedFileNames(os)) {
          final f = File('${entity.path}/$fileName');
          if (f.existsSync()) {
            f.deleteSync();
          }
        }
      }
    } else {
      // Exclusive dir — wipe the whole platform subdir, faster + cleaner.
      entity.deleteSync(recursive: true);
    }
  }
}

// ============================================================================
// Dynamic-library file naming
// ============================================================================

/// Dylib filename for [name] on [os]: `lib<name>.so/dylib` on Unix-like
/// systems, `<name>.dll` on Windows. The lib prefix is applied unconditionally
/// for now — both LiteRT and qdrant use it on every Unix-like target.
String _dylibFileName(OS os, String name) {
  return switch (os) {
    OS.windows => '$name.dll',
    OS.macOS || OS.iOS => 'lib$name.dylib',
    _ => 'lib$name.so',
  };
}

bool _hasMainLib(Directory dir, _NativeBundle bundle, OS os) {
  if (!dir.existsSync()) return false;
  final fileName = _dylibFileName(os, bundle.mainLibName);
  return File('${dir.path}/$fileName').existsSync();
}

/// Try to resolve libs from a directory. Returns the directory if the bundle's
/// main lib exists. Search order:
///   1. local `native/<bundle-namespace>/prebuilt/<dirName>/` inside the
///      package — useful for in-tree development.
///   2. cached `<cacheBase>/<bundle-namespace>/<dirName>/` from a previous
///      `_downloadAndExtract`.
/// Package-relative local prebuilt directory for [bundle] on [dirName].
///
/// LiteRT keeps the historical `native/litert_lm/`; new bundles use
/// `native/<namespace>/`.
String _localPrebuiltPath(_NativeBundle bundle, String dirName) =>
    bundle.namespace == 'litertlm'
    ? 'native/litert_lm/prebuilt/$dirName/'
    : 'native/${bundle.namespace}/prebuilt/$dirName/';

Directory? _resolveLibDir(
  _NativeBundle bundle,
  String dirName,
  Uri packageRoot,
  OS os,
) {
  // Local prebuilts use a per-bundle directory layout under `native/`.
  // LiteRT historically uses `native/litert_lm/prebuilt/`. For new bundles
  // we use `native/<namespace>/prebuilt/`.
  final localDir = Directory.fromUri(
    packageRoot.resolve(_localPrebuiltPath(bundle, dirName)),
  );
  if (_hasMainLib(localDir, bundle, os)) return localDir;

  final cacheDir = Directory('${bundle.cacheRoot().path}/$dirName');
  if (_hasMainLib(cacheDir, bundle, os)) return cacheDir;

  return null;
}

// ============================================================================
// Download + verify + extract
// ============================================================================

Future<Directory?> _downloadAndExtract(
  _NativeBundle bundle,
  String dirName,
) async {
  final archiveName = bundle.archiveName(dirName);
  final expectedChecksum = bundle.checksums[archiveName];
  if (expectedChecksum == null) {
    // No checksum registered — the ONLY legitimate reason this function
    // returns null. Mirrors LiteRT-LM's behaviour for targets we ship nothing
    // for (android_x86_64). The build proceeds without this CodeAsset and the
    // runtime fails at first use with a clear "no such file" dlopen error.
    //
    // Every other failure below THROWS. A registered checksum is a promise
    // that this platform is supported, so failing to produce the library is a
    // broken build, not a skip — and a hook that returns null there completes
    // successfully, ships an app with no native library, and surfaces as an
    // opaque dlopen crash on the user's device (#316's shape).
    return null;
  }

  final cacheRoot = bundle.cacheRoot();
  final targetDir = Directory('${cacheRoot.path}/$dirName');
  final archiveFile = File('${cacheRoot.path}/$archiveName');

  try {
    if (!cacheRoot.existsSync()) {
      cacheRoot.createSync(recursive: true);
    }

    final url = '${bundle.releaseBase}/$archiveName';
    stderr.writeln(
      'flutter_edge_ai: Downloading ${bundle.namespace} native libs from $url ...',
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError(
          'flutter_edge_ai: could not download ${bundle.namespace} native libs '
          'for $dirName — HTTP ${response.statusCode} from $url.\n'
          'This platform HAS a registered checksum, so the archive is expected '
          'to exist. Check network access to github.com, or that release tag '
          '"${bundle.releaseTag}" still carries $archiveName.',
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
      // GitHub served are not the bytes this plugin version was built against
      // — a re-uploaded tag (#316), a corrupted transfer, or a MITM. Shipping
      // an app without the library, or with the wrong one, are both worse than
      // failing here.
      throw StateError(
        'flutter_edge_ai: CHECKSUM MISMATCH for $archiveName.\n'
        '  expected $expectedChecksum\n'
        '  actual   $actualChecksum\n'
        'The archive served by ${bundle.releaseBase} does not match what '
        '${bundle.namespace} ${bundle.version} was pinned to. Re-run to rule '
        'out a corrupt transfer; if it persists, the release asset was '
        'replaced after publication and the pin can no longer be satisfied — '
        'do NOT work around it by clearing the checksum.',
      );
    }
    stderr.writeln('flutter_edge_ai: Checksum verified ($archiveName)');

    // Extract into a sibling temp dir on the SAME filesystem (under cacheRoot),
    // then atomically rename into place. A torn/interrupted extract leaves only
    // the temp dir (cleaned in finally), never a half-populated targetDir.
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
          'flutter_edge_ai: could not extract $archiveName for '
          '${bundle.namespace} — tar exited ${result.exitCode}.\n'
          '${result.stderr}\n'
          'The download and its checksum both passed, so this is local: '
          'disk space or permissions. (A MISSING tar cannot reach this branch '
          'at all — Process.run raises ProcessException instead of returning a '
          'non-zero code — so do not read this as "tar not installed".)',
        );
      }
      if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
      tmpDir.renameSync(targetDir.path); // atomic on same FS
    } finally {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    }
    archiveFile.deleteSync();
    stderr.writeln(
      'flutter_edge_ai: ${bundle.namespace} libs cached to ${targetDir.path}',
    );
    return targetDir;
  } on StateError {
    // Already carries a crafted message — clean up and let it through.
    if (archiveFile.existsSync()) archiveFile.deleteSync();
    rethrow;
  } catch (e) {
    // Everything else, and this is the COMMON path: no network, DNS failure,
    // a proxy or firewall refusing github.com, TLS interception, a 429. Those
    // used to `return null` and now would surface as a bare SocketException
    // with a 17-frame stack and no guidance — the four crafted messages above
    // all cover rarer cases than this one.
    if (archiveFile.existsSync()) archiveFile.deleteSync();
    throw StateError(
      'flutter_edge_ai: could not fetch ${bundle.namespace} native libs for '
      '$dirName.\n'
      '  $e\n'
      'This platform is supported, so the build cannot continue without them.\n'
      '  - No network / restricted egress? The archives come from '
      'github.com/DenisovAV/flutter_edge_ai/releases (tag ${bundle.releaseTag}), '
      'not from pub.dev, so mirroring pub is not enough.\n'
      '  - Transient (GitHub 5xx or 429)? Re-run; there is no retry here.\n'
      '  - Working on the plugin itself? A populated '
      'native/litert_lm/prebuilt/$dirName/ is used before any download.',
    );
  }
}

// ============================================================================
// Per-bundle processing — register CodeAssets from resolved libDir
// ============================================================================

/// Cross-package coordination for a shared native bundle. Inspects the marker:
///   - (present: true)  → exact (bundle, version) already cached → dedup
///   - (present: false) → caller fetches (absent, legacy, OR same-owner upgrade)
///   - THROWS           → a DIFFERENT owner placed a DIFFERENT version (skew).
/// Call FIRST in _processBundle. The existing _resolveLibDir/_hasMainLib do the
/// actual from-cache dedup; the guard's load-bearing job is the throw on skew.
({bool present}) _guardAndCheckPresent(_NativeBundle bundle) {
  final existing = _readMarker(bundle);
  // absent / legacy → fetch.
  if (existing == null) return (present: false);
  // exact match → dedup.
  if (existing.version == bundle.version) return (present: true);
  // same-owner upgrade → fetch.
  if (_isMarkerOwner(existing.owner)) return (present: false);
  throw StateError(
    'Native library conflict for "${bundle.namespace}": '
    'this package ($_packageName) needs version ${bundle.version}, '
    'but "${existing.owner}" already placed version ${existing.version} '
    'in the shared cache (${bundle.cacheRoot().path}). '
    'Align the ${bundle.namespace} bundle version across these packages '
    "(each package's hook/build.dart pins it).",
  );
}

Future<void> _processBundle({
  required _NativeBundle bundle,
  required BuildInput input,
  required BuildOutputBuilder output,
  required OS os,
  required String dirName,
}) async {
  // Skip the bundle entirely if it has no checksum for this platform.
  // Both bundles use this as the "is this target supported" gate.
  if (!bundle.checksums.containsKey(bundle.archiveName(dirName))) return;

  // Cross-package version-skew guard (throws on a different owner declaring a
  // different version of this shared bundle). Match/absent/same-owner are no-ops
  // here — _resolveLibDir below does the actual dedup; this call exists so the
  // THROW happens before any fetch/wipe on a skew.
  _guardAndCheckPresent(bundle);

  // Sole owner of libLiteRtLm now; the single-registrant marker is vestigial
  // (cache-dedup only).
  //
  // Single-registrant: only the bundle's owner (the first hook to write the
  // marker) registers the shared CodeAssets. A non-owner package sharing the
  // same bundle (e.g. embeddings sharing litertlm's libLiteRtLm) ensures the
  // cache is populated (dedup/download below) but must NOT re-register the same
  // dylib — Native Assets errors on a duplicate bundled filename, and both FFI
  // loaders open it by a FIXED basename (libLiteRtLm.so / LiteRtLm.framework),
  // so exactly one package must bundle it. At runtime the non-owner's
  // DynamicLibrary.open(filename) resolves the owner-bundled dylib.
  //
  // KNOWN LIMITATION (orphaned-owner edge case): the owner is persisted in the
  // shared-cache marker ACROSS builds. A Dart build hook is sandboxed — it sees
  // only its own packageRoot; BuildInput.assets/metadata expose ONLY direct
  // dependencies (hooks config.dart, ToBuildHooks dartdoc), and litertlm /
  // embeddings deliberately don't depend on each other (embeddings is
  // autonomous). So a hook CANNOT learn the current build's package set and
  // CANNOT recompute the registrant per-build. If the recorded owner is later
  // dropped from the app's deps and the survivor rebuilds without `flutter
  // clean`, the survivor reads the stale owner, skips registration, and nobody
  // bundles the dylib → an opaque dlopen "no such file" at first use. Fix:
  // `flutter clean` + delete the flutter_gemma native cache (see each package's
  // README troubleshooting). Upstream deliberately chose "one registrant + error
  // on conflict, no auto-dedup" (dart-lang/native#190, flutter#158214).
  //
  // Capture the owner state BEFORE _writeMarker below can overwrite it: a
  // non-owner dedup must not clobber the marker's owner to itself.
  final existingOwner = _readMarker(bundle)?.owner;
  final iAmRegistrant = existingOwner == null || _isMarkerOwner(existingOwner);

  _invalidateBundleCacheIfStale(bundle);

  var libDir = _resolveLibDir(bundle, dirName, input.packageRoot, os);
  libDir ??= await _downloadAndExtract(bundle, dirName);
  // Null now means one thing only: no checksum registered for this platform,
  // i.e. we ship nothing for it on purpose. Every real failure throws.
  if (libDir == null) return;

  final prebuiltDir = libDir.uri;
  final mainFileName = _dylibFileName(os, bundle.mainLibName);
  final mainFileUri = prebuiltDir.resolve(mainFileName);
  if (!File.fromUri(mainFileUri).existsSync()) {
    // We got a directory — from the cache, a local prebuilt, or a verified
    // download — and the one library the bundle exists to deliver is not in
    // it. Returning here registered no CodeAsset and reported success, so a
    // half-populated cache shipped as a working build.
    throw StateError(
      'flutter_edge_ai: ${bundle.namespace} $dirName resolved to '
      '${prebuiltDir.toFilePath()} but $mainFileName is missing from it.\n'
      'The directory is present but incomplete — most often a cache left over '
      'from an interrupted extract. Delete it, then `flutter clean` and build '
      'again. NOT `flutter pub get`: pub get does not run build hooks, so it '
      'will not repopulate the cache (measured — output.json mtimes unchanged).',
    );
  }

  // Commit point: marker written only after the dylib is confirmed in place.
  // Gated on iAmRegistrant so a non-owner dedup never clobbers the owner.
  if (iAmRegistrant) _writeMarker(bundle);

  // Non-owner stops here: cache is populated, but the owner registers the
  // shared CodeAssets to avoid a duplicate bundled-filename error.
  if (!iAmRegistrant) return;

  // Flutter's native-assets pipeline declares every `CodeAsset.file` as a
  // build OUTPUT and every `output.dependencies` entry as a build INPUT (see
  // flutter_tools build_system/targets/native_assets.dart `DartBuild`).
  // Registering a dylib straight from `prebuiltDir` (the global cache, which we
  // also list as a dependency below) makes the output dylib live INSIDE an
  // input directory. Xcode then takes a directoryTreeSignature over that input
  // dir which includes the output dylib, so the macOS "Flutter Assemble" Run
  // Script ends up depending on its own output → "Cycle inside Flutter
  // Assemble" (and "located outside of the allowed root paths" warnings).
  //
  // Fix: copy each dylib into the hook's `outputDirectory` (an allowed root
  // that never overlaps the cache dependency dir) and register the CodeAsset
  // from there. The cache dir stays an input-only dependency for rebuild
  // detection. Copies compare CONTENT, not length — see [_sameBytes].
  //
  // APPLE-ONLY: the "Cycle inside Flutter Assemble" self-loop is an Xcode
  // mechanism (the Run Script's directoryTreeSignature over an input dir that
  // contains the output dylib). Windows (MSBuild) and Linux (Ninja) have no
  // such cycle, so staging there solves nothing — and on Windows it actively
  // breaks the PE loader: it splits the main `LiteRtLm.dll` (staged) away from
  // its dynamically-loaded companion DLLs (samplers / Intel-NPU dispatch /
  // openvino / tbb) that stay in the cache, so a `dlopen` of a companion on
  // cancel/close cannot find it and hangs. So stage ONLY on the Apple
  // toolchain, where the cycle actually occurs; elsewhere register straight
  // from the cache (the layout the loader expects), keeping every file
  // consistent regardless of which list it came from.
  //
  // ---------------------------------------------------------------------
  // The rest of this comment is NOT Apple-specific.
  //
  // Every registered asset passes through `stage()`, which makes it the one
  // place that knows what this hook actually READ — so it records those files
  // as dependencies too.
  //
  // `output.dependencies` already lists `prebuiltDir`, but a DIRECTORY entry is
  // hashed as the sorted list of child NAMES and nothing else
  // (`_hashDirectory` in package:native_assets_builder — verified against
  // 0.13.0: `recursive: false`, no content, no mtime. It is a private symbol
  // in a package nothing here depends on directly, so re-check it after a
  // Flutter SDK bump.) Rebuilding these dylibs in place keeps every name, so
  // the hash is unchanged and the hook is skipped entirely — the new binaries
  // never reach the build, and `stage()` never even runs to notice.
  //
  // Measured, not inferred: the hash this repo's own build recorded for
  // `prebuilt/ios_arm64/` is md5 of the four child names joined by ';',
  // truncated to a little-endian int64 —
  //
  //   "libGemmaModelConstraintProvider.dylib;libLiteRtLm.dylib;"
  //   "libLiteRtMetalAccelerator.dylib;libStreamProxy.dylib"
  //   -> 7433067446362060770
  //
  // (Written as two adjacent literals with the ';' inside the first, so the
  // string is reproducible by copy-paste. A `\` line continuation means
  // nothing in a `//` comment, and the earlier version of this note that used
  // one hashed to a different number than the one it claimed.)
  //
  // That is the entire invalidation signal for four dylibs, and it is why a
  // local `build_ios.sh` used to need `flutter clean` to take effect.
  //
  // Files are content-hashed, so listing them is what closes that. The
  // directory entry stays: it is the only thing that notices a NEW companion
  // appearing, since the lists below are `existsSync`-guarded. Cost is
  // paid on every up-to-date check, not only when the hook runs, and it is
  // well under a second for the 19-file / 154 MB android_arm64 set on a warm
  // cache. No figure is quoted because it is a single-machine measurement and
  // will read as false on a slower host.
  final consumed = <Uri>[];

  Uri stage(Uri srcUri) {
    consumed.add(srcUri);
    if (os != OS.macOS && os != OS.iOS) return srcUri;
    final src = File.fromUri(srcUri);
    final destUri = input.outputDirectory.resolve(srcUri.pathSegments.last);
    final dest = File.fromUri(destUri);
    if (!dest.existsSync() || !_sameBytes(src, dest)) {
      dest.parent.createSync(recursive: true);
      src.copySync(destUri.toFilePath());
    }
    return destUri;
  }

  output.assets.code.add(
    CodeAsset(
      package: _packageName,
      name: 'src/native/${bundle.mainLibName}',
      linkMode: DynamicLoadingBundled(),
      file: stage(mainFileUri),
    ),
  );

  // StreamProxy companion (LiteRT only — a tiny C lib that copies callback
  // strings to heap). Lives in the same tarball, registered by convention.
  // Other bundles can ignore it by simply not shipping a `StreamProxy.*` file.
  final proxyFileName = _dylibFileName(os, 'StreamProxy');
  final proxyFileUri = prebuiltDir.resolve(proxyFileName);
  if (File.fromUri(proxyFileUri).existsSync()) {
    output.assets.code.add(
      CodeAsset(
        package: _packageName,
        name: 'src/native/StreamProxy',
        linkMode: DynamicLoadingBundled(),
        file: stage(proxyFileUri),
      ),
    );
  }

  // Companion libraries (accelerators, samplers, etc.).
  final skipCompanions = bundle.skipCompanionsOn.contains(os);
  for (final name in bundle.companions) {
    if (skipCompanions) continue;
    final fileName = _dylibFileName(os, name);
    final fileUri = prebuiltDir.resolve(fileName);
    if (File.fromUri(fileUri).existsSync()) {
      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: 'src/native/$name',
          linkMode: DynamicLoadingBundled(),
          file: stage(fileUri),
        ),
      );
    }
  }

  // Windows-only extras (lib-prefixed companions for PE imports, DXC, NPU).
  if (os == OS.windows) {
    for (final name in bundle.windowsExtraLibs) {
      final fileName = _dylibFileName(os, name);
      final fileUri = prebuiltDir.resolve(fileName);
      if (File.fromUri(fileUri).existsSync()) {
        output.assets.code.add(
          CodeAsset(
            package: _packageName,
            name: 'src/native/$name',
            linkMode: DynamicLoadingBundled(),
            file: stage(fileUri),
          ),
        );
      }
    }
  }

  // Android-only extras (Qualcomm NPU dispatch + QNN runtime stack).
  if (os == OS.android) {
    for (final name in bundle.androidExtraLibs) {
      final fileName = _dylibFileName(os, name);
      final fileUri = prebuiltDir.resolve(fileName);
      if (File.fromUri(fileUri).existsSync()) {
        output.assets.code.add(
          CodeAsset(
            package: _packageName,
            name: 'src/native/$name',
            linkMode: DynamicLoadingBundled(),
            file: stage(fileUri),
          ),
        );
      }
    }
  }

  // A bundle that skips its companions on this OS (see [skipCompanionsOn])
  // leaves them for the app's own build phase to stage. Ship that phase its
  // script through the one path it can already find.
  if (bundle.skipCompanionsOn.contains(os) && bundle.companions.isNotEmpty) {
    final staged = _shipCompanionStager(
      input.packageRoot,
      Directory('${bundle.cacheRoot().path}/$dirName'),
    );
    if (staged != null) {
      output.dependencies.add(staged.source);
      // The destination too: the cache is shared across checkouts, so an app
      // on an older plugin version can overwrite this file. Its content hash
      // is what makes this hook re-run and put its own version back, instead
      // of the Xcode phase silently executing the other checkout's script.
      output.dependencies.add(staged.destination);
    }
  }

  output.dependencies.add(prebuiltDir);
  output.dependencies.addAll(consumed);
  // And the branch that did NOT win. The entries above describe the directory
  // that resolved and the files read from it, which notices a rewrite of a file
  // already in use — but not a change in WHICH directory wins. If the cache
  // resolved and the maintainer then runs build_*.sh, no recorded hash moves,
  // the hook is skipped, and the fresh local build is ignored until
  // `flutter clean`. A directory that does not exist hashes to a sentinel and
  // flips the moment it is created, so naming it while absent costs nothing.
  final localDir = Directory.fromUri(
    input.packageRoot.resolve(_localPrebuiltPath(bundle, dirName)),
  );
  if (localDir.uri != prebuiltDir) {
    output.dependencies.add(_watchableAncestor(localDir).uri);
  }
}

// ============================================================================
// Entry point
// ============================================================================

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final codeConfig = input.config.code;
    final os = codeConfig.targetOS;

    // Supported platforms: desktop + iOS + Android.
    // Web uses MediaPipe JS + wa-sqlite (dart:ffi blocked in WASM).
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
    if (dirName == null) return; // Unsupported arch (e.g. arm32), skip.

    for (final bundle in _bundles) {
      await _processBundle(
        bundle: bundle,
        input: input,
        output: output,
        os: os,
        dirName: dirName,
      );
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
/// Byte-identical in `flutter_edge_ai_sqlite` and `flutter_edge_ai_onnx`; the
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

/// Name of the companion-staging script, in `tool/` here and copied into the
/// native cache dir next to the dylibs it stages.
const _stagerFileName = 'stage_macos_companions.sh';

/// Source and destination of the shipped staging script.
typedef _StagedScript = ({Uri source, Uri destination});

/// Copy `tool/[_stagerFileName]` next to the dylibs it stages.
///
/// The app's Xcode build phase cannot locate a file inside this package:
/// `flutter_edge_ai_litertlm` declares no macOS plugin, so Flutter creates no
/// `.symlinks/plugins/` entry for it, and the pub-cache path is not knowable
/// from a Podfile. The flat native cache dir is the one location the phase
/// already resolves — it reads the companion dylibs from there — so the script
/// travels with them.
///
/// Returns null when the script is absent (a consumer on an older plugin
/// version), leaving the phase to report the missing file itself.
_StagedScript? _shipCompanionStager(Uri packageRoot, Directory cacheDir) {
  final src = File.fromUri(packageRoot.resolve('tool/$_stagerFileName'));
  if (!src.existsSync()) return null;
  final dst = File('${cacheDir.path}/$_stagerFileName');
  // Content-compare, not the bundle `.version` marker: the script's version is
  // the PACKAGE's, so a plugin-only patch release must be able to replace it
  // without a native re-tag.
  if (!dst.existsSync() || !_sameBytes(src, dst)) {
    dst.parent.createSync(recursive: true);
    src.copySync(dst.path);
  }
  // `copySync` does not carry the executable bit — callers invoke it as
  // `sh <path>` rather than executing it directly.
  return (source: src.uri, destination: dst.uri);
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
