// How an FFI `openSession` session holds its context (core 2.6.0 design §1.1):
// a native conversation of its own, or a virtual one replayed as text into a
// shared conversation. Internal to this package; the switch is no API.

import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;

import '../npu_stacks.dart';

/// How each `openSession` session of a loaded model holds its context.
enum OpenSessionBacking {
  /// One native conversation per session, beside the others on the engine
  /// (LiteRT-LM 0.19 lifts upstream #966). Images and audio are taken, and a
  /// stopped turn is rewound (§16) where the backend can.
  native,

  /// History kept in Dart and replayed as text into one shared conversation
  /// at every switch between sessions, as on LiteRT-LM 0.18. Images and audio
  /// are refused: a text replay cannot carry them.
  virtual,
}

/// The Android GPU families whose drivers this package tells apart, by the
/// device node the driver exposes.
enum AndroidGpuFamily { adreno, mali, other }

/// The GPU family of an Android device whose device nodes [exists] reports:
/// `/dev/kgsl-3d0` Adreno, `/dev/mali0` Mali, anything else (and a node the
/// app may not stat, which reads as absent) [AndroidGpuFamily.other].
AndroidGpuFamily androidGpuFamilyFrom(bool Function(String path) exists) {
  if (exists('/dev/kgsl-3d0')) return AndroidGpuFamily.adreno;
  if (exists('/dev/mali0')) return AndroidGpuFamily.mali;
  return AndroidGpuFamily.other;
}

/// The hosts whose CPU ran several live conversations on one engine, each
/// keeping its own history (the `multiconv` probe, 3/3, on native-v0.19.0-a's
/// patch set): macOS arm64 (M5 Pro), Linux x86_64, Linux arm64 and Windows
/// x86_64 (phase 1, "Probes"; Linux x86_64 and Windows again on the T4 VM and
/// intel-ptl, L1 paid runs). Not run: Android CPU on a phone, iOS.
const liteRtLmConversationsCpuAbis = {
  'macos_arm64',
  'linux_x64',
  'linux_arm64',
  'windows_x64',
};

/// The hosts whose GPU ran them: Metal on macOS, Vulkan on a Tesla T4 (Linux
/// x86_64) and D3D12 on Arc B390 and Arc 140V (Windows x86_64), all with §20
/// on the desktop. Android is decided per GPU family
/// ([liteRtLmConversationsAndroidGpus]). Not run: iOS Metal, Linux arm64.
const liteRtLmConversationsGpuAbis = {
  'macos_arm64',
  'linux_x64',
  'windows_x64',
};

/// The Android GPU families that ran them: Adreno 830 (Galaxy S25 Ultra) and
/// Mali-G715 (Pixel 8a), every probe command on Gemma 4 E2B (L1 paid runs,
/// 2026-11-04). A third family failed: on the Pixel 11's PowerVR GPU two
/// greedy conversations diverged, so every other family stays virtual.
const liteRtLmConversationsAndroidGpus = {
  AndroidGpuFamily.adreno,
  AndroidGpuFamily.mali,
};

/// The NPU stacks that ran them, each on the ABI it was run on, with §22
/// (every KV buffer saved at a switch): Qualcomm SM8750 and Google Tensor G6
/// on Android, Intel Panther Lake and Lunar Lake on Windows (npu-0.19 runs N2
/// and N2b; L1 paid runs, `multiconv` and `ctxgroup` at 1104 tokens).
/// Qualcomm on Linux arm64 was not run. MediaTek is refused at load.
const liteRtLmConversationsNpus = {
  (NpuStack.qualcomm, 'android_arm64'),
  (NpuStack.googleTensor, 'android_arm64'),
  (NpuStack.intel, 'windows_x64'),
};

/// How the open sessions of a model loaded on [backend] on the host [abi]
/// are backed: [OpenSessionBacking.native] only where that backend ran
/// several live conversations correctly, [OpenSessionBacking.virtual]
/// everywhere else. [npuVendor] is the stack an NPU load runs on;
/// [androidGpu] the GPU family of an Android device, null when not read.
OpenSessionBacking liteRtLmOpenSessionBacking({
  required String abi,
  required PreferredBackend? backend,
  NpuStack? npuVendor,
  AndroidGpuFamily? androidGpu,
}) {
  final verified = switch (backend) {
    PreferredBackend.cpu => liteRtLmConversationsCpuAbis.contains(abi),
    PreferredBackend.gpu =>
      abi == 'android_arm64'
          ? liteRtLmConversationsAndroidGpus.contains(androidGpu)
          : liteRtLmConversationsGpuAbis.contains(abi),
    PreferredBackend.npu =>
      npuVendor != null && liteRtLmConversationsNpus.contains((npuVendor, abi)),
    null => false,
  };
  return verified ? OpenSessionBacking.native : OpenSessionBacking.virtual;
}
