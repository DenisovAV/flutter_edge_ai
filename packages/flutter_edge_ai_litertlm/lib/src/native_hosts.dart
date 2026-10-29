/// The hosts this package runs on natively, and where EmbeddingGemma 2 runs
/// on the GPU, named once for the places that must agree on them: the
/// loader, the model catalog's `backendsHere` and the build hook's archive
/// table (held equal by test/native_hosts_test.dart).
///
/// Pure Dart with no imports at all, like npu_stacks.dart: the catalog
/// reaches it from the web graph, and the hook from the plain Dart VM.
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
/// GPU executor over the WebGPU accelerator these archives ship. Linux x64
/// only: Windows x64 is refused on native-v0.18.0-h
/// ([liteRtLmEmbeddingGpuRefusedAbis]). Measured 2026-10-22 on the 270m, ten
/// golden texts: Linux x64 on a Tesla T4 (Vulkan) 32-64 ms per embedding vs
/// 232-308 ms on its CPU; min cos 0.997 to the CPU vectors, and to Sentence
/// Transformers fp32 0.9765-0.9767 vs 0.9763 on CPU (Windows x64 on Lunar
/// Lake measured the same way on native-v0.18.0-g: 22 ms vs 83-90 ms).
/// The adapter is Dawn's choice: with no GPU driver loaded, Linux ran it on
/// Mesa's llvmpipe (software Vulkan), reported as gpu, 37-48 s per load, and
/// a ~900-token text failed there with DEADLINE_EXCEEDED.
/// Only the text tower runs on the GPU: on the 440m and 740m the pass names
/// their vision and audio towers cpu (`readLiteRtLmMediaTowers`), which is
/// not yet measured on these hosts. The GPU runs FP16 activations by
/// default. macOS and iOS are not here: their
/// Metal accelerator ends the process with a SIGBUS in LiteRT's external
/// weight loader (`PrepareAccessForBuffer`) at engine create (measured on
/// macOS), which no Dart code can catch. Android's OpenCL accelerator and
/// Linux arm64 are not measured. Elsewhere a `gpu` request runs on CPU, with
/// core's not-applied notice, as before.
const liteRtLmEmbeddingGpuAbis = {'linux_x64'};

/// The hosts where `preferredBackend: gpu` for a generic EmbeddingGemma 2
/// bundle is refused with an `EmbeddingLoadException`
/// (`liteRtLmEmbeddingGpuRefusal`) instead of running anywhere: Windows x64,
/// where LiteRT-LM's WebGPU accelerator in native-v0.18.0-h (Google's prebuilt
/// from LiteRT-LM 5f973f57) ends the process with an access violation in
/// `webgpu_dawn.dll` at the first EmbeddingGemma 2 GPU load (reproduced on an
/// Intel Panther Lake PC with the 270m, 440m and 740m; the same build with
/// native-v0.18.0-g's Windows archive passes). A crash no Dart code can catch,
/// so the request is refused; it is not run on CPU instead either, because
/// the app asked for the GPU.
const liteRtLmEmbeddingGpuRefusedAbis = {'windows_x64'};
