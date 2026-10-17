import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../litert_lm_load_errors.dart';
import '../npu_stacks.dart';

export '../litert_lm_load_errors.dart'
    show BackendInitAttemptFailure, BackendInitException;

/// Whether this device reaches the NPU of any vendor ([NpuVendor]) at all.
///
/// Three hosts can: Android and Linux arm64 carry the Qualcomm QNN stack and
/// Windows carries Intel's (`LiteRtDispatch.dll` + OpenVino + TBB). Nothing
/// ships for macOS or iOS. On Android and Linux the stack is opt-in per app
/// (`qualcomm_npu`), so `LiteRtLmEngine.createModel` first asks
/// NativeAssetsManifest.json whether this build bundled it and only then lets
/// the vendor's probe ([hostReachesNpu]) decide.
///
/// This gate exists because `backend: "npu"` is a string the native runtime
/// accepts WITHOUT complaint on a host that cannot honour it. Since
/// [initializeFfiRuntime] reports the first candidate whose init did not throw,
/// a Mac asking for NPU got a model claiming `activeBackend == npu` —
/// measured, on macOS, with a Gemma 4 E2B `.litertlm`.
/// `InferenceModel.activeBackend` promises to "reflect any fallback the plugin
/// performed internally", so that was a false report: a benchmark asking for
/// NPU attributed its CPU or GPU numbers to an NPU the machine does not have.
///
/// Windows is still gated per OS, and that is known to be too coarse.
/// Measured 2026-09-27 on a Windows Server VM with no NPU (Xeon + T4): a
/// generic Gemma 4 E2B requested on npu passed `engine_create`, answered
/// correctly and reported `npu` — faster than explicit cpu, so it ran
/// somewhere else. Android got a hardware probe ([_androidHasFastRpc]);
/// Windows has none yet because its positive arm can only be verified on
/// Intel NPU silicon, and a probe guessed without that could switch off the
/// NPU on the machines that have one.
bool get hostShipsNpuDispatch => NpuVendor.values.any(hostReachesNpu);

/// Whether this device can run [vendor]'s NPU stack: its device probe, run
/// once per isolate, and only on the operating system it is for.
bool hostReachesNpu(NpuVendor vendor) {
  final os = Platform.operatingSystem;
  // `&&`, so a probe runs on its own platform only. As a plain argument it was
  // evaluated on every host that asked for npu: a dlopen of a Qualcomm library
  // on macOS, Linux and iOS, and on Windows a LoadLibrary that walks PATH.
  return npuVendorReachableOn(
    vendor,
    os,
    androidHasFastRpc:
        vendor == NpuVendor.qualcomm && os == 'android' && _androidHasFastRpc,
    linuxHasQualcommNpu:
        vendor == NpuVendor.qualcomm && os == 'linux' && _linuxHasQualcommNpu,
  );
}

/// Whether the FastRPC probe has run in this isolate. Lets a test prove it did
/// not run on a host where its answer is irrelevant.
@visibleForTesting
bool get fastRpcProbed => _fastRpcProbe != null;

/// The rule behind [hostShipsNpuDispatch], as a pure function: whether any
/// vendor is reachable on [operatingSystem] ([npuVendorReachableOn]).
///
/// Split out because `Platform.operatingSystem` has no override seam — `dart:io`'s
/// `IOOverrides` covers files, directories and sockets, not the platform — so the
/// Android and Windows arms are otherwise unreachable from a `flutter test` run
/// on a Mac, and a test can only restate the implementation back at itself.
bool npuDispatchShipsFor(
  String operatingSystem, {
  required bool androidHasFastRpc,
  bool linuxHasQualcommNpu = false,
}) => NpuVendor.values.any(
  (vendor) => npuVendorReachableOn(
    vendor,
    operatingSystem,
    androidHasFastRpc: androidHasFastRpc,
    linuxHasQualcommNpu: linuxHasQualcommNpu,
  ),
);

