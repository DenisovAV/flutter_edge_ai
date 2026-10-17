// Which vendor's NPU a load runs on ([chooseNpuVendor]) and what this process
// can tell about each vendor ([NpuVendor]): whether this build carries its
// stack, whether the device reaches it (the vendor's probe, in
// backend_preference.dart), and the directory LiteRT loads its dispatch from.
// The LLM engine (litert_lm_engine.dart) and the EmbeddingGemma 2 placement
// (litert_lm_npu.dart) both choose here, through one host interface, so the two
// cannot disagree about a vendor.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart' show edgeAiLog;

import '../bundle/litertlm_bundle_info.dart'
    show LiteRtLmNpuTarget, npuVendorOf;
import '../litert_lm_load_errors.dart' show NpuDispatchUnavailableException;
import '../npu_stacks.dart';
import 'backend_preference.dart'
    show npuNoVendorReason, npuUnreachable, platformNpuProbes;
import 'npu_stack_manifest.dart';

/// What choosing an NPU vendor asks of the host. The real one is
/// [LiteRtLmPlatformNpuHost]; tests pass a fake, because every answer here is
/// a property of a device a test host is not.
abstract interface class LiteRtLmNpuHost {
  /// `Platform.operatingSystem`.
  String get operatingSystem;

  /// `Abi.current()`, as its `toString()` (`android_arm64`, `linux_arm64`, …).
  String get abi;

  /// Whether this build carries [vendor]'s NPU stack where LiteRT will load
  /// it ([npuStackOf]): the opt-in Qualcomm stack in NativeAssetsManifest.json,
  /// Intel's dispatch beside the executable.
  Future<NpuStackCheck> stack(NpuVendor vendor);

  /// Why this device cannot run [vendor]'s stack, or null when it can
  /// ([npuUnreachable]: for Qualcomm on Android, FastRPC opens; on Linux, a
  /// compute DSP the user may open, and libcdsprpc.so.1; Windows has no
  /// probe). Asked only for a vendor of [abi].
  String? unreachable(NpuVendor vendor);

  /// The `dispatch_lib_dir` for LiteRT ([prepareNpuDispatchDir]). Throws
  /// [NpuDispatchUnavailableException] when the stack cannot be prepared.
  Future<String> prepareDispatchDir(NpuVendor vendor);
}

/// The host this process runs on.
final class LiteRtLmPlatformNpuHost implements LiteRtLmNpuHost {
  const LiteRtLmPlatformNpuHost();

  @override
  String get operatingSystem => Platform.operatingSystem;

  @override
  String get abi => '${Abi.current()}';

  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) => npuStackOf(vendor);

  @override
  String? unreachable(NpuVendor vendor) =>
      npuUnreachable(vendor, operatingSystem, platformNpuProbes);

  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) =>
      prepareNpuDispatchDir(vendor);
}

/// Which vendor's NPU a load runs on ([NpuChosen]), or why none
/// ([NpuRefused]).
sealed class NpuChoice {
  const NpuChoice();
}

/// The load runs on [vendor]'s NPU.
final class NpuChosen extends NpuChoice {
  const NpuChosen(this.vendor);
  final NpuVendor vendor;
}

/// No NPU this host reaches can run the load; [reason] says why, worded for
/// the person who has to fix it.
final class NpuRefused extends NpuChoice {
  const NpuRefused(this.reason);
  final String reason;
}

