// Where a `.litertlm` LLM runs, decided from the file before any engine
// exists (owner-approved design, 2026-10-15).
//
// Why the file decides and not the request alone: LiteRT-LM checks the
// requested backends against the bundle only inside `engine_create` and
// `conversation_create`, and the failures it reports there do not say what to
// do. Measured on Developer Device Platform phones (2026-10-15): an
// NPU-compiled Gemma 4 asked for the GPU fails "Failed to create engine",
// then the CPU fallback fails the same way, and the app shows a CPU error the
// user never asked for; the official `…_qualcomm_sm8750` bundle with its
// encoders on the NPU loads, then fails at conversation create, because only
// its text model and `tf_lite_aux` are compiled for the NPU (read from the
// published file: the vision and audio sections carry no `LiteRtStamp`).
//
// The rules:
// - text: a bundle compiled for an NPU runs on the NPU only; otherwise the
//   text model's `backend_constraint`, when it has one, limits the backends
//   tried; without a request the first of GPU, CPU the bundle allows is
//   tried, and the NPU when it allows neither;
// - an encoder (vision, audio) the caller left unset runs where its section
//   says: its `backend_constraint` (CPU when it allows CPU), the NPU when it
//   is compiled for one, else the CPU, as before; an encoder asked for the NPU
//   it is not compiled for, or compiled for the NPU and asked for anything
//   else, is refused;
// - an incomplete file, a backend the bundle cannot run on, and an NPU this
//   package has no dispatch for are refused before any engine is created.

import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;

import '../embedding/litert_lm_npu.dart' show liteRtLmNpuEmbeddingAbis;
import '../litert_lm_load_errors.dart';
import 'litertlm_bundle_info.dart';

/// What a `.litertlm` load does.
typedef LiteRtLmLoadPlan = ({
  /// The backends to try for the text model, in order; never empty.
  List<PreferredBackend> textBackends,

  /// The vision encoder's backend; null when vision is off.
  PreferredBackend? visionBackend,

  /// The audio encoder's backend; null when audio is off.
  PreferredBackend? audioBackend,

  /// The NPU the bundle is compiled for, when it is.
  LiteRtLmNpuTarget? npuTarget,
});

/// Decides a load of [path] from what the file says ([bundle]; null when it
/// could not be read, which keeps the rules that need no file) and what the
/// caller asked for.
///
/// [npuAvailable] is asked only when the NPU is one of the backends to try,
/// because on Android it opens a vendor library; [npuUnavailableReason] says
/// why it is false. [abi] is `Abi.current()` as a string.
///
/// Throws [LiteRtLmBundleException] for a file that cannot run as asked, and
/// [BackendInitException] (one NPU attempt, a
/// [NpuDispatchUnavailableException]) when the NPU is the only backend to try
/// and this device cannot reach it — both before any engine exists.
LiteRtLmLoadPlan planLiteRtLmLoad({
  required String path,
  required LiteRtLmBundleInfo? bundle,
  required PreferredBackend? preferredBackend,
  required bool backendFallback,
  required bool supportImage,
  required bool supportAudio,
  PreferredBackend? preferredVisionBackend,
  PreferredBackend? preferredAudioBackend,
  required bool Function() npuAvailable,
  required String Function() npuUnavailableReason,
  required String abi,
}) {
  if (bundle != null && !bundle.isComplete) {
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.incomplete,
      '$path is ${bundle.fileLength} bytes, and its sections end at '
      '${bundle.expectedLength}: the download is incomplete. Install it again.',
      path: path,
    );
  }
  final target = bundle?.npuTarget;
  if (target != null) _checkNpuVendor(path, target, abi);

  final allowed = _textBackendsAllowed(bundle);
  final requested = preferredBackend;
  final order = switch (requested) {
    null => [
      ...[PreferredBackend.gpu, PreferredBackend.cpu].where(allowed.contains),
    ],
    final backend when !backendFallback => [backend],
    final backend => [
      for (final candidate in _fallbackOrder(backend))
        if (allowed.contains(candidate)) candidate,
    ],
  };
  var textBackends = order.isEmpty && requested == null
      ? [if (allowed.contains(PreferredBackend.npu)) PreferredBackend.npu]
      : order;
  if (!backendFallback && textBackends.length > 1) {
    textBackends = [textBackends.first];
  }
  if (textBackends.isEmpty ||
      (requested != null && !allowed.contains(requested) && !backendFallback)) {
    throw LiteRtLmBundleException(
      LiteRtLmBundleProblem.wrongBackend,
      _wrongTextBackend(path, bundle!, requested!),
      path: path,
    );
  }

  if (textBackends.contains(PreferredBackend.npu) && !npuAvailable()) {
    final rest = [
      for (final backend in textBackends)
        if (backend != PreferredBackend.npu) backend,
    ];
    if (rest.isEmpty) {
      final reason = npuUnavailableReason();
      final needs = bundle != null && bundle.isCompiledForNpu
          ? '$path is compiled for the '
                '${target == null ? 'NPU' : '$target NPU'} and runs only there, '
                'and $reason'
          : reason;
      throw BackendInitException(
        attempts: [
          BackendInitAttemptFailure(
            backend: PreferredBackend.npu,
            error: NpuDispatchUnavailableException(needs),
            stackTrace: StackTrace.current,
          ),
        ],
      );
    }
    // A generic bundle with a fallback: the NPU is dropped and the rest is
    // tried; the caller says so (initializeFfiRuntime's notice).
    textBackends = rest;
  }

  return (
    textBackends: textBackends,
    visionBackend: supportImage
        ? _encoderBackend(
            path,
            'vision',
            bundle?.visionEncoder,
            preferredVisionBackend,
          )
        : null,
    audioBackend: supportAudio
        ? _encoderBackend(
            path,
            'audio',
            bundle?.audioEncoder,
            preferredAudioBackend,
          )
        : null,
    npuTarget: target,
  );
}

