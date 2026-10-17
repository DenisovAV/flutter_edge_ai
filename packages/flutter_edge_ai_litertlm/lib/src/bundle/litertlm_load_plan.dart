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
//   is compiled for one, else the CPU, as before; an encoder asked for a
//   backend its `backend_constraint` excludes, for the NPU it is not compiled
//   for, or compiled for the NPU and asked for anything else, is refused; a
//   bundle without the encoder reports none;
// - an incomplete file, a backend the bundle cannot run on, and a text model,
//   or an encoder that is on, compiled for an NPU this package has no
//   dispatch for are refused before any engine is created. An encoder that is
//   off is not checked: a text-only load does not run it;
// - an encoder that is on and runs on the NPU needs an NPU this device
//   reaches, and a text model tried on the NPU alone: the FFI client prepares
//   the NPU dispatch for an NPU text attempt only, so a GPU or CPU attempt
//   would fail at engine create. Both are refused before any engine. No
//   published bundle compiles an encoder for the NPU next to a generic text
//   model; an all-NPU build compiles both.

import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;

import '../litert_lm_load_errors.dart';
import '../npu_stacks.dart';
import 'litertlm_bundle_info.dart';

/// What a `.litertlm` load does.
typedef LiteRtLmLoadPlan = ({
  /// The backends to try for the text model, in order; never empty.
  List<PreferredBackend> textBackends,

  /// The vision encoder's backend; null when vision is off or the bundle (read)
  /// has no vision encoder.
  PreferredBackend? visionBackend,

  /// The audio encoder's backend; null when audio is off or the bundle (read)
  /// has no audio encoder.
  PreferredBackend? audioBackend,

  /// The NPU the text model is compiled for, else the one an encoder that is
  /// on is compiled for; null when none of them is.
  LiteRtLmNpuTarget? npuTarget,

  /// The backends of the request's fallback order the file rules out, each
  /// with why (the text model's declared `backend_constraint`, or a bundle
  /// compiled for an NPU), for the notice that the requested backend is not
  /// tried. An NPU left out because this device cannot reach it is not here:
  /// `initializeFfiRuntime` words that reason from the host.
  Map<PreferredBackend, String> dropped,
});

