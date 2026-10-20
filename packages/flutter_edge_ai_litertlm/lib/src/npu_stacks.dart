/// The NPU vendors this package dispatches to and their stacks, named once for
/// the places that must agree on them: the build hook (what gets bundled), the
/// runtime gate (what this build bundled, read back from Flutter's
/// NativeAssetsManifest.json) and the Android channel call that extracts the
/// libraries for LiteRT.
///
/// Pure Dart on purpose, with no imports at all: `hook/build.dart` imports this
/// file and runs on the plain Dart VM, so nothing here may import Flutter, and
/// the web arm reaches it too (through `litertlm_bundle_info.dart`), so nothing
/// here may import dart:io, dart:ffi or dart:isolate either.
library;

/// A vendor whose NPU this package dispatches to.
///
/// A bundle compiled for an NPU names its vendor in the `LiteRtStamp` its
/// compiler wrote (`npuVendorOf(target)`, internal); which vendor a load runs
/// on is decided by `chooseNpuVendor` (lib/src/ffi/npu_vendor_host.dart), for
/// the LLM engine and the EmbeddingGemma 2 placement alike. LiteRT never checks
/// the stamp against the dispatch it loads, so this choice is the only guard.
///
/// The runtime answers that differ per vendor — the build's stack, the device
/// probe (`npuUnreachable`, one member per probe on `NpuProbes`), the dispatch
/// directory, the HW masking setting, the wording — are `switch`es over this
/// enum with no default, so a vendor added here is a compile error at each of
/// them. NOT forced by the compiler, and needed for a new vendor all the same:
/// its native build (`native/litert_lm/build_*.sh`), its files in
/// `verify_tarball_manifest.sh` REQUIRED, its system libraries as
/// `<uses-native-library>` in the core plugin's AndroidManifest.xml (the
/// probe's dlopen fails in the app's namespace without them), the core version
/// floor in this package's pubspec when core's side changes, the docs, the
/// example's catalog enum (`EmbeddingNpuVendor`), and the load plan's
/// assumption that no stack ships a LiteRT compiler plugin
/// (`_textBackendsAllowed` in `litertlm_load_plan.dart`): a vendor that ships
/// one makes a generic bundle's on-device compile real, and its plugin then
/// belongs in [npuStackLibs].
///
/// Declaration order is the order in which a load whose bundle names no vendor
/// tries the vendors of its ABI; a device is expected to reach at most one.
/// LiteRT's dispatch is process-global: the first NPU load that initializes it
/// fixes the vendor and the dispatch directory for every later NPU load in the
/// process (`IsTheApiInitialized`, litert/runtime/dispatch/litert_dispatch.cc;
/// a failed init fixes nothing). It is per copy of LiteRT: another plugin's
/// `libLiteRt` (flutter_litert) keeps its own.
enum NpuVendor {
  /// Qualcomm Hexagon through QNN, in apps that opt in with
  /// [qualcommNpuUserDefine].
  qualcomm(
    'Qualcomm',
    stampVendor: 'qualcomm',
    abis: {'android_arm64', 'linux_arm64'},
  ),

  /// Google Tensor G5/G6 through the Pixel system's LiteRT Edge TPU runtime,
  /// in apps that opt in with [googleTensorNpuUserDefine]. The dispatch bridge
  /// ships in the Android native tarball and is bundled only then; the
  /// runtime stays on the system image.
  googleTensor('Google Tensor', stampVendor: 'google', abis: {'android_arm64'}),

  /// MediaTek APUs (Dimensity) through NeuroPilot, in apps that opt in with
  /// [mediatekNpuUserDefine]. The dispatch is Google's, from its
  /// `litert-npu-runtime-mediatek` AAR, fetched by the build hook; the
  /// NeuroPilot runtime stays on the device (MediaTek's licence lets it reach
  /// users only inside an app).
  mediatek('MediaTek', stampVendor: 'mediatek', abis: {'android_arm64'}),

