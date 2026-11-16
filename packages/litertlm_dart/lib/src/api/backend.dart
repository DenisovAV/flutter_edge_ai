// Where a model runs: LiteRT-LM's Kotlin `Backend` (CPU with a thread count,
// GPU, NPU), as one sealed type.

import 'package:meta/meta.dart' show immutable;

import '../ffi/npu_vendor_host.dart' show NpuPlatform;
import '../runtime/types.dart' show BackendKind;

/// The executor a model, or one of its encoders, runs on.
///
/// The NPU is one backend: which vendor's NPU (Qualcomm, Google Tensor,
/// MediaTek, Intel) is read from the bundle's own `LiteRtStamp`, so there is
/// no per-vendor backend.
@immutable
sealed class Backend {
  const Backend._();

  /// The CPU. [threadCount] is the number of threads LiteRT-LM's CPU executor
  /// uses; null leaves LiteRT-LM's default.
  const factory Backend.cpu({int? threadCount}) = CpuBackend;

  /// The GPU: OpenCL on Android, Metal on Apple, WebGPU over Vulkan on Linux
  /// and over Direct3D 12 on Windows.
  const factory Backend.gpu() = GpuBackend;

  /// The NPU of the vendor the bundle is compiled for. [platform] answers
  /// what plain Dart cannot: the build's `NativeAssetsManifest.json`, and on
  /// Android a directory holding the vendor's dispatch libraries. Null works
  /// where the dispatch sits beside the executable (Linux, Windows). A
  /// [dispatchDir] already prepared (Kotlin's `nativeLibraryDir`) is used as
  /// it is, and [platform] is then not asked for one.
  const factory Backend.npu({NpuPlatform? platform, String? dispatchDir}) =
      NpuBackend;

  /// The runtime's name for this backend.
  BackendKind get kind;
}

/// [Backend.cpu].
final class CpuBackend extends Backend {
  const CpuBackend({this.threadCount})
    : assert(threadCount == null || threadCount > 0),
      super._();

  /// Threads of the CPU executor; null is LiteRT-LM's default.
  final int? threadCount;

  @override
  BackendKind get kind => BackendKind.cpu;

  @override
  bool operator ==(Object other) =>
      other is CpuBackend && other.threadCount == threadCount;

  @override
  int get hashCode => Object.hash(CpuBackend, threadCount);

  @override
  String toString() =>
      threadCount == null ? 'Backend.cpu()' : 'Backend.cpu($threadCount)';
}

/// [Backend.gpu].
final class GpuBackend extends Backend {
  const GpuBackend() : super._();

  @override
  BackendKind get kind => BackendKind.gpu;

  @override
  bool operator ==(Object other) => other is GpuBackend;

  @override
  int get hashCode => (GpuBackend).hashCode;

  @override
  String toString() => 'Backend.gpu()';
}

/// [Backend.npu].
final class NpuBackend extends Backend {
  const NpuBackend({this.platform, this.dispatchDir}) : super._();

  /// The app's platform layer; see [Backend.npu].
  final NpuPlatform? platform;

  /// A directory already holding the vendor's dispatch libraries.
  final String? dispatchDir;

  @override
  BackendKind get kind => BackendKind.npu;

  @override
  bool operator ==(Object other) =>
      other is NpuBackend &&
      identical(other.platform, platform) &&
      other.dispatchDir == dispatchDir;

  @override
  int get hashCode => Object.hash(NpuBackend, platform, dispatchDir);

  @override
  String toString() => 'Backend.npu()';
}

/// The backend of [kind], with no thread count or platform.
Backend backendOf(BackendKind kind, {NpuPlatform? platform}) => switch (kind) {
  BackendKind.cpu => const Backend.cpu(),
  BackendKind.gpu => const Backend.gpu(),
  BackendKind.npu => Backend.npu(platform: platform),
};

/// How LiteRT-LM's speculative decoding (MTP) is used: the values of its
/// `--speculative_decoding` flag and of `LiteRtLmSpeculativeDecodingMode`.
enum SpeculativeDecodingMode {
  /// Never speculate.
  off,

  /// Speculate on every decode step.
  on,

  /// Speculate only while it is measured to be faster than plain decoding;
  /// backends that cannot adapt speculate on every step.
  adaptive,
}