/// The text backends a load of [path] tries before it asks whether the NPU
/// can be reached, and the backends of the request the file rules out (see
/// [LiteRtLmLoadPlan]). [planLiteRtLmLoad] starts from it; the engine asks it
/// first, so that it looks for the app's NPU stack only when the NPU is one of
/// the backends.
///
/// Throws [LiteRtLmBundleException] as [planLiteRtLmLoad] does.
({List<PreferredBackend> backends, Map<PreferredBackend, String> dropped})
liteRtLmTextCandidates({
  required String path,
  required LiteRtLmBundleInfo? bundle,
  required PreferredBackend? preferredBackend,
  required bool backendFallback,
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
  // The text model's NPU only: an encoder compiled for one is checked when
  // that encoder is on (`_encoderBackend`).
  final target = _textNpuTarget(bundle);
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
  return (
    backends: textBackends,
    dropped: {
      if (requested != null && backendFallback)
        for (final candidate in _fallbackOrder(requested))
          if (!allowed.contains(candidate))
            candidate: _textRulesOut(path, bundle!),
    },
  );
}

/// Whether an encoder the load turns on runs on the NPU of a [bundle] that
/// was read, by the rule [planLiteRtLmLoad] applies (the request, else
/// [_encoderDefault]). The engine asks it with [liteRtLmTextCandidates], so
/// that it looks for the app's NPU stack also when only an encoder needs the
/// NPU. A request the plan then refuses may count: the plan throws before the
/// stack's answer is used. A file that could not be read keeps the old rules.
bool liteRtLmEncoderOnNpu({
  required LiteRtLmBundleInfo? bundle,
  required bool supportImage,
  required bool supportAudio,
  PreferredBackend? preferredVisionBackend,
  PreferredBackend? preferredAudioBackend,
}) {
  if (bundle == null) return false;
  bool onNpu(LiteRtLmSection? encoder, PreferredBackend? requested) =>
      encoder != null &&
      (requested ?? _encoderDefault(encoder)) == PreferredBackend.npu;
  return (supportImage &&
          onNpu(bundle.visionEncoder, preferredVisionBackend)) ||
      (supportAudio && onNpu(bundle.audioEncoder, preferredAudioBackend));
}

/// The NPU a load of [bundle] runs on when it runs on one: the text model's
/// (its own stamp, else `tf_lite_aux`'s), else that of an encoder the load
/// turns on. Null for a bundle compiled for no NPU, and for one that was not
/// read. The engine asks it before the plan, to look up that vendor's stack.
LiteRtLmNpuTarget? liteRtLmLoadNpuTarget({
  required LiteRtLmBundleInfo? bundle,
  required bool supportImage,
  required bool supportAudio,
}) =>
    _textNpuTarget(bundle) ??
    (supportImage ? bundle?.visionEncoder?.npuTarget : null) ??
    (supportAudio ? bundle?.audioEncoder?.npuTarget : null);

/// Decides a load of [path] from what the file says ([bundle]; null when it
/// could not be read, which keeps the rules that need no file) and what the
/// caller asked for.
///
/// [npuAvailable] is asked only when the NPU is one of the backends to try,
/// or an encoder that is on runs there, because on Android it opens a vendor
/// library; [npuUnavailableReason] says why it is false. [abi] is
/// `Abi.current()` as a string.
///
/// Throws [LiteRtLmBundleException] for a file that cannot run as asked
/// (among them an encoder that is on and runs on the NPU while the text model
/// is not tried on the NPU alone), and [BackendInitException] (one NPU
/// attempt, a [NpuDispatchUnavailableException]) when the NPU is the only
/// backend to try, or an encoder that is on runs only there, and this device
/// cannot reach it — both before any engine exists.
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
  final candidates = liteRtLmTextCandidates(
    path: path,
    bundle: bundle,
    preferredBackend: preferredBackend,
    backendFallback: backendFallback,
    abi: abi,
  );
  final target = _textNpuTarget(bundle);
  var textBackends = candidates.backends;
  // An encoder that is on and compiled for an NPU this host has no dispatch
  // for is refused for what it is before the NPU is asked about: the question
  // has no answer for a vendor this host does not run, and its reason would
  // name the wrong stack.
  for (final (kind, on, encoder) in [
    ('vision', supportImage, bundle?.visionEncoder),
    ('audio', supportAudio, bundle?.audioEncoder),
  ]) {
    final compiledFor = encoder?.npuTarget;
    if (on && compiledFor != null) {
      _checkNpuVendor(path, compiledFor, abi, encoder: kind);
    }
  }
  // Asked once per load: on Android it opens a vendor library.
  bool? reachable;
  bool npuReachable() => reachable ??= npuAvailable();

  if (textBackends.contains(PreferredBackend.npu) && !npuReachable()) {
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

  final visionBackend = supportImage
      ? _encoderBackend(
          path,
          'vision',
          bundle,
          bundle?.visionEncoder,
          preferredVisionBackend,
          abi,
        )
      : null;
  final audioBackend = supportAudio
      ? _encoderBackend(
          path,
          'audio',
          bundle,
          bundle?.audioEncoder,
          preferredAudioBackend,
          abi,
        )
      : null;
  // An encoder on the NPU gets the NPU dispatch only through an NPU text
  // attempt (`LiteRtLmFfiClient.initialize`), so it needs a reachable NPU and
  // a text model tried there alone. A file that could not be read keeps the
  // old rules.
  for (final (kind, backend, encoder) in [
    ('vision', visionBackend, bundle?.visionEncoder),
    ('audio', audioBackend, bundle?.audioEncoder),
  ]) {
    if (backend != PreferredBackend.npu || encoder == null) continue;
    final runs = encoder.npuTarget == null
        ? "$path's $kind encoder runs only on the NPU"
        : "$path's $kind encoder is compiled for the ${encoder.npuTarget} NPU "
              'and runs only there';
    if (!npuReachable()) {
      throw BackendInitException(
        attempts: [
          BackendInitAttemptFailure(
            backend: PreferredBackend.npu,
            error: NpuDispatchUnavailableException(
              '$runs, and ${npuUnavailableReason()}',
            ),
            stackTrace: StackTrace.current,
          ),
        ],
      );
    }
    if (textBackends.any((text) => text != PreferredBackend.npu)) {
      final flag = kind == 'vision' ? 'supportImage' : 'supportAudio';
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.unsupportedNpu,
        '$runs, and its text model would be tried on '
        '${textBackends.map((text) => text.name).join(', then ')}, not '
        'on the NPU alone. flutter_edge_ai_litertlm runs an encoder on the NPU '
        'only together with a text model on the NPU (a bundle compiled for the '
        'NPU throughout). Load it without $flag to run the text model alone, '
        'or install the generic bundle of this model.',
        path: path,
      );
    }
  }
  return (
    textBackends: textBackends,
    visionBackend: visionBackend,
    audioBackend: audioBackend,
    npuTarget: liteRtLmLoadNpuTarget(
      bundle: bundle,
      supportImage: supportImage,
      supportAudio: supportAudio,
    ),
    dropped: candidates.dropped,
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

/// The NPU the text model is compiled for: its own stamp, else the
/// `tf_lite_aux` section's — the two sections that make it NPU-only
/// ([LiteRtLmBundleInfo.isCompiledForNpu]). An encoder's stamp is not the
/// text model's: a text-only load does not run that encoder.
LiteRtLmNpuTarget? _textNpuTarget(LiteRtLmBundleInfo? bundle) =>
    bundle?.textModel?.npuTarget ?? bundle?.sectionOf('tf_lite_aux')?.npuTarget;

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
    return '${_textRulesOut(path, bundle)}, not on ${requested.name}. Load it '
        'with preferredBackend: PreferredBackend.npu, or omit '
        'preferredBackend; to run on the ${requested.name}, install the '
        'generic bundle of this model.';
  }
  return '${_textRulesOut(path, bundle)}, not on ${requested.name}. Load it '
      'with one of those, or omit preferredBackend.';
}