/// The rule behind [hostReachesNpu], as a pure function over the probes'
/// answers.
bool npuVendorReachableOn(
  NpuVendor vendor,
  String operatingSystem, {
  required bool androidHasFastRpc,
  bool linuxHasQualcommNpu = false,
}) => switch (vendor) {
  NpuVendor.qualcomm => switch (operatingSystem) {
    'android' => androidHasFastRpc,
    'linux' => linuxHasQualcommNpu,
    _ => false,
  },
  // Per OS, knowingly too coarse — see hostShipsNpuDispatch.
  NpuVendor.intel => operatingSystem == 'windows',
};

/// Whether the Linux probe has run in this isolate; see [fastRpcProbed].
@visibleForTesting
bool get linuxNpuProbed => _linuxNpuProbe != null;

bool? _linuxNpuProbe;

/// Why the Linux probe failed, worded for the person who has to fix it.
String? _linuxNpuProbeError;

/// Whether this Linux machine can run the Qualcomm NPU stack.
///
/// The stack is built for arm64 only, and on arm64 most machines (a Raspberry
/// Pi, a Jetson, a cloud VM) have no Hexagon DSP. Three things must hold, and
/// each failure gets its own reason because each has a different fix:
/// - `/dev/fastrpc-cdsp` exists — the kernel exposes a compute DSP;
/// - it and `/dev/dma_heap/system` open for this user — the upstream fastrpc
///   udev rules grant both to group `fastrpc`, which a fresh user is not in;
/// - `libcdsprpc.so.1` opens — Qualcomm's FastRPC user library, which the
///   bundled Stubs reach through our `libcdsprpc.so` shim.
///
/// The device files are opened read-only and closed at once: that maps no
/// memory and opens no DSP session. Probed once per isolate.
bool get _linuxHasQualcommNpu => _linuxNpuProbe ??= () {
  if (Abi.current() != Abi.linuxArm64) {
    _linuxNpuProbeError =
        'the Qualcomm NPU stack is built for linux_arm64 only, and this is '
        '${Abi.current()}';
    return false;
  }
  for (final node in const ['/dev/fastrpc-cdsp', '/dev/dma_heap/system']) {
    try {
      File(node).openSync().closeSync();
    } on FileSystemException catch (e) {
      final errno = e.osError?.errorCode;
      if (errno == 2 && node == '/dev/fastrpc-cdsp') {
        _linuxNpuProbeError =
            'this machine has no Qualcomm compute DSP ($node does not exist)';
        return false;
      }
      if (errno == 2) continue; // An older kernel without DMA-BUF heaps.
      _linuxNpuProbeError = errno == 13
          ? '$node is not accessible to this user. Add the user to group '
                'fastrpc (sudo usermod -aG fastrpc \$USER) and log in again'
          : '$node could not be opened: $e';
      return false;
    }
  }
  try {
    DynamicLibrary.open('libcdsprpc.so.1');
  } on Object catch (e) {
    _linuxNpuProbeError =
        "Qualcomm's FastRPC library libcdsprpc.so.1 did not open ($e); on "
        'Ubuntu it comes with the qcom-fastrpc1 package';
    return false;
  }
  return true;
}();

bool? _fastRpcProbe;

/// Why the probe failed, kept for the notice: "no Hexagon DSP" and "the library
/// is not visible to this app's linker namespace" are different answers, and
/// only the error text tells them apart.
String? _fastRpcProbeError;

