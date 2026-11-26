// Where a model runs: LiteRT-LM's Kotlin `Backend` (CPU with a thread count,
// GPU, NPU), as one sealed type.

import 'package:meta/meta.dart' show immutable;

import '../runtime/npu_platform.dart' show NpuPlatform;
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

  /// The NPU of the vendor the bundle is compiled for: Kotlin's
  /// `Backend.NPU(nativeLibraryDir)`. [dispatchDir] is a directory holding
  /// that vendor's dispatch libraries, and only that vendor's (LiteRT loads
  /// the first dispatch it finds there); null looks where the build puts
  /// them on Linux and Windows: beside an app's executable, among a plain
  /// Dart program's code assets.
  ///
  /// On Android the libraries are inside the APK: an app's
  /// `nativeLibraryDir` holds them only with `extractNativeLibs="true"`, and
  /// then holds every vendor the app ships. An app copies one vendor's
  /// libraries out of the APK into a directory of their own and passes it
  /// here.
  const factory Backend.npu({String? dispatchDir}) = NpuBackend;
}

/// The runtime's name for [backend].
BackendKind backendKindOf(Backend backend) => switch (backend) {
  CpuBackend() => BackendKind.cpu,
  GpuBackend() => BackendKind.gpu,
  NpuBackend() => BackendKind.npu,
};

/// [Backend.cpu].
final class CpuBackend extends Backend {
  const CpuBackend({this.threadCount}) : super._();

  /// Threads of the CPU executor; null is LiteRT-LM's default. A count below
  /// 1 is an [ArgumentError] when an engine is created with it.
  final int? threadCount;

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
  bool operator ==(Object other) => other is GpuBackend;

  @override
  int get hashCode => (GpuBackend).hashCode;

  @override
  String toString() => 'Backend.gpu()';
}

/// [Backend.npu].
final class NpuBackend extends Backend {
  const NpuBackend({this.dispatchDir}) : _platform = null, super._();

  const NpuBackend._on(NpuPlatform platform)
    : _platform = platform,
      dispatchDir = null,
      super._();

  final NpuPlatform? _platform;

  /// A directory already holding the vendor's dispatch libraries.
  final String? dispatchDir;

  @override
  bool operator ==(Object other) =>
      other is NpuBackend &&
      identical(other._platform, _platform) &&
      other.dispatchDir == dispatchDir;

  @override
  int get hashCode => Object.hash(NpuBackend, _platform, dispatchDir);

  @override
  String toString() => 'Backend.npu()';
}

/// The backend of [kind], with no thread count or platform.
Backend backendOf(BackendKind kind, {NpuPlatform? platform}) => switch (kind) {
  BackendKind.cpu => const Backend.cpu(),
  BackendKind.gpu => const Backend.gpu(),
  BackendKind.npu =>
    platform == null ? const NpuBackend() : npuBackendOn(platform),
};

/// The NPU, with [platform] answering what plain Dart cannot: the build's
/// `NativeAssetsManifest.json`, and on Android a directory prepared with the
/// dispatch libraries of the vendor the bundle names. A package built on this
/// one passes its own implementation.
NpuBackend npuBackendOn(NpuPlatform platform) => NpuBackend._on(platform);

/// [backend]'s platform layer ([npuBackendOn]); null for any other backend.
NpuPlatform? npuPlatformOf(Backend? backend) =>
    backend is NpuBackend ? backend._platform : null;

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

/// LiteRT-LM's speculative decoding (MTP) settings: Kotlin's and Swift's
/// `SpeculativeDecodingConfig`, except that [mode] is required here, where
/// upstream's is nullable (inherited from the engine).
///
/// Any [lenience] above 0 gives up speculative decoding's quality guarantee
/// (upstream's warning): at 0 it is lossless, the tokens follow the model's
/// own sampling distribution; above 0 a drafted token that differs from the
/// verifier's sample is still accepted with that probability, so the reply
/// can differ from what the model itself would write. Set it only where
/// lower quality is an acceptable price for speed.
@immutable
final class SpeculativeDecodingConfig {
  /// [lenience] must be in [0, 1]; null leaves LiteRT-LM's (the engine's, 0
  /// by default). An [ArgumentError] otherwise.
  SpeculativeDecodingConfig({required this.mode, this.lenience}) {
    final l = lenience;
    if (l != null && !(l >= 0 && l <= 1)) {
      throw ArgumentError.value(l, 'lenience', 'must be in [0, 1]');
    }
  }

  /// Whether and how to speculate.
  final SpeculativeDecodingMode mode;

  /// How far a drafted token may stray from what the model would choose and
  /// still be accepted, in [0, 1]: 0 accepts only exact matches. The NPU
  /// executor stays exact whatever is set (LiteRT-LM logs a warning).
  final double? lenience;

  @override
  bool operator ==(Object other) =>
      other is SpeculativeDecodingConfig &&
      other.mode == mode &&
      other.lenience == lenience;

  @override
  int get hashCode => Object.hash(mode, lenience);

  @override
  String toString() =>
      'SpeculativeDecodingConfig(mode: ${mode.name}'
      '${lenience == null ? '' : ', lenience: $lenience'})';
}
