// What this process can tell about each NPU vendor's stack ([NpuVendor]):
// whether this build carries it, and the directory LiteRT loads its dispatch
// from. Whether the device reaches it is the vendor's probe, in
// backend_preference.dart. The LLM engine (litert_lm_engine_host.dart) and the
// EmbeddingGemma 2 placement (litert_lm_npu.dart) both ask here, so the two
// cannot disagree about a vendor.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import '../litert_lm_load_errors.dart' show NpuDispatchUnavailableException;
import '../npu_stacks.dart';
import 'npu_stack_manifest.dart';

/// Whether this build carries [vendor]'s NPU stack where LiteRT will load it:
/// for Qualcomm, what NativeAssetsManifest.json says the build bundled
/// ([checkQualcommNpuStack]); for Intel, whether its dispatch is beside the
/// executable ([checkIntelNpuStack]).
Future<NpuStackCheck> npuStackOf(NpuVendor vendor) async => switch (vendor) {
  NpuVendor.qualcomm => await checkQualcommNpuStack(),
  NpuVendor.intel => checkIntelNpuStack(windowsNpuDispatchDir),
};

/// The `dispatch_lib_dir` to hand LiteRT for [vendor] on this host: the
/// prepared Qualcomm libraries on Android ([prepareAndroidNpuDispatchDir]) and
/// on Linux ([prepareLinuxNpuDispatchDir]), [windowsNpuDispatchDir] for Intel.
/// Throws [NpuDispatchUnavailableException] when the stack cannot be prepared.
Future<String> prepareNpuDispatchDir(NpuVendor vendor) async =>
    switch (vendor) {
      NpuVendor.qualcomm =>
        Platform.isAndroid
            ? await prepareAndroidNpuDispatchDir(qualcommNpuLibs, vendor.label)
            : prepareLinuxNpuDispatchDir(),
      NpuVendor.intel => windowsNpuDispatchDir,
    };

/// Returns the directory to hand LiteRT as `dispatch_lib_dir` on Android for
/// one vendor's stack, [libs] (CodeAsset names) — for the LLM engine and the
/// EmbeddingGemma 2 embedding pass alike (the pass asks from
/// `LiteRtEmbeddingBackend.describe()`, on the caller's isolate: this goes
/// through a platform channel, which core's worker cannot reach).
///
/// LiteRT opendir()-scans it for libLiteRtDispatch_*.so and loads the first it
/// finds, so the directory must hold this vendor's dispatch and no other's, and
/// the vendor's libraries must exist there as files. The core plugin returns a
/// directory holding exactly [libs] — nativeLibraryDir when the installer
/// extracted them and no other vendor's dispatch is there, else a copy taken
/// from the base APK or its config split (a Play install). The list comes from
/// here because the build decides it.
Future<String> prepareAndroidNpuDispatchDir(
  List<String> libs,
  String vendor,
) async {
  const bundledChannel = MethodChannel('flutter_gemma_bundled');
  final String? dir;
  try {
    dir = await bundledChannel.invokeMethod<String>('prepareNpuDispatchDir', {
      'libs': [for (final n in libs) androidLibFileName(n)],
    });
  } on MissingPluginException {
    throw const NpuDispatchUnavailableException(
      'the installed flutter_edge_ai has no prepareNpuDispatchDir; '
      'update flutter_edge_ai to the version flutter_edge_ai_litertlm '
      'requires',
    );
  } on PlatformException catch (e) {
    throw NpuDispatchUnavailableException(
      'the $vendor NPU libraries could not be prepared '
      '(${e.code}: ${e.message})',
    );
  }
  if (dir == null) {
    throw const NpuDispatchUnavailableException(
      'prepareNpuDispatchDir returned no directory',
    );
  }
  return dir;
}

/// Returns the directory to hand LiteRT as `dispatch_lib_dir` on Linux arm64,
/// after loading what QNN cannot find on its own. Shared with the
/// EmbeddingGemma 2 pass; the libraries it loads are process-wide, so loading
/// them from the caller's isolate serves the embedding worker too.
///
/// Native Assets puts the whole stack in the bundle's `lib/`. From there the
/// dispatch loads libQnnHtp and libQnnSystem by full path, and prepends the
/// directory to `ADSP_LIBRARY_PATH` so FastRPC finds the Skels (fastrpc appends
/// the system DSP paths itself). One step it cannot do: libQnnHtp opens its
/// Hexagon Stub by bare name and has no RPATH, so glibc searches
/// LD_LIBRARY_PATH and the system — never the app — and LD_LIBRARY_PATH cannot
/// change after the process started. A library already loaded under that
/// SONAME is matched first, so the Stubs are loaded here by full path, after
/// the libcdsprpc.so shim they NEED.
String prepareLinuxNpuDispatchDir() {
  final libDir = '${File(Platform.resolvedExecutable).parent.path}/lib';
  final missing = [
    for (final n in qualcommNpuLibsLinux)
      if (!File('$libDir/${androidLibFileName(n)}').existsSync())
        androidLibFileName(n),
  ];
  if (missing.isNotEmpty) {
    throw NpuDispatchUnavailableException(
      'the Qualcomm NPU stack is not in $libDir (missing ${missing.join(', ')}); '
      'build the app with hooks.user_defines.flutter_edge_ai_litertlm.'
      '$qualcommNpuUserDefine: true',
    );
  }
  for (final n in [
    cdsprpcShimLib,
    for (final lib in qairtLinuxLibs)
      if (lib.endsWith('Stub')) lib,
  ]) {
    final path = '$libDir/${androidLibFileName(n)}';
    try {
      DynamicLibrary.open(path);
    } on Object catch (e) {
      throw NpuDispatchUnavailableException('$path did not load: $e');
    }
  }
  return libDir;
}

/// The directory of the running executable: where Native Assets puts a
/// Windows app's DLLs, the Intel NPU stack among them, and the
/// `dispatch_lib_dir` LiteRT gets for an Intel NPU.
String get windowsNpuDispatchDir =>
    File(Platform.resolvedExecutable).parent.path;

/// The library LiteRT loads from the dispatch directory for an Intel NPU: our
/// OpenVINO dispatch, which the Windows x64 native archive carries with
/// OpenVINO and TBB (hook/build.dart, `windowsExtraLibs`). Not opt-in, so it
/// is in every Windows x64 build.
const intelNpuDispatchLib = 'LiteRtDispatch.dll';

/// Whether [dir] holds [intelNpuDispatchLib].
///
/// File presence, unlike [checkQualcommNpuStack]'s manifest: [dir] is the
/// directory LiteRT is pointed at, so the question is what it will find
/// there. Only the dispatch is checked — which of the OpenVINO and TBB
/// libraries a precompiled EmbeddingGemma 2 graph needs has not been
/// established on Intel NPU hardware, and a stack that cannot serve the bundle
/// still fails the pass's probe embed at load.
NpuStackCheck checkIntelNpuStack(String dir) =>
    File('$dir${Platform.pathSeparator}$intelNpuDispatchLib').existsSync()
    ? const NpuStackCheck.bundled()
    : NpuStackCheck.missing(
        '$intelNpuDispatchLib is not beside the executable ($dir). Every '
        'Windows x64 build with flutter_edge_ai_litertlm puts the Intel NPU '
        'stack there; ship all the DLLs the build put next to the executable '
        'with the app',
      );
