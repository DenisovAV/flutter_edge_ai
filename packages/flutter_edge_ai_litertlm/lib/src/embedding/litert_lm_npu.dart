// Where an EmbeddingGemma 2 `.litertlm` bundle runs: the generic bundle on
// CPU, a per-SoC bundle on that SoC's NPU — decided in
// `LiteRtEmbeddingBackend.describe()`, on the caller's isolate, before any
// worker or engine exists.
//
// The rule (owner-approved design, 2026-10-12) is that nothing switches
// backend on its own: vectors from the NPU bundle and the CPU bundle live in
// different spaces, so a request that cannot be served as asked is refused
// with an `EmbeddingLoadException` that names what to do instead.
// - generic bundle + npu → refused, naming the per-SoC bundles;
// - per-SoC bundle without npu → refused (it runs nowhere else);
// - per-SoC bundle + npu → runs on Qualcomm Android arm64 and Qualcomm Linux
//   arm64 only, with the app's opt-in Qualcomm NPU stack (`qualcomm_npu`, the
//   flag the LLM path uses) and a device whose FastRPC the stack can reach;
//   anything else is refused, never moved to CPU.
// What the bundle IS comes from its own bytes (`readLiteRtLmNpuTarget`), not
// from its file name.

import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../ffi/backend_preference.dart'
    show hostNpuUnavailableReason, hostShipsNpuDispatch;
import '../ffi/litert_lm_client.dart'
    show
        NpuDispatchUnavailableException,
        prepareAndroidNpuDispatchDir,
        prepareLinuxNpuDispatchDir;
import '../ffi/npu_stack_manifest.dart';
import 'litert_lm_embedding_common.dart';
import 'litertlm_npu_target.dart';

/// Where the pass will run a bundle: [backend] `cpu` for a generic bundle,
/// `npu` for a per-SoC one, with its [target] and the [dispatchDir] LiteRT
/// loads the Qualcomm dispatch from.
typedef LiteRtLmEmbeddingPlacement = ({
  PreferredBackend backend,
  LiteRtLmNpuTarget? target,
  String? dispatchDir,
});

/// What [placeLiteRtLmEmbedder] asks of the host. The real one is
/// [LiteRtLmPlatformNpuHost]; tests pass a fake, because every answer here is
/// a property of a device a test host is not.
abstract interface class LiteRtLmNpuHost {
  /// `Platform.operatingSystem`.
  String get operatingSystem;

  /// `Abi.current()`, as its `toString()` (`android_arm64`, `linux_arm64`, …).
  String get abi;

  /// Whether this build bundles the opt-in Qualcomm NPU stack
  /// (NativeAssetsManifest.json).
  Future<NpuStackCheck> qualcommStack();

  /// Whether this device can run the bundled stack (Android: FastRPC opens;
  /// Linux: a compute DSP the user may open, and libcdsprpc.so.1).
  bool get hasNpu;

  /// Why [hasNpu] is false, worded for the person who has to fix it.
  String get noNpuReason;

  /// The `dispatch_lib_dir` for LiteRT. Throws
  /// [NpuDispatchUnavailableException] when the stack cannot be prepared.
  Future<String> prepareDispatchDir();
}

/// The host this process runs on.
final class LiteRtLmPlatformNpuHost implements LiteRtLmNpuHost {
  const LiteRtLmPlatformNpuHost();

  @override
  String get operatingSystem => Platform.operatingSystem;

  @override
  String get abi => '${Abi.current()}';

  @override
  Future<NpuStackCheck> qualcommStack() => checkQualcommNpuStack();

  @override
  bool get hasNpu => hostShipsNpuDispatch;

  @override
  String get noNpuReason => hostNpuUnavailableReason;

  @override
  Future<String> prepareDispatchDir() async => Platform.isAndroid
      ? await prepareAndroidNpuDispatchDir()
      : prepareLinuxNpuDispatchDir();
}

/// The host [placeLiteRtLmEmbedder] asks when it is given none —
/// `LiteRtEmbeddingBackend.describe()` passes none. Replaced only by tests,
/// which describe on a host with no NPU.
@visibleForTesting
LiteRtLmNpuHost liteRtLmNpuHost = const LiteRtLmPlatformNpuHost();

/// The hosts that run EmbeddingGemma 2 on an NPU: Qualcomm on Android arm64
/// and on Linux arm64 (VENTUNO Q / QCS8275), the two verified on device.
const liteRtLmNpuEmbeddingAbis = {'android_arm64', 'linux_arm64'};

