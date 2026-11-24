// The backends a plain Dart program (`dart run`, `dart test`, `dart build
// cli`) runs LiteRT-LM on in this release: the CPU only. The GPU and the NPU
// are refused by name, before anything loads, never moved to the CPU: the
// library lookup of a plain Dart program is new, and their accelerator and
// dispatch libraries are not looked up there yet.
//
// Package-private.

import '../bundle/litertlm_bundle_info.dart';
import 'backend.dart';

/// Why [backend], asked for [what] (`'The engine'`, `'The vision encoder'`,
/// ...), does not run in a plain Dart program; null for the CPU and for no
/// backend.
String? plainDartBackendRefusal(String what, Backend? backend) =>
    switch (backend) {
      null || CpuBackend() => null,
      GpuBackend() || NpuBackend() =>
        'litertlm_dart: $what on $backend is not supported outside Flutter '
            'yet. $plainDartCpuOnly: pass Backend.cpu().',
    };

/// What every plain-Dart refusal says.
const plainDartCpuOnly =
    'In a plain Dart program (dart run, dart test, dart build cli) this '
    'release runs LiteRT-LM on the CPU only';

/// Why the file [bundle] at [path] cannot run on the CPU in a plain Dart
/// program, with the encoders the load turns on: its text model is compiled
/// for an NPU or declares backends without the CPU, or an encoder does.
/// Null when it can, and for a file that was not read ([bundle] null).
/// Refused before the load plan, whose advice (another backend) does not
/// apply here.
String? plainDartFileRefusal({
  required String path,
  required BundleInfo? bundle,
  required bool supportImage,
  required bool supportAudio,
}) {
  if (bundle == null) return null;
  String? why(String what, BundleSection? section) {
    if (section == null) return null;
    final target = section.npuTarget;
    if (target != null) return '$what is compiled for the $target NPU';
    final declared = section.backendConstraint;
    if (declared != null && declared.isNotEmpty && !declared.contains('cpu')) {
      return '$what declares that it runs on ${declared.join(', ')} '
          '(backend_constraint)';
    }
    return null;
  }

  final reason = bundle.isCompiledForNpu
      ? '$path is compiled for an NPU'
      : why(path, bundle.textModel) ??
            (supportImage
                ? why("$path's vision encoder", bundle.visionEncoder)
                : null) ??
            (supportAudio
                ? why("$path's audio encoder", bundle.audioEncoder)
                : null);
  if (reason == null) return null;
  return 'litertlm_dart: $reason, and $plainDartCpuOnly, so it cannot run '
      'here.';
}
