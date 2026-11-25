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
// The page hands over the whole module (`window.litertLm`,
// web_module_shim.dart), and the enum is read from it as
// `window.litertLm.Backend`; a module without it, or whose value is not that
// enum, is refused by name, never driven with guessed ids. Pure Dart, so the
// rules are tested on the VM; litert_lm_js.dart reads the global.
library;

import 'web_embedder.dart' show LiteRtLmWebBackend;
import 'web_module_shim.dart';
import 'web_runtime_version.dart';

/// The names of the `Backend` entries this release sends or reads back.
const _cpu = 'CPU';
const _gpu = 'GPU';
const _gpuArtisan = 'GPU_ARTISAN';

/// Why the page module's `Backend` (`window.litertLm.Backend`) cannot be
/// used: missing, not an object, or without an integer `CPU`, `GPU` or
/// `GPU_ARTISAN` (or with two of them equal). Its message names the runtime
/// to import.
final class LiteRtLmWebBackendEnumError extends LiteRtLmWebModuleError {
  LiteRtLmWebBackendEnumError(super.message);
}

/// `@litert-lm/core`'s `Backend` as the page's module exports it.
final class LiteRtLmWebBackendIds {
  LiteRtLmWebBackendIds._(this.entries)
    : cpu = entries[_cpu]!,
      gpu = entries[_gpu]!,
      gpuArtisan = entries[_gpuArtisan]!;

  /// Reads [backendEnum]: the entries of `window.litertLm.Backend` (name →
  /// value, a JS number as a Dart [num], anything else as the `typeof` of the
  /// value, a [String]), a [String] naming what the member is when it is not
  /// an object, or null when the module has none. Throws
  /// [LiteRtLmWebBackendEnumError].
  factory LiteRtLmWebBackendIds.parse(Object? backendEnum) {
    if (backendEnum == null) {
      throw LiteRtLmWebBackendEnumError(
        liteRtLmWebModuleMemberMessage('Backend', 'a value of type undefined'),
      );
    }
    if (backendEnum is! Map<String, Object?>) {
      throw LiteRtLmWebBackendEnumError(
        'window.litertLm.Backend is $backendEnum, not @litert-lm/core\'s '
        'Backend enum: the page\'s @litert-lm/core is not one this release '
        'calls. Import $liteRtLmWebModuleUrl in its module script.',
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
        'window.litertLm.Backend is not @litert-lm/core\'s Backend enum: '
        '${problems.join('; ')}. The page\'s @litert-lm/core is not one this '
        'release calls: import $liteRtLmWebModuleUrl in its module script.',
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
  /// GPU export asked for the GPU (0.18.0 and 0.19.0, measured 2026-11-23;
  /// 0.20.0, 2026-11-25):
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