  /// Intel NPUs (Lunar Lake, Panther Lake) through OpenVINO, in every Windows
  /// x64 build. Google's `…_Intel_PTL` bundles are stamped `IntelOpenVINO` /
  /// `PTL` (read from the published 270m, 440m and 740m, revisions 9be6e8b9,
  /// e301f74d, 24d962e9); a bare `Intel` is not LiteRT's stamp.
  intel('Intel', stampVendor: 'intelopenvino', abis: {'windows_x64'});

  const NpuVendor(this.label, {required this.stampVendor, required this.abis});

  /// The vendor's name in messages.
  final String label;

  /// The vendor field of the `LiteRtStamp` LiteRT's compiler writes for this
  /// vendor, in lower case.
  final String stampVendor;

  /// The hosts, in `Abi.current()` spelling, where this package runs this
  /// vendor's NPU bundles: the only answer to where a vendor runs, so a host
  /// whose ABI is not here is never asked about this vendor.
  final Set<String> abis;

  /// The vendor of a bundle stamped [vendor] (any case), or null when this
  /// package has no dispatch for it.
  static NpuVendor? forStamp(String vendor) {
    final lower = vendor.toLowerCase();
    for (final candidate in values) {
      if (candidate.stampVendor == lower) return candidate;
    }
    return null;
  }

  /// The vendors whose NPU bundles run on [abi], in declaration order.
  static List<NpuVendor> forAbi(String abi) => [
    for (final vendor in values)
      if (vendor.abis.contains(abi)) vendor,
  ];
}

/// [items] joined for a sentence: `A`, `A and B`, `A, B and C`.
String npuSentenceList(Iterable<String> items) {
  final list = items.toList();
  if (list.length < 2) return list.join();
  return '${list.sublist(0, list.length - 1).join(', ')} and ${list.last}';
}

/// `hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu: true` in the
/// app's pubspec (the workspace root pubspec for a pub-workspace member)
/// bundles the Qualcomm NPU stack into the app's Android arm64 and Linux arm64
/// builds; the hook picks the source per target. Setting it means accepting
/// Qualcomm's licence for the QNN runtime.
const qualcommNpuUserDefine = 'qualcomm_npu';

/// Optional Maven repository to fetch the QNN runtime from instead of Maven
/// Central (a mirror). The pinned checksum is verified either way.
const qualcommNpuMavenUrlUserDefine = 'qualcomm_npu_maven_url';

/// Optional path to a pre-downloaded `qnn-runtime-<version>.aar`, resolved
/// against the pubspec that declares it — for offline or air-gapped builds and
/// for mirrors that need credentials.
const qualcommNpuAarUserDefine = 'qualcomm_npu_aar';

/// Our Qualcomm dispatch library (built from the LiteRT pin, Apache 2.0). It
/// ships in the native tarball and is bundled only with [qualcommNpuUserDefine].
const qualcommDispatchLib = 'LiteRtDispatch_Qualcomm';

/// The user_define that bundles the Google Tensor dispatch bridge into an
/// Android app. Opt-in, as for Qualcomm: the bridge is built from LiteRT's
/// `litert/vendors/google_tensor`, a directory Google's Tensor SDK terms
/// (`TERMS_OF_USE.md` there) cover besides the sources' own licence headers.
const googleTensorNpuUserDefine = 'google_tensor_npu';

/// Our Google Tensor dispatch bridge, built from the LiteRT pin's
/// `litert/vendors/google_tensor/dispatch`. It ships in the Android native
/// tarball and is bundled only with [googleTensorNpuUserDefine]. It
/// late-binds [googleTensorSystemRuntime] from the Pixel system image, which
/// this package never redistributes.
const googleTensorDispatchLib = 'LiteRtDispatch_GoogleTensor';

/// The Pixel system runtime used by [googleTensorDispatchLib].
const googleTensorSystemRuntime = 'libedgetpu_litert.so';

/// The complete app-bundled Google Tensor stack: the bridge only.
const googleTensorNpuLibs = [googleTensorDispatchLib];

/// The user_define that bundles the MediaTek NPU dispatch into an Android
/// app. Opt-in, as for Qualcomm: the dispatch is fetched at build time from
/// Google's `com.google.ai.edge.litert:litert-npu-runtime-mediatek` AAR, and
/// it drives MediaTek's NeuroPilot runtime on the device, which is under
/// MediaTek's licence.
const mediatekNpuUserDefine = 'mediatek_npu';

