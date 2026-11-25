// The `Backend` ids of the page's `@litert-lm/core`, read from the enum the
// module itself exports (`m.Backend`, `wasm_binding_types.js`) instead of
// numbers written here: 0.20.0 renumbered it (`88a271c3` removed
// CPU_ARTISAN), so the same number is another backend on another version.
//
//   0.19.0: UNSPECIFIED 0, CPU_ARTISAN 1, GPU_ARTISAN 2, CPU 3, GPU 4,
//           GOOGLE_TENSOR_ARTISAN 5, NPU 6
//   0.20.0: UNSPECIFIED 0, GPU_ARTISAN 1, CPU 2, GPU 3,
//           GOOGLE_TENSOR_ARTISAN 4, NPU 5
//
// The page hands the enum over with one line of its module script
// ([liteRtLmWebBackendShimLine]); a page without it, or whose value is not
// that enum, is refused by name, never driven with guessed ids. Pure Dart,
// so the rules are tested on the VM; litert_lm_js.dart reads the global.
library;

import 'web_embedder.dart' show LiteRtLmWebBackend;

/// The `index.html` line that hands this release `@litert-lm/core`'s
/// `Backend` enum, word for word.
const liteRtLmWebBackendShimLine = 'window.LiteRtLmBackend = m.Backend;';

/// The names of the `Backend` entries this release sends or reads back.
const _cpu = 'CPU';
const _gpu = 'GPU';
const _gpuArtisan = 'GPU_ARTISAN';

/// Why the page's `window.LiteRtLmBackend` cannot be used: missing, not an
/// object, or without an integer `CPU`, `GPU` or `GPU_ARTISAN` (or with two
/// of them equal). Its message names the line the page's module script
/// needs. A [StateError], as every other refusal of a page that does not
/// load the runtime this release calls.
final class LiteRtLmWebBackendEnumError extends StateError {
  LiteRtLmWebBackendEnumError(super.message);
}

/// `@litert-lm/core`'s `Backend` as the page's module exports it.
final class LiteRtLmWebBackendIds {
  LiteRtLmWebBackendIds._(this.entries)
    : cpu = entries[_cpu]!,
      gpu = entries[_gpu]!,
      gpuArtisan = entries[_gpuArtisan]!;

  /// Reads [backendEnum]: the entries of `window.LiteRtLmBackend` (name →
  /// value, a JS number as a Dart [num], anything else as the `typeof` of the
  /// value, a [String]), a [String] naming what the global is when it is not
  /// an object, or null when it is not set. Throws
  /// [LiteRtLmWebBackendEnumError].
  factory LiteRtLmWebBackendIds.parse(Object? backendEnum) {
    if (backendEnum == null) {
      throw LiteRtLmWebBackendEnumError(
        'window.LiteRtLmBackend is not set: the page\'s module script must '
        'hand this release @litert-lm/core\'s Backend enum. Add '
        '$liteRtLmWebBackendShimLine next to window.Engine = m.Engine; '
        '(litertlm_dart\'s README, "On the web").',
      );
    }
    if (backendEnum is! Map<String, Object?>) {
      throw LiteRtLmWebBackendEnumError(
        'window.LiteRtLmBackend is $backendEnum, not @litert-lm/core\'s '
        'Backend enum: set it with $liteRtLmWebBackendShimLine in the page\'s '
        'module script (litertlm_dart\'s README, "On the web").',
      );
    }
    final entries = <String, int>{
      for (final MapEntry(:key, :value) in backendEnum.entries)
        if (value is num && value.isFinite && value == value.truncate())
          key: value.toInt(),
    };
    final problems = [
      for (final name in const [_cpu, _gpu, _gpuArtisan])
        if (!backendEnum.containsKey(name))
          'it has no $name'
        else if (!entries.containsKey(name))
          'its $name is ${_describe(backendEnum[name])}, not an integer',
    ];
    if (problems.isEmpty) {
      final ids = [entries[_cpu], entries[_gpu], entries[_gpuArtisan]];
      if (ids.toSet().length != ids.length) {
        problems.add(
          'its CPU (${entries[_cpu]}), GPU (${entries[_gpu]}) and '
          'GPU_ARTISAN (${entries[_gpuArtisan]}) are not three ids',
        );
      }
    }
    if (problems.isNotEmpty) {
      throw LiteRtLmWebBackendEnumError(
        'window.LiteRtLmBackend is not @litert-lm/core\'s Backend enum: '
        '${problems.join('; ')}. Set it with $liteRtLmWebBackendShimLine in '
        'the page\'s module script (litertlm_dart\'s README, "On the web").',
      );
    }
    return LiteRtLmWebBackendIds._(Map.unmodifiable(entries));
  }

  /// Every integer entry of the page's enum, by name.
  final Map<String, int> entries;

  /// `Backend.CPU`: WebAssembly (XNNPack).
  final int cpu;

  /// `Backend.GPU`: WebGPU.
  final int gpu;

  /// `Backend.GPU_ARTISAN`: what the runtime reports for a Gemma 4 web or
  /// GPU export asked for the GPU (0.18.0 and 0.19.0, measured 2026-11-23):
  /// the same WebGPU, through the runtime's legacy executor.
  final int gpuArtisan;

  /// The id this release sends for [backend].
  int idOf(LiteRtLmWebBackend backend) => switch (backend) {
    LiteRtLmWebBackend.cpu => cpu,
    LiteRtLmWebBackend.gpu => gpu,
  };

  /// Where an engine the runtime resolved to [id] runs: WebAssembly for
  /// `CPU`, WebGPU for `GPU` and `GPU_ARTISAN`; null for any other id.
  LiteRtLmWebBackend? backendOf(int id) => id == cpu
      ? LiteRtLmWebBackend.cpu
      : (id == gpu || id == gpuArtisan)
      ? LiteRtLmWebBackend.gpu
      : null;

  /// What the page's enum calls [id], for the refusal of an id
  /// [backendOf] does not know: `NPU in the page's Backend`, or that the
  /// enum has no such id, with its entries.
  String nameOf(int id) {
    final names = [
      for (final MapEntry(:key, :value) in entries.entries)
        if (value == id) key,
    ];
    if (names.isNotEmpty) return '${names.join(' / ')} in the page\'s Backend';
    final all = [
      for (final MapEntry(:key, :value) in entries.entries) '$key $value',
    ];
    return 'not in the page\'s Backend (${all.join(', ')})';
  }

  static String _describe(Object? value) => switch (value) {
    null => 'null',
    'undefined' => 'undefined',
    final String typeOf => 'a value of type $typeOf',
    final num number => '$number',
    _ => '${value.runtimeType}',
  };
}