/// The one rule for which vendor's NPU a load runs on, for the LLM engine and
/// the EmbeddingGemma 2 placement alike.
///
/// The candidates are the vendors of the host's ABI ([NpuVendor.forAbi]): for a
/// bundle compiled for an NPU ([target], its `LiteRtStamp`), only that vendor;
/// otherwise each in [NpuVendor] declaration order. The caller refuses a
/// stamped vendor this package or this host has no dispatch for before it
/// asks, so that the refusal names the vendor rather than this host's stack.
/// For each candidate the build is asked before the device: an app that did not
/// bundle an opt-in stack must not even dlopen that vendor's library. A stack
/// the manifest cannot vouch for (no binding in a background isolate) goes on
/// to the probe: preparing its dispatch directory checks the libraries before
/// anything is loaded. The first candidate whose stack is there and whose
/// device answers is chosen.
Future<NpuChoice> chooseNpuVendor({
  required LiteRtLmNpuTarget? target,
  required LiteRtLmNpuHost host,
}) async {
  final compiledFor = target == null ? null : npuVendorOf(target);
  final candidates = [
    for (final vendor in NpuVendor.forAbi(host.abi))
      if (target == null || vendor == compiledFor) vendor,
  ];
  if (candidates.isEmpty) return NpuRefused(npuNoVendorReason(host.abi));
  final reasons = <String>[];
  for (final vendor in candidates) {
    final stack = await host.stack(vendor);
    if (!stack.known) {
      edgeAiLog(
        '[NPU] ${stack.reason}; trying the ${vendor.label} NPU, the platform '
        'side checks the libraries',
      );
    } else if (!stack.bundled) {
      reasons.add(stack.reason!);
      continue;
    }
    final unreachable = host.unreachable(vendor);
    if (unreachable == null) return NpuChosen(vendor);
    reasons.add(unreachable);
  }
  return NpuRefused(reasons.join('; '));
}

/// What an NPU attempt hands LiteRT-LM: the `dispatch_lib_dir` its vendor
/// prepared, and whether to turn LiteRT's HW mask update path off.
typedef NpuDispatch = ({String dir, bool disableHwMasking});

/// Whether an LLM engine on [vendor]'s NPU turns `use_hw_masking_for_npu`
/// off. Intel: with it on, LiteRT sets up the kWH HW mask method, which Intel
/// preview NPUs (LunarLake/PantherLake) do not fully support → CFG check
/// failure 0xc0000409 (per Matt Kreileder's Intel NPU pipeline instructions).
bool npuDisablesHwMasking(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => false,
  NpuVendor.intel => true,
};

/// Whether this build carries [vendor]'s NPU stack where LiteRT will load it:
/// for Qualcomm, what NativeAssetsManifest.json says the build bundled
/// ([checkNpuStackInManifest]); for Intel, whether its dispatch is beside the
/// executable ([checkIntelNpuStack]) — the directory LiteRT is pointed at, and
/// a stack that answers [NpuStackCheck.unknown] there would go unchecked:
/// Intel's [prepareNpuDispatchDir] checks nothing.
Future<NpuStackCheck> npuStackOf(NpuVendor vendor) async => switch (vendor) {
  NpuVendor.qualcomm => await checkNpuStackInManifest(vendor),
  NpuVendor.intel => checkIntelNpuStack(windowsNpuDispatchDir),
};

/// The `dispatch_lib_dir` to hand LiteRT for [vendor] on this host: the
/// prepared Qualcomm libraries on Android ([prepareAndroidNpuDispatchDir]) and
/// on Linux ([prepareLinuxNpuDispatchDir]), [windowsNpuDispatchDir] for Intel.
/// Throws [NpuDispatchUnavailableException] when the stack cannot be prepared.
///
/// [operatingSystem] is `Platform.operatingSystem` unless a test names one:
/// that getter has no override seam, so the Windows arm is otherwise
/// unreachable from a test run on another host.
Future<String> prepareNpuDispatchDir(
  NpuVendor vendor, {
  String? operatingSystem,
}) async => switch (vendor) {
  NpuVendor.qualcomm => switch (operatingSystem ?? Platform.operatingSystem) {
    'android' => await prepareAndroidNpuDispatchDir(
      qualcommNpuLibs,
      vendor.label,
    ),
    'linux' => prepareLinuxNpuDispatchDir(),
    final os => throw StateError(
      'NpuVendor.qualcomm has no dispatch directory on $os',
    ),
  },
  NpuVendor.intel => switch (operatingSystem ?? Platform.operatingSystem) {
    'windows' => windowsNpuDispatchDir,
    final os => throw StateError(
      'NpuVendor.intel has no dispatch directory on $os',
    ),
  },
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
/// File presence, unlike [checkNpuStackInManifest]: [dir] is the
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