/// Optional Maven repository to fetch the MediaTek dispatch AAR from instead
/// of Google Maven (a mirror). The pinned checksum is verified either way.
const mediatekNpuMavenUrlUserDefine = 'mediatek_npu_maven_url';

/// Optional path to a pre-downloaded `litert-npu-runtime-mediatek-<version>.aar`,
/// resolved against the pubspec that declares it — for offline builds and for
/// mirrors that need credentials.
const mediatekNpuAarUserDefine = 'mediatek_npu_aar';

/// Google's MediaTek dispatch, from the AAR (Apache 2.0). Not in this
/// package's native tarball: the hook fetches it for [mediatekNpuUserDefine].
const mediatekDispatchLib = 'LiteRtDispatch_MediaTek';

/// The complete app-bundled MediaTek stack: the dispatch only. The AAR's
/// compiler plugin is left out: only bundles compiled ahead of time for a
/// MediaTek SoC run here, never an on-device compile.
const mediatekNpuLibs = [mediatekDispatchLib];

/// The NeuroPilot adapters the MediaTek dispatch opens from the device, in the
/// order it tries them (`neuron_adapter_api.cc` at the LiteRT pin; it keeps
/// the last that opens). The device probe asks for any of them.
const mediatekNeuronAdapters = [
  'libneuron_adapter_mgvi.so',
  'libneuronusdk_adapter.10.mtk.so',
  'libneuronusdk_adapter.9.mtk.so',
  'libneuronusdk_adapter.mtk.so',
  'libneuronusdk_adapter.so',
  'libneuron_adapter.so',
];

/// The device libraries the MediaTek dispatch or NeuroPilot open: the
/// adapters, the utility library the dispatch reads the NeuroPilot version
/// from, and the APU/MVPU set Google's AAR declares (its AndroidManifest.xml
/// at 2.3.0). `libneuronusdk_adapter.10.mtk.so`, which the dispatch tries
/// first and the AAR does not declare, is among the adapters.
const mediatekAndroidSystemLibs = [
  ...mediatekNeuronAdapters,
  'libneuron_sys_util.mtk.so',
  'libapuwareutils_v2.mtk.so',
  'libapuwareutils.mtk.so',
  'libapuwareapusys_v2.mtk.so',
  'libmvpuop_mtk_nn.mtk.so',
  'libmvpuop_mtk_cv.mtk.so',
  'libmvpu_runtime_pub.mtk.so',
  'libmvpu_engine_pub.mtk.so',
  'libmvpu_pattern_pub.mtk.so',
  'libmvpuop25_mtk_nn.mtk.so',
  'libmvpuop25_mtk_cv.mtk.so',
  'libmvpu_runtime_25_pub.mtk.so',
  'libmvpu_engine_25_pub.mtk.so',
  'libmvpu_pattern_25_pub.mtk.so',
  'libmvpu_config.mtk.so',
  'libmvpup30_mtk_nn.mtk.so',
  'libmvpup30_mtk_cv.mtk.so',
  'libmvpu_runtime_30.mtk.so',
  'libmvpu_engine_30.mtk.so',
  'libmvpu_pattern_30.mtk.so',
  'libmvpuop30_mtk_nn.mtk.so',
];

/// Qualcomm's QNN runtime, taken from `com.qualcomm.qti:qnn-runtime` on Maven
/// Central at build time — never shipped in this package's own release.
///
/// The AAR carries 201 MB; this is the subset the dispatch needs for
/// ahead-of-time compiled models on Hexagon V73/V75/V79/V81 (82.8 MiB as
/// published, the Skels carrying non-loaded sections we leave alone). Left
/// out on purpose: libQnnHtpPrepare (on-device compilation only), the GPU and
/// DSP backends, and the V66/V68/V69 pairs no LiteRT-LM model targets.
const qnnRuntimeLibs = [
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
];

/// Every library of the Android Qualcomm NPU stack, as CodeAsset names.
const qualcommNpuLibs = [qualcommDispatchLib, ...qnnRuntimeLibs];

