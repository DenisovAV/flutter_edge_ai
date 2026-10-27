// Where an EmbeddingGemma 2 `.litertlm` bundle runs: the generic bundle on
// CPU, or on the GPU when asked for where that is measured
// ([liteRtLmEmbeddingGpuAbis]), a per-SoC bundle on that SoC's NPU — decided in
// `LiteRtEmbeddingBackend.describe()`, on the caller's isolate, before any
// worker or engine exists.
//
// The rule (owner-approved design, 2026-10-12) is that nothing switches
// backend on its own: vectors from the NPU bundle and the CPU bundle live in
// different spaces, so a request that cannot be served as asked is refused
// with an `EmbeddingLoadException` that names what to do instead.
// - generic bundle + npu → refused, naming the per-SoC bundles;
// - per-SoC bundle without npu → refused (it runs nowhere else);
// - per-SoC bundle + npu → runs where this package ships the vendor's
//   dispatch: a Qualcomm bundle on Qualcomm Android arm64 and Qualcomm Linux
//   arm64, with the app's opt-in Qualcomm NPU stack (`qualcomm_npu`, the flag
//   the LLM path uses) and a device whose FastRPC the stack can reach; an
//   Intel bundle (Google's `…_Intel_PTL`, Panther Lake) on Windows x64, with
//   the Intel stack every Windows build carries beside the executable — added
//   in 1.13.2 without a run on Intel NPU hardware; a Google Tensor bundle
//   (`…_Google_Tensor_G5|G6`) on Android arm64, with the app's opt-in Tensor
//   dispatch (`google_tensor_npu`) on a device LiteRT runs the Tensor NPU on
//   (Android 16 or later, not a BP2A build) — the G6 270m and 440m run on a
//   Pixel 11, G5 not run; anything else is refused, never moved to CPU.
// What the bundle IS comes from its own bytes (`readLiteRtLmNpuTarget`), not
// from its file name.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../bundle/litertlm_bundle_info.dart' show npuVendorOf;
import '../ffi/litert_lm_client.dart' show NpuDispatchUnavailableException;
import '../ffi/npu_vendor_host.dart';
import '../npu_stacks.dart';
import 'litert_lm_embedding_common.dart';
import 'litertlm_npu_target.dart';

/// Where the pass will run a bundle: [backend] `cpu` for a generic bundle
/// (`gpu` when asked for on a [liteRtLmEmbeddingGpuAbis] host), `npu` for a
/// per-SoC one, with its [target] and the [dispatchDir] LiteRT loads the
/// vendor's dispatch from.
typedef LiteRtLmEmbeddingPlacement = ({
  PreferredBackend backend,
  LiteRtLmNpuTarget? target,
  String? dispatchDir,
});

/// The host [placeLiteRtLmEmbedder] asks when it is given none —
/// `LiteRtEmbeddingBackend.describe()` passes none. Replaced only by tests,
/// which describe on a host with no NPU.
@visibleForTesting
LiteRtLmNpuHost liteRtLmNpuHost = const LiteRtLmPlatformNpuHost();

/// Where each build has run, per platform and backend: the model registry's
/// page, generated from its recorded runs. A list in an error message goes
/// stale with the next run; the page does not.
const liteRtLmRegistryUrl = 'https://flutteredge.ai/docs/registry';

/// The hosts, in `Abi.current()` spelling, where a generic EmbeddingGemma 2
/// bundle runs on the GPU when `preferredBackend: gpu` asks for it: LiteRT-LM's
/// GPU executor over the WebGPU accelerator these archives ship. Measured
/// 2026-10-22 on the 270m, ten golden texts: Windows x64 on Lunar Lake (Arc
/// iGPU, DX12) 22 ms per embedding vs 83-90 ms on its CPU, Linux x64 on a
/// Tesla T4 (Vulkan) 32-64 ms vs 232-308 ms; min cos 0.997 to the CPU vectors
/// on both, and to Sentence Transformers fp32 0.9765-0.9767 vs 0.9763 on CPU.
/// The adapter is Dawn's choice: with no GPU driver loaded, Linux ran it on
/// Mesa's llvmpipe (software Vulkan), reported as gpu, 37-48 s per load, and
/// a ~900-token text failed there with DEADLINE_EXCEEDED.
/// Only the text tower runs on the GPU: on the 440m and 740m the pass names
/// their vision and audio towers cpu (`readLiteRtLmMediaTowers`), which is
/// not yet measured on these hosts. The GPU runs FP16 activations by default. macOS and iOS are not here: their
/// Metal accelerator ends the process with a SIGBUS in LiteRT's external
/// weight loader (`PrepareAccessForBuffer`) at engine create (measured on
/// macOS), which no Dart code can catch. Android's OpenCL accelerator and
/// Linux arm64 are not measured. Elsewhere a `gpu` request runs on CPU, with
/// core's not-applied notice, as before.
const liteRtLmEmbeddingGpuAbis = {'windows_x64', 'linux_x64'};

