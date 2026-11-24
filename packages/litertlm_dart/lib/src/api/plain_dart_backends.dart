// The backends a plain Dart program (`dart run`, `dart test`, `dart build
// cli`) runs LiteRT-LM on in this release: the CPU only. The GPU and the NPU
// are refused by name, before anything loads, never moved to the CPU: the
// library lookup of a plain Dart program is new, and their accelerator and
// dispatch libraries are not looked up there yet.
//
// Package-private.

import 'backend.dart';

/// Why [backend], asked for [what] (`'The engine'`, `'The vision encoder'`,
/// ...), does not run in a plain Dart program; null for the CPU and for no
/// backend.
String? plainDartBackendRefusal(String what, Backend? backend) {
  final name = switch (backend) {
    null || CpuBackend() => null,
    GpuBackend() => 'Backend.gpu()',
    NpuBackend() => 'Backend.npu()',
  };
  if (name == null) return null;
  return 'litertlm_dart: $what on $name is not supported outside Flutter '
      'yet. In a plain Dart program (dart run, dart test, dart build cli) '
      'this release runs LiteRT-LM on the CPU only: pass Backend.cpu().';
}
