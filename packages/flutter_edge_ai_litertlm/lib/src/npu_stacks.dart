/// The opt-in vendor NPU stacks, named once for the three places that must
/// agree on them: the build hook (what gets bundled), the runtime gate (what
/// this build bundled, read back from Flutter's NativeAssetsManifest.json) and
/// the Android channel call that extracts the libraries for LiteRT.
///
/// Pure Dart on purpose: `hook/build.dart` imports this file and runs on the
/// plain Dart VM, so nothing here may import Flutter.
library;

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

/// The Qualcomm NPU stack of [operatingSystem] (`Platform.operatingSystem`
/// spelling), or empty where none exists.
List<String> qualcommNpuLibsFor(String operatingSystem) =>
    switch (operatingSystem) {
      'android' => qualcommNpuLibs,
      'linux' => qualcommNpuLibsLinux,
      _ => const [],
    };

/// The asset id the build hook registers [name] under — the key Flutter
/// writes into NativeAssetsManifest.json.
String nativeAssetId(String name) =>
    'package:flutter_edge_ai_litertlm/src/native/$name';

/// The file name [name] gets on Android and Linux (`lib<name>.so`).
String androidLibFileName(String name) => 'lib$name.so';