/// Whether this host is one of [liteRtLmEmbeddingGpuAbis], asked of the same
/// host [placeLiteRtLmEmbedder] places on, so the two never disagree.
bool liteRtLmEmbeddingGpuHost() =>
    liteRtLmEmbeddingGpuAbis.contains(liteRtLmNpuHost.abi);


/// Decides where [file] runs for a [requested] backend, or refuses with an
/// [EmbeddingLoadException] (engine `LiteRT-LM`). [target] is what the bundle
/// was compiled for (`readLiteRtLmNpuTarget`): null for the generic bundle.
///
/// The host is asked only for a per-SoC bundle with `npu` requested, in the
/// order of the cheapest answer first: the platform, the vendor, the build's
/// stack, the device, then the dispatch directory (Android extracts the
/// libraries out of the APK there). Where EmbeddingGemma 2 runs on an NPU is
/// [NpuStack.abis]: Qualcomm on Android arm64 and Linux arm64, Google Tensor
/// and MediaTek on Android arm64, Intel on Windows x64; which builds have run
/// where is [liteRtLmRegistryUrl].
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
    final gpu =
        requested == PreferredBackend.gpu &&
        liteRtLmEmbeddingGpuAbis.contains(host.abi);
    return (
      backend: gpu ? PreferredBackend.gpu : PreferredBackend.cpu,
      target: null,
      dispatchDir: null,
    );
  }
  if (requested != PreferredBackend.npu) {
    _refuse(liteRtLmNpuBundleWithoutNpuRefusal(file, target));
  }
  final hostVendors = NpuStack.forAbi(host.abi);
  if (hostVendors.isEmpty) {
    _refuse(
      '$file is compiled for the $target NPU. flutter_edge_ai_litertlm runs '
      'EmbeddingGemma 2 on the NPU ${liteRtLmEmbeddingNpuHosts()}, and this '
      'is ${host.operatingSystem} (${host.abi}). Install the generic '
      'EmbeddingGemma 2 bundle to embed here on CPU.',
    );
  }
  final vendor = npuVendorOf(target);
  if (vendor == null) {
    _refuse(
      '$file is compiled for a ${target.vendor} NPU (${target.soc}). '
      'flutter_edge_ai_litertlm runs EmbeddingGemma 2 NPU bundles on '
      '${npuSentenceList(NpuStack.values.map((v) => v.label))} NPUs only. '
      'Install the generic EmbeddingGemma 2 bundle to embed on CPU.',
    );
  }
  if (!hostVendors.contains(vendor)) {
    _refuse(
      '$file is compiled for the $target NPU, and on ${host.operatingSystem} '
      '(${host.abi}) flutter_edge_ai_litertlm runs '
      '${npuSentenceList(hostVendors.map((v) => v.label))} NPU bundles only; '
      '${vendor.label} ones run on ${npuSentenceList(vendor.abis)}. Install the '
      'generic EmbeddingGemma 2 bundle to embed here on CPU.',
    );
  }
  // The rule the LLM engine follows too: the build's stack, then the device.
  // Intel's device answer is a yes without a probe (Windows has none), so a PC
  // without an Intel NPU is told apart by the pass's probe embed at load.
  if (await chooseNpuVendor(target: target, host: host) case NpuRefused(
    :final reason,
  )) {
    _refuse('$file needs the $target NPU, and $reason.');
  }
  final String dispatchDir;
  try {
    dispatchDir = await host.prepareDispatchDir(vendor);
  } on NpuDispatchUnavailableException catch (e) {
    throw EmbeddingLoadException(
      '$file needs the $target NPU, and its ${vendor.label} libraries could not '
      'be prepared: ${e.message}',
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
    '${npuSentenceList(NpuStack.values.map(_bundleNames))} '
    'beside it; which have run on which device: $liteRtLmRegistryUrl) and load '
    'it with PreferredBackend.npu. To run this bundle, omit preferredBackend.';

/// The file names litert-community gives [vendor]'s EmbeddingGemma 2 bundles.
String _bundleNames(NpuStack vendor) => switch (vendor) {
  NpuStack.qualcomm => '`<model>_Qualcomm_<SoC>.litertlm`',
  NpuStack.googleTensor => '`<model>_Google_Tensor_G5|G6.litertlm`',
  NpuStack.mediatek => '`<model>_MediaTek_<SoC>.litertlm`',
  NpuStack.intel => '`<model>_Intel_PTL.litertlm`',
};

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