/// The backends tried for a [requested] backend when falling back.
List<PreferredBackend> _fallbackOrder(PreferredBackend requested) =>
    switch (requested) {
      PreferredBackend.npu => const [
        PreferredBackend.npu,
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      ],
      PreferredBackend.gpu => const [
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      ],
      PreferredBackend.cpu => const [PreferredBackend.cpu],
    };

/// The backends the text model can run on: the NPU only for a bundle compiled
/// for one, else its `backend_constraint`, else any.
Set<PreferredBackend> _textBackendsAllowed(LiteRtLmBundleInfo? bundle) {
  if (bundle == null) return PreferredBackend.values.toSet();
  if (bundle.isCompiledForNpu) return {PreferredBackend.npu};
  final declared = _backends(bundle.textModel?.backendConstraint);
  return declared.isEmpty ? PreferredBackend.values.toSet() : declared;
}

/// The backends a `backend_constraint` names that this package knows.
Set<PreferredBackend> _backends(List<String>? constraint) => {
  for (final name in constraint ?? const <String>[])
    for (final backend in PreferredBackend.values)
      if (backend.name == name) backend,
};

String _wrongTextBackend(
  String path,
  LiteRtLmBundleInfo bundle,
  PreferredBackend requested,
) {
  if (bundle.isCompiledForNpu) {
    final target = bundle.npuTarget;
    return '$path is compiled for the ${target == null ? 'NPU' : '$target NPU'} '
        'and runs only there, not on ${requested.name}. Load it with '
        'preferredBackend: PreferredBackend.npu, or omit preferredBackend; to '
        'run on the ${requested.name}, install the generic bundle of this '
        'model.';
  }
  final declared = bundle.textModel!.backendConstraint!.join(', ');
  return '$path declares that its text model runs on $declared '
      '(backend_constraint), not on ${requested.name}. Load it with one of '
      'those, or omit preferredBackend.';
}

/// The backend of an encoder (`kind` vision or audio) whose section is
/// [encoder] (null when the bundle has none or could not be read), for a
/// [requested] backend.
PreferredBackend _encoderBackend(
  String path,
  String kind,
  LiteRtLmSection? encoder,
  PreferredBackend? requested,
) {
  final compiledFor = encoder?.npuTarget;
  if (requested != null) {
    if (encoder == null) return requested;
    if (requested == PreferredBackend.npu && compiledFor == null) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.wrongBackend,
        "$path's $kind encoder is not compiled for an NPU (its section "
        'carries no LiteRtStamp), so it cannot run on the NPU: LiteRT-LM would '
        'fail at conversation create. Omit the $kind backend to run it on '
        '${_encoderDefault(encoder).name}.',
        path: path,
      );
    }
    if (requested != PreferredBackend.npu && compiledFor != null) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.wrongBackend,
        "$path's $kind encoder is compiled for the $compiledFor NPU and runs "
        'only there, not on ${requested.name}. Omit the $kind backend to run it '
        'on the NPU.',
        path: path,
      );
    }
    return requested;
  }
  return encoder == null ? PreferredBackend.cpu : _encoderDefault(encoder);
}

/// Where an encoder runs when the caller does not say: its declared
/// `backend_constraint` (the CPU when that allows it, as before), the NPU it
/// is compiled for, else the CPU.
PreferredBackend _encoderDefault(LiteRtLmSection encoder) {
  final declared = _backends(encoder.backendConstraint);
  if (declared.isNotEmpty && !declared.contains(PreferredBackend.cpu)) {
    return [
      PreferredBackend.gpu,
      PreferredBackend.npu,
    ].firstWhere(declared.contains);
  }
  if (declared.isEmpty && encoder.npuTarget != null) {
    return PreferredBackend.npu;
  }
  return PreferredBackend.cpu;
}

/// Refuses a bundle compiled for an NPU this package has no dispatch for on
/// [abi]: Qualcomm runs on Android and Linux arm64, Intel on Windows x64.
void _checkNpuVendor(String path, LiteRtLmNpuTarget target, String abi) {
  final vendor = target.isQualcomm
      ? 'Qualcomm'
      : target.isIntel
      ? 'Intel'
      : null;
  final hostVendor = liteRtLmNpuEmbeddingAbis[abi];
  if (vendor != null && vendor == hostVendor) return;
  final hosts = vendor == null
      ? null
      : [
          for (final MapEntry(key: hostAbi, value: v)
              in liteRtLmNpuEmbeddingAbis.entries)
            if (v == vendor) hostAbi,
        ];
  throw LiteRtLmBundleException(
    LiteRtLmBundleProblem.unsupportedNpu,
    vendor == null
        ? '$path is compiled for the $target NPU. flutter_edge_ai_litertlm '
              'runs Qualcomm and Intel NPU bundles only; install the generic '
              'bundle of this model to run it on the GPU or the CPU.'
        : '$path is compiled for the $target NPU, which runs on '
              '${hosts!.join(' and ')} only, and this is $abi. Install the '
              'generic bundle of this model to run it here.',
    path: path,
  );
}