/// Optional path to a pre-downloaded QAIRT SDK zip (`v<qairtBuild>.zip`), for
/// offline Linux arm64 builds. Each library taken from it is checked against
/// the same pinned SHA-256 as a network fetch.
const qualcommNpuQairtZipUserDefine = 'qualcomm_npu_qairt_zip';

/// Our `libcdsprpc.so` (Linux arm64, ours, in the native tarball): an empty
/// library whose only content is `NEEDED libcdsprpc.so.1`.
///
/// Qualcomm's Linux Stubs need the bare name `libcdsprpc.so`, which only a
/// `-dev` package provides; the runtime package installs `libcdsprpc.so.1`.
/// The Stubs carry `RPATH $ORIGIN`, so this one, beside them in the bundle's
/// `lib/`, is what they find, and it hands them the system FastRPC library.
const cdsprpcShimLib = 'cdsprpc';

/// Qualcomm's QNN runtime for Linux arm64, taken at build time from the public
/// QAIRT SDK zip (host libraries from `lib/aarch64-oe-linux-gcc11.2/`, Skels
/// from `lib/hexagon-v*/unsigned/`) — never shipped in this package's release.
///
/// Every Hexagon version the SDK ships a Linux Stub for: V68 (QCS6490), V73
/// (QCS9075), V75 (QCS8275), and V69/V79/V81. libQnnHtpPrepare (on-device
/// compilation) and the DSP-side libQnnHtpV*.so are not needed for the
/// ahead-of-time compiled models LiteRT-LM runs.
const qairtLinuxLibs = [
  'QnnHtp',
  'QnnSystem',
  'QnnHtpV68Stub',
  'QnnHtpV68Skel',
  'QnnHtpV69Stub',
  'QnnHtpV69Skel',
  'QnnHtpV73Stub',
  'QnnHtpV73Skel',
  'QnnHtpV75Stub',
  'QnnHtpV75Skel',
  'QnnHtpV79Stub',
  'QnnHtpV79Skel',
  'QnnHtpV81Stub',
  'QnnHtpV81Skel',
];

/// Every library of the Linux arm64 Qualcomm NPU stack, as CodeAsset names.
const qualcommNpuLibsLinux = [
  qualcommDispatchLib,
  cdsprpcShimLib,
  ...qairtLinuxLibs,
];

/// Intel's NPU stack for Windows x64: our OpenVINO dispatch, the OpenVINO
/// runtime and release TBB (~102 MB; it only enables `PreferredBackend.npu` on
/// LunarLake/PantherLake — a model still loads on CPU/GPU without it). In every
/// Windows x64 build: the hook lists it in `windowsExtraLibs`.
///
/// THIS LIST AND THE WINDOWS WORKFLOW'S `$ovWanted` ARE ONE SET IN TWO PLACES.
/// The tarball is what CI assembles; this is what becomes a CodeAsset and
/// lands next to the app binary. A name present there and absent here
/// extracts to the cache and is never shipped — which is exactly how
/// openvino_intel_npu_compiler(.dll/_loader.dll) went missing at v0.16.0:
/// 78.8 MB of the stack, allow-listed and `throw`-guarded in CI, silently not
/// bundled, so openvino_intel_npu_plugin could not resolve its compiler and
/// backend=npu stayed broken in the release that set out to fix it. Change
/// one, change the other. Release TBB only: the debug variants were once
/// registered into user apps — 1.8 MB of parallel debug builds beside the
/// release set, the mis-binding hazard the workflow's allow-list exists to
/// avoid.
const intelNpuLibs = [
  intelDispatchLib,
  'openvino',
  'openvino_intel_npu_plugin',
  'openvino_intel_npu_compiler',
  'openvino_intel_npu_compiler_loader',
  'openvino_tensorflow_lite_frontend',
  'tbb12',
  'tbbbind_2_5',
  'tbbmalloc',
  'tbbmalloc_proxy',
];

/// Our Intel OpenVINO dispatch (built from the LiteRT pin), `LiteRtDispatch.dll`.
const intelDispatchLib = 'LiteRtDispatch';