/// Whether Qualcomm's FastRPC bridge resolves in this process.
///
/// The OS is the wrong granularity on Android. The Qualcomm stack ships in every
/// `android_arm64` build, so a Tensor, Exynos or Dimensity phone has all eleven
/// libraries in its APK and no Hexagon DSP to run them on. Offering `npu` there
/// costs a 55.1 MiB zip extraction out of the APK into `codeCacheDir` — measured
/// on the native-v0.17.1 bundle, of which 44 MiB is the four per-SoC Skels — and
/// that extraction runs on the platform thread inside a `MethodChannel` handler,
/// so it stalls input dispatch and the Choreographer. `codeCacheDir` is
/// cache-class storage, so "Clear cache" and every app
/// upgrade make it happen again.
///
/// `libcdsprpc.so` is the precondition for the chain: the per-SoC `QnnHtp*Stub`
/// libraries carry it as a `DT_NEEDED`, and the core plugin's manifest declares
/// it `required="false"` so it resolves in the app's namespace where it exists.
/// So one `dlopen` answers whether there is a Hexagon DSP at all, before the
/// gate lets anything reach the channel that does the extracting. Necessary,
/// not sufficient: a Snapdragon whose Hexagon version has no Skel in the bundle
/// (only V73/V75/V79/V81 ship) passes this probe too.
///
/// Probed once: the answer cannot change within a process.
bool get _androidHasFastRpc => _fastRpcProbe ??= () {
  try {
    DynamicLibrary.open('libcdsprpc.so');
    return true;
  } on Object catch (e) {
    _fastRpcProbeError = '$e';
    return false;
  }
}();

/// Why no vendor's NPU is on offer on [operatingSystem]: the reason of each
/// vendor that runs there ([npuVendorUnreachableReason]), with the error its
/// probe kept in [probeErrors].
///
/// Android is its own case: the stack DOES ship there, in every arm64 build —
/// what is missing is the device's FastRPC. Saying "no NPU dispatch stack ships
/// for android" and then "NPU is available on Android" in one line was the
/// shape this replaced.
@visibleForTesting
String npuUnavailableReason(
  String operatingSystem, {
  Map<NpuVendor, String> probeErrors = const {},
}) {
  final reasons = [
    for (final vendor in NpuVendor.values)
      if (vendor.runsOn(operatingSystem))
        npuVendorUnreachableReason(
          vendor,
          operatingSystem,
          probeError: probeErrors[vendor],
        ),
  ];
  return reasons.isEmpty
      ? 'no NPU dispatch stack ships for $operatingSystem'
      : reasons.join('; ');
}

/// Why [vendor]'s NPU stack cannot run on [operatingSystem], with the error
/// its probe kept, when it kept one.
String npuVendorUnreachableReason(
  NpuVendor vendor,
  String operatingSystem, {
  String? probeError,
}) => switch (vendor) {
  NpuVendor.qualcomm =>
    operatingSystem == 'linux'
        ? 'the bundled Qualcomm NPU stack cannot run here: '
              '${probeError ?? 'this machine has no Qualcomm NPU'}'
        : 'this device has no Qualcomm FastRPC (libcdsprpc.so did not open'
              '${probeError == null ? '' : ': $probeError'}), so the bundled '
              'NPU stack cannot run here',
  // Never unreachable where it runs: Windows has no NPU probe yet
  // (hostShipsNpuDispatch).
  NpuVendor.intel => 'no Intel NPU stack ships for $operatingSystem',
};

/// The error [vendor]'s probe kept on this host; null when it did not run or
/// did not fail.
String? _probeError(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm =>
    Platform.isLinux ? _linuxNpuProbeError : _fastRpcProbeError,
  NpuVendor.intel => null,
};

/// Why this host cannot run any vendor's NPU stack, from the probes
/// [hostShipsNpuDispatch] ran (read it after that getter).
String get hostNpuUnavailableReason => npuUnavailableReason(
  Platform.operatingSystem,
  probeErrors: {
    for (final vendor in NpuVendor.values) vendor: ?_probeError(vendor),
  },
);

/// Why this host cannot run [vendor]'s NPU stack, from the probe
/// [hostReachesNpu] ran (read it after that call). For the EmbeddingGemma 2
/// refusal and the LLM load plan, which word the same reason.
String hostNpuUnreachableReason(NpuVendor vendor) => npuVendorUnreachableReason(
  vendor,
  Platform.operatingSystem,
  probeError: _probeError(vendor),
);