/// The per-SoC Qualcomm bundles verified on device. Others are published by
/// Google (SM8550, SM8750; Tensor G5/G6; MediaTek MT6991/MT6993; Intel PTL)
/// and not verified here.
const liteRtLmVerifiedNpuSocs = ['SM8850', 'SM8650', 'QCS8275'];

/// Decides where [file] runs for a [requested] backend, or refuses with an
/// [EmbeddingLoadException] (engine `LiteRT-LM`). [target] is what the bundle
/// was compiled for (`readLiteRtLmNpuTarget`): null for the generic bundle.
///
/// The host is asked only for a per-SoC bundle with `npu` requested, in the
/// order of the cheapest answer first: the platform, the vendor, the build's
/// stack, the device, then the dispatch directory (Android extracts the
/// libraries out of the APK there).
Future<LiteRtLmEmbeddingPlacement> placeLiteRtLmEmbedder({
  required String file,
  required LiteRtLmNpuTarget? target,
  required PreferredBackend? requested,
  LiteRtLmNpuHost? host,
}) async {
  host ??= liteRtLmNpuHost;
  if (target == null) {
    if (requested == PreferredBackend.npu) {
      _refuse(liteRtLmGenericOnNpuRefusal(file));
    }
    return (backend: PreferredBackend.cpu, target: null, dispatchDir: null);
  }
  if (requested != PreferredBackend.npu) {
    _refuse(liteRtLmNpuBundleWithoutNpuRefusal(file, target));
  }
  if (!liteRtLmNpuEmbeddingAbis.contains(host.abi)) {
    _refuse(
      '$file is compiled for the $target NPU. flutter_edge_ai_litertlm runs '
      'EmbeddingGemma 2 on the NPU on Qualcomm Android and Qualcomm Linux '
      'arm64 only, and this is ${host.operatingSystem} (${host.abi}). Install '
      'the generic EmbeddingGemma 2 bundle to embed here on CPU.',
    );
  }
  if (!target.isQualcomm) {
    _refuse(
      '$file is compiled for a ${target.vendor} NPU (${target.soc}). '
      'flutter_edge_ai_litertlm runs EmbeddingGemma 2 NPU bundles on Qualcomm '
      'NPUs only. Install the generic EmbeddingGemma 2 bundle to embed on CPU.',
    );
  }
  final stack = await host.qualcommStack();
  if (stack.known && !stack.bundled) {
    _refuse('$file needs the $target NPU, and ${stack.reason}.');
  }
  if (!host.hasNpu) {
    _refuse('$file needs the $target NPU, and ${host.noNpuReason}.');
  }
  final String dispatchDir;
  try {
    dispatchDir = await host.prepareDispatchDir();
  } on NpuDispatchUnavailableException catch (e) {
    throw EmbeddingLoadException(
      '$file needs the $target NPU, and its Qualcomm libraries could not be '
      'prepared: ${e.message}',
      engine: liteRtLmEngineTag,
      cause: e,
    );
  }
  return (
    backend: PreferredBackend.npu,
    target: target,
    dispatchDir: dispatchDir,
  );
}

/// The generic bundle asked to run on the NPU.
String liteRtLmGenericOnNpuRefusal(String file) =>
    '$file is the generic EmbeddingGemma 2 bundle: it has no NPU graph and '
    'runs on CPU only. To embed on the NPU, install the bundle compiled for '
    "this device's SoC (litert-community publishes "
    '`<model>_Qualcomm_<SoC>.litertlm` beside it; '
    '${liteRtLmVerifiedNpuSocs.join(', ')} are verified) and load it with '
    'PreferredBackend.npu. To run this bundle, omit preferredBackend.';

/// A per-SoC bundle asked to run anywhere but the NPU.
String liteRtLmNpuBundleWithoutNpuRefusal(
  String file,
  LiteRtLmNpuTarget target,
) =>
    '$file is compiled for the $target NPU and runs only there: load it with '
    'getActiveEmbedder(preferredBackend: PreferredBackend.npu) on a '
    '${target.soc} device, or install the generic EmbeddingGemma 2 bundle to '
    'embed on CPU. Its vectors are not the CPU bundle\'s, so an index built '
    'with it has its own profile id.';

Never _refuse(String message) =>
    throw EmbeddingLoadException(message, engine: liteRtLmEngineTag);