/// The user_define that bundles [vendor]'s stack into an app, or null when
/// every build for the vendor's ABIs carries it.
String? npuUserDefine(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => qualcommNpuUserDefine,
  NpuVendor.googleTensor => googleTensorNpuUserDefine,
  NpuVendor.mediatek => mediatekNpuUserDefine,
  NpuVendor.intel => null,
};

/// [vendor]'s dispatch library, as a CodeAsset name: what LiteRT finds in the
/// dispatch directory, and — when [npuDispatchInNativeTarball] — what every
/// native tarball of the vendor's ABIs must carry
/// (`verify_tarball_manifest.sh` REQUIRED).
String npuDispatchLib(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => qualcommDispatchLib,
  NpuVendor.googleTensor => googleTensorDispatchLib,
  NpuVendor.mediatek => mediatekDispatchLib,
  NpuVendor.intel => intelDispatchLib,
};

/// Whether [vendor]'s dispatch ships in this package's native tarball (built
/// from the LiteRT pin), rather than being fetched by the build hook from the
/// vendor's own publication (MediaTek: Google's AAR, whose build needs
/// MediaTek's NeuroPilot SDK, which may not be redistributed on its own).
bool npuDispatchInNativeTarball(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => true,
  NpuVendor.googleTensor => true,
  NpuVendor.mediatek => false,
  NpuVendor.intel => true,
};

/// Every library of [vendor]'s stack on [operatingSystem]
/// (`Platform.operatingSystem` spelling), as CodeAsset names: what
/// NativeAssetsManifest.json lists when the build carries the stack, and what
/// Android hands LiteRT as the dispatch directory.
List<String> npuStackLibs(NpuVendor vendor, String operatingSystem) =>
    switch (vendor) {
      NpuVendor.qualcomm => switch (operatingSystem) {
        'android' => qualcommNpuLibs,
        'linux' => qualcommNpuLibsLinux,
        _ => throw ArgumentError.value(
          operatingSystem,
          'operatingSystem',
          'NpuVendor.qualcomm has no stack here',
        ),
      },
      NpuVendor.googleTensor => switch (operatingSystem) {
        'android' => googleTensorNpuLibs,
        _ => throw ArgumentError.value(
          operatingSystem,
          'operatingSystem',
          'NpuVendor.googleTensor has no stack here',
        ),
      },
      NpuVendor.mediatek => switch (operatingSystem) {
        'android' => mediatekNpuLibs,
        _ => throw ArgumentError.value(
          operatingSystem,
          'operatingSystem',
          'NpuVendor.mediatek has no stack here',
        ),
      },
      NpuVendor.intel => switch (operatingSystem) {
        'windows' => intelNpuLibs,
        _ => throw ArgumentError.value(
          operatingSystem,
          'operatingSystem',
          'NpuVendor.intel has no stack here',
        ),
      },
    };

/// Qualcomm's FastRPC library on Android, from the vendor partition: the
/// device probe opens it, and the stack's Hexagon Stubs load it.
const qualcommAndroidFastRpcLib = 'libcdsprpc.so';

/// The system libraries [vendor]'s NPU stack or its device probe opens on
/// Android, which the core plugin's AndroidManifest.xml must declare as
/// `<uses-native-library>`: without the declaration the dlopen fails in the
/// app's linker namespace — the probe's, or the dispatch's at engine_create.
/// A dispatch that opens a vendor runtime lists all of it (MediaTek's Neuron
/// adapters, Tensor's `libedgetpu_litert.so`), not only what the probe opens.
List<String> npuAndroidSystemLibs(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => const [qualcommAndroidFastRpcLib],
  NpuVendor.googleTensor => const [googleTensorSystemRuntime],
  NpuVendor.mediatek => mediatekAndroidSystemLibs,
  NpuVendor.intel => const [],
};

/// The asset id the build hook registers [name] under — the key Flutter
/// writes into NativeAssetsManifest.json.
String nativeAssetId(String name) =>
    'package:flutter_edge_ai_litertlm/src/native/$name';

/// The file name [name] gets on Android and Linux (`lib<name>.so`).
String androidLibFileName(String name) => 'lib$name.so';