/// Where [vendor]'s NPU runs, for the notice that the NPU was not tried.
String _whereNpuRuns(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm =>
    'Qualcomm Android and Qualcomm Linux arm64 (in apps built with '
        'hooks.user_defines.flutter_edge_ai_litertlm.$qualcommNpuUserDefine: '
        'true)',
  NpuVendor.intel => 'on Windows (Intel LunarLake/PantherLake)',
};

/// The backends to try, in order, for a [preferredBackend] request.
///
/// [npuDispatchAvailable] overrides [hostShipsNpuDispatch] — tests need both
/// answers, and a platform-dependent default cannot give them one.
List<PreferredBackend> ffiBackendFallbackOrder(
  PreferredBackend? preferredBackend, {
  bool? npuDispatchAvailable,
}) => switch (preferredBackend) {
  PreferredBackend.npu => [
    // Offered only where a dispatch stack exists. Dropping it here is what
    // makes the reported `activeBackend` true on the other four platforms.
    if (npuDispatchAvailable ?? hostShipsNpuDispatch) PreferredBackend.npu,
    PreferredBackend.gpu,
    PreferredBackend.cpu,
  ],
  PreferredBackend.gpu ||
  null => const [PreferredBackend.gpu, PreferredBackend.cpu],
  PreferredBackend.cpu => const [PreferredBackend.cpu],
};

String ffiBackendWireName(PreferredBackend backend) => switch (backend) {
  PreferredBackend.npu => 'npu',
  PreferredBackend.gpu => 'gpu',
  PreferredBackend.cpu => 'cpu',
};

/// Wire name for an ENCODER backend (vision / audio), defaulting to `cpu` when
/// unset. Shared by both because their defaulting is identical (`null → cpu`).
///
/// The LLM engine passes what its load plan chose from the bundle (the
/// section's `backend_constraint`, else the NPU it is compiled for, else CPU),
/// so `null` reaches here only for a file the plan could not read. CPU is
/// the safe value then: the VISION graph carries `STABLEHLO_COMPOSITE` ops the
/// Metal (iOS/macOS) and WebGPU (Windows/Linux) LiteRT delegates cannot
/// prepare — it hard-fails at `conversation_create` with no backend fallback
/// (LiteRT-LM#2461, open upstream) — and the published Gemma 4 and Gemma 3n
/// AUDIO encoders declare `backend_constraint` cpu.
String encoderBackendWireName(PreferredBackend? encoderBackend) =>
    encoderBackend == null ? 'cpu' : ffiBackendWireName(encoderBackend);

/// The C API's number for [type] (`ActivationDataType` in LiteRT-LM's
/// `executor_settings_base.h`: 0 F32, 1 F16, and 2 I16 / 3 I8 which the Dart
/// enum does not offer), or null to leave the engine setting untouched.
/// Spelled out rather than taken from `index`, so reordering the Dart enum
/// cannot silently change what native receives.
int? activationDataTypeWireValue(ActivationDataType? type) => switch (type) {
  null => null,
  ActivationDataType.float32 => 0,
  ActivationDataType.float16 => 1,
};

