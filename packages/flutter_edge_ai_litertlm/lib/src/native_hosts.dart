/// The hosts this package runs on natively, and where EmbeddingGemma 2 runs
/// on the GPU, named once for the places that must agree on them: the
/// loader and the model catalog's `backendsHere` import it; the build hook
/// does not, and test/native_hosts_test.dart holds its archive table equal
/// to [liteRtLmNativeAbis] by reading the hook's text.
///
/// Pure Dart with no imports at all, like npu_stacks.dart: the catalog
/// reaches it from the web graph.
library;

/// The hosts, in `Abi.current()` spelling, the native archive is published
/// for (`hook/build.dart`, one `litertlm-<host>.tar.gz` each; the iOS
/// simulator's `ios_sim_arm64` archive reports `ios_arm64`). Anywhere else
/// the app builds without `libLiteRtLm`, and nothing of this package loads.
const liteRtLmNativeAbis = {
  'android_arm64',
  'ios_arm64',
  'macos_arm64',
  'linux_x64',
  'linux_arm64',
  'windows_x64',
};

/// The hosts, in `Abi.current()` spelling, where a generic EmbeddingGemma 2
/// bundle runs on the GPU when `preferredBackend: gpu` asks for it: LiteRT-LM's
/// GPU executor, over the WebGPU accelerator these archives ship on Linux and
/// Windows and the Metal accelerator linked into libLiteRtLm on macOS.
///
/// - Linux x64, measured 2026-10-22 on the 270m, ten golden texts, on a Tesla
///   T4 (Vulkan): 32-64 ms per embedding vs 232-308 ms on its CPU; min cos
///   0.997 to the CPU vectors, and to Sentence Transformers fp32
///   0.9765-0.9767 vs 0.9763 on CPU. The adapter is Dawn's choice: with no
///   GPU driver loaded, Linux ran it on Mesa's llvmpipe (software Vulkan),
///   reported as gpu, 37-48 s per load, and a ~900-token text failed there
///   with DEADLINE_EXCEEDED.
/// - Windows x64, since LiteRT-LM 0.19 (native-v0.19.0-a): the 270m on the
///   GPU on Panther Lake (Arc B390) and Lunar Lake (Arc 140V), 2026-11-04, C
///   probe over the shipped archive. native-v0.18.0-h ended the process at
///   that load (#744), so it was refused there.
/// - macOS arm64, since LiteRT-LM 0.19: the 270m and 740m text towers on
///   Metal, 24 ms per embedding, ML Drift caches written (C probe,
///   2026-11-04), and the pass on Metal through this package (L2). 0.18's
///   Metal path ended the process with a SIGBUS in LiteRT's external weight
///   loader (`PrepareAccessForBuffer`) at engine create.
///
/// Only the text tower runs on the GPU: on the 440m and 740m the pass names
/// their vision and audio towers cpu (`readLiteRtLmMediaTowers`), not yet
/// measured on these hosts, and neither are the 440m and 740m text towers on
/// the Windows GPU. The GPU runs FP16 activations by default. iOS, which
/// links the same Metal accelerator, Android's OpenCL accelerator and Linux
/// arm64 are not measured. Elsewhere a `gpu` request runs on CPU, with core's
/// not-applied notice, as before.
const liteRtLmEmbeddingGpuAbis = {'linux_x64', 'windows_x64', 'macos_arm64'};

/// The generic EmbeddingGemma 2 bundles, told apart by the towers their
/// container carries (`readLiteRtLmMediaTowers`).
enum LiteRtLmEg2Bundle {
  /// embeddinggemma-2-text-270m: text only.
  text270m('the 270m'),

  /// embeddinggemma-2-text-vision-440m: text and vision.
  textVision440m('the 440m'),

  /// embeddinggemma-2-740m: text, vision and audio.
  textVisionAudio740m('the 740m');

  const LiteRtLmEg2Bundle(this.label);

  final String label;

  /// The bundle with [vision] and [audio] towers.
  static LiteRtLmEg2Bundle of({required bool vision, required bool audio}) =>
      audio ? textVisionAudio740m : (vision ? textVision440m : text270m);
}

/// Which generic EmbeddingGemma 2 bundles have run with their text tower on
/// the GPU of each [liteRtLmEmbeddingGpuAbis] host; a `gpu` request for any
/// other is refused there, naming the missing run. Linux x64: all three since
/// litertlm 1.19.0 (measured on the 270m; the others run the same text tower
/// with their media towers on CPU). Windows x64: the 270m on Panther Lake and
/// Lunar Lake (L1, 2026-11-04). macOS: the 270m and the 740m text towers on
/// Metal (L1 C probe; the 270m and 740m through this pass, L2).
const liteRtLmEmbeddingGpuMeasured = <String, Set<LiteRtLmEg2Bundle>>{
  'linux_x64': {
    LiteRtLmEg2Bundle.text270m,
    LiteRtLmEg2Bundle.textVision440m,
    LiteRtLmEg2Bundle.textVisionAudio740m,
  },
  'windows_x64': {LiteRtLmEg2Bundle.text270m},
  'macos_arm64': {
    LiteRtLmEg2Bundle.text270m,
    LiteRtLmEg2Bundle.textVisionAudio740m,
  },
};

/// The hosts where `preferredBackend: gpu` for a generic EmbeddingGemma 2
/// bundle is refused with an `EmbeddingLoadException`
/// (`liteRtLmEmbeddingGpuRefusal`) instead of running anywhere: a host whose
/// GPU path ends the process, which no Dart code can catch, so the request is
/// refused rather than run on the CPU (the app asked for the GPU). None on
/// native-v0.19.0-a: Windows x64 was here on native-v0.18.0-h (#744, an
/// access violation in `webgpu_dawn.dll` at the first EmbeddingGemma 2 GPU
/// load) and runs on 0.19 ([liteRtLmEmbeddingGpuAbis]).
const liteRtLmEmbeddingGpuRefusedAbis = <String>{};