/// Why the file rules a backend out for its text model: it is compiled for an
/// NPU, or it declares the backends it runs on.
String _textRulesOut(String path, LiteRtLmBundleInfo bundle) {
  if (bundle.isCompiledForNpu) {
    final target = _textNpuTarget(bundle);
    return '$path is compiled for the ${target == null ? 'NPU' : '$target NPU'} '
        'and runs only there';
  }
  final declared = bundle.textModel!.backendConstraint!.join(', ');
  return '$path declares that its text model runs on $declared '
      '(backend_constraint)';
}

/// The backend of an encoder (`kind` vision or audio) whose section in
/// [bundle] is [encoder], for a [requested] backend. Null for a bundle that
/// was read and has no such encoder: nothing runs it. A file that could not
/// be read keeps the rules that need no file: the request, else the CPU.
///
/// Called only for an encoder that is on, so only then is an encoder compiled
/// for an NPU checked against [abi].
PreferredBackend? _encoderBackend(
  String path,
  String kind,
  LiteRtLmBundleInfo? bundle,
  LiteRtLmSection? encoder,
  PreferredBackend? requested,
  String abi,
) {
  if (encoder == null) {
    return bundle != null ? null : requested ?? PreferredBackend.cpu;
  }
  final compiledFor = encoder.npuTarget;
  if (compiledFor != null) {
    _checkNpuVendor(path, compiledFor, abi, encoder: kind);
  }
  if (requested != null) {
    // LiteRT-LM checks the requested backend against the section's
    // `backend_constraint` at engine_create ("Audio backend constraint
    // mismatch"), the failure every text backend would then report.
    final declared = _backends(encoder.backendConstraint);
    if (declared.isNotEmpty && !declared.contains(requested)) {
      throw LiteRtLmBundleException(
        LiteRtLmBundleProblem.wrongBackend,
        "$path's $kind encoder declares that it runs on "
        '${encoder.backendConstraint!.join(', ')} (backend_constraint), not '
        'on ${requested.name}. Omit the $kind backend to run it on '
        '${_encoderDefault(encoder).name}, or ask for one of those.',
        path: path,
      );
    }
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
  return _encoderDefault(encoder);
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

/// Refuses a [target] NPU this package has no dispatch for on [abi]
/// ([NpuVendor.abis]). [encoder] is the kind (vision, audio) of the encoder
/// compiled for it, null for the text model.
void _checkNpuVendor(
  String path,
  LiteRtLmNpuTarget target,
  String abi, {
  String? encoder,
}) {
  final vendor = npuVendorOf(target);
  if (vendor != null && vendor.abis.contains(abi)) return;
  final what = encoder == null ? path : "$path's $encoder encoder";
  // An encoder that is off is not run: the load works without it.
  final instead = switch (encoder) {
    null => 'install',
    'vision' => 'load it without supportImage, or install',
    _ => 'load it without supportAudio, or install',
  };
  throw LiteRtLmBundleException(
    LiteRtLmBundleProblem.unsupportedNpu,
    vendor == null
        ? '$what is compiled for the $target NPU. flutter_edge_ai_litertlm '
              'runs ${npuSentenceList(NpuVendor.values.map((v) => v.label))} '
              'NPU bundles only; $instead the generic bundle of this model to '
              'run it on the GPU or the CPU.'
        : '$what is compiled for the $target NPU, which runs on '
              '${vendor.abis.join(' and ')} only, and this is $abi; $instead '
              'the generic bundle of this model to run it here.',
    path: path,
  );
}
