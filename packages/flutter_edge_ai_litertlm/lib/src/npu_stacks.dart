/// The opt-in vendor NPU stacks, named once for the three places that must
/// agree on them: the build hook (what gets bundled), the runtime gate (what
/// this build bundled, read back from Flutter's NativeAssetsManifest.json) and
/// the Android channel call that extracts the libraries for LiteRT.
///
/// Pure Dart on purpose: `hook/build.dart` imports this file and runs on the
/// plain Dart VM, so nothing here may import Flutter.
library;

/// A vendor whose NPU this package dispatches to.
///
/// A bundle compiled for an NPU names its vendor in the `LiteRtStamp` its
/// compiler wrote (`LiteRtLmNpuTarget.npuVendor`); a load without one uses the
/// vendor this device reaches. Every answer that differs per vendor — the
/// build's stack, the device probe, the dispatch directory, the wording — is a
/// `switch` over this enum with no default, so a vendor added here is a compile
/// error at each place that still needs its answer.
enum NpuVendor {
  /// Qualcomm Hexagon through QNN, in apps that opt in with
  /// [qualcommNpuUserDefine].
  qualcomm(
    'Qualcomm',
    stampVendor: 'qualcomm',
    abis: {'android_arm64', 'linux_arm64'},
  ),

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
  /// vendor's NPU bundles.
  final Set<String> abis;

  /// Whether this vendor's NPU runs on [operatingSystem]
  /// (`Platform.operatingSystem` spelling) on any of its [abis].
  bool runsOn(String operatingSystem) =>
      abis.any((abi) => abi.startsWith('${operatingSystem}_'));

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