Future<({T client, PreferredBackend activeBackend})> initializeFfiRuntime<T>({
  required PreferredBackend? preferredBackend,
  required String logTag,
  required T Function() createClient,
  required Future<void> Function(T client, PreferredBackend backend)
  initializeClient,
  // FutureOr: LiteRtLmFfiClient.shutdown() is async (it waits for in-flight
  // conversation creates before engine_delete); test fakes tear down
  // synchronously. Awaiting covers both, so a failed backend is fully released
  // before the next one allocates an engine.
  required FutureOr<void> Function(T client) shutdownClient,
  bool? npuDispatchAvailable,
  // Why npu is off when the caller decided so from something this file cannot
  // see — on Android, the build not bundling the opt-in Qualcomm stack.
  String? npuUnavailableBecause,
  // The backends to try, when the caller decided them (the LLM engine does,
  // from the bundle: `planLiteRtLmLoad`); otherwise [ffiBackendFallbackOrder].
  List<PreferredBackend>? backends,
  // Why the caller left a backend of the request out of [backends] — the
  // model file rules it out (`LiteRtLmLoadPlan.dropped`). The notice below
  // says that instead of a reason about the host.
  Map<PreferredBackend, String> droppedBecause = const {},
}) async {
  final attempts = <BackendInitAttemptFailure>[];
  backends ??= ffiBackendFallbackOrder(
    preferredBackend,
    npuDispatchAvailable: npuDispatchAvailable,
  );

  if (backends.isEmpty) {
    throw StateError('No FFI backend candidates are available.');
  }

  // Said out loud rather than dropped: the request cannot be honoured here, and
  // a caller who reads `activeBackend` will see gpu or cpu with no explanation
  // of why the thing they asked for is absent.
  //
  // `print`, the one channel that reaches both a release build and a
  // `flutter run` terminal: `gemmaLog` returns early in release, and
  // flutter_tools never subscribes to the VM-service `Logging` stream that
  // `developer.log` writes to. An explicit request overridden is an abnormal
  // state, so this costs nothing in the normal case — the same reasoning as
  // `_warn` in litert_default_scope.dart.
  final fileReason = preferredBackend == null
      ? null
      : droppedBecause[preferredBackend];
  if (fileReason != null && !backends.contains(preferredBackend)) {
    // ignore: avoid_print
    print(
      '[flutter_edge_ai] WARNING: $logTag '
      '${ffiBackendWireName(preferredBackend!)} was requested, but '
      '$fileReason — trying ${backends.map(ffiBackendWireName).join(" -> ")} '
      'instead. InferenceModel.activeBackend names what actually ran.',
    );
  } else if (preferredBackend == PreferredBackend.npu &&
      !backends.contains(PreferredBackend.npu)) {
    final reason = npuUnavailableBecause ?? hostNpuUnavailableReason;
    // ignore: avoid_print
    print(
      '[flutter_edge_ai] WARNING: $logTag npu was requested, but $reason — '
      'trying ${backends.map(ffiBackendWireName).join(" -> ")} instead. NPU '
      'runs on ${npuSentenceList(NpuVendor.values.map(_whereNpuRuns))}. '
      'InferenceModel.activeBackend names what actually ran.',
    );
  }

  for (final backend in backends) {
    final client = createClient();
    try {
      await initializeClient(client, backend);
      return (client: client, activeBackend: backend);
    } on Exception catch (error, stackTrace) {
      attempts.add(
        BackendInitAttemptFailure(
          backend: backend,
          error: error,
          stackTrace: stackTrace,
        ),
      );
      await shutdownClient(client);
      // Both, for two readers. `developer.log` carries the structured error and
      // stack trace to DevTools, which is where they are useful. `print` is the
      // line a person sees — in a `flutter run` terminal and in a release
      // build's logcat — for the same reason as the npu notice above.
      developer.log(
        '$logTag ${ffiBackendWireName(backend)} backend failed: $error',
        name: 'flutter_edge_ai',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
      final next = backend == backends.last
          ? 'no candidates are left'
          : 'trying the next candidate';
      // ignore: avoid_print
      print(
        '[flutter_edge_ai] WARNING: $logTag ${ffiBackendWireName(backend)} '
        'backend failed, $next: $error',
      );
    }
  }

  if (attempts.isEmpty) {
    throw StateError('No FFI backend candidates were attempted.');
  }

  final exception = BackendInitException(attempts: attempts);
  Error.throwWithStackTrace(exception, exception.lastAttempt.stackTrace);
}
