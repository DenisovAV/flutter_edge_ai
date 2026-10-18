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

/// Why this device cannot run [vendor]'s NPU stack on [operatingSystem], or
/// null when it can — the vendor's device probe, through [probes], worded for
/// the person who has to fix it.
///
/// This gate exists because `backend: "npu"` is a string the native runtime
/// accepts WITHOUT complaint on a host that cannot honour it. Since
/// [initializeFfiRuntime] reports the first candidate whose init did not throw,
/// a Mac asking for NPU got a model claiming `activeBackend == npu` —
/// measured, on macOS, with a Gemma 4 E2B `.litertlm`.
/// `InferenceModel.activeBackend` promises to "reflect any fallback the plugin
/// performed internally", so that was a false report: a benchmark asking for
/// NPU attributed its CPU or GPU numbers to an NPU the machine does not have.
/// Hosts with no vendor at all never get here ([npuNoVendorReason]).
///
/// Each vendor names its probe per operating system, and an operating system
/// it has no probe for is a programming error: [NpuVendor.abis] decides where
/// a vendor is asked about at all, so a host added there without a probe here
/// fails at once instead of borrowing another platform's answer.
///
/// Split from the probes ([NpuProbes]) because `Platform.operatingSystem` has
/// no override seam — `dart:io`'s `IOOverrides` covers files, directories and
/// sockets, not the platform — so the Android and Windows arms are otherwise
/// unreachable from a `flutter test` run on a Mac.
String? npuUnreachable(
  NpuVendor vendor,
  String operatingSystem,
  NpuProbes probes,
) => switch (vendor) {
  NpuVendor.qualcomm => switch (operatingSystem) {
    'android' => switch (probes.androidFastRpc()) {
      null => null,
      final error =>
        'this device has no Qualcomm FastRPC ($qualcommAndroidFastRpcLib did '
            'not open: $error), so the bundled NPU stack cannot run here',
    },
    'linux' => switch (probes.linuxQualcommNpu()) {
      null => null,
      final error => 'the bundled Qualcomm NPU stack cannot run here: $error',
    },
    _ => throw StateError(
      'NpuVendor.qualcomm has no device probe for $operatingSystem',
    ),
  },
  // Windows has no probe yet, and that is known to be too coarse. Measured
  // 2026-09-27 on a Windows Server VM with no NPU (Xeon + T4): a generic
  // Gemma 4 E2B requested on npu passed `engine_create`, answered correctly
  // and reported `npu` — faster than explicit cpu, so it ran somewhere else.
  // Its positive arm can only be verified on Intel NPU silicon, and a probe
  // guessed without that could switch off the NPU on the machines that have
  // one.
  NpuVendor.intel => switch (operatingSystem) {
    'windows' => null,
    _ => throw StateError(
      'NpuVendor.intel has no device probe for $operatingSystem',
    ),
  },
};

/// Why no NPU is on offer on [abi]: no vendor this package dispatches to runs
/// there ([NpuVendor.forAbi] is empty).
String npuNoVendorReason(String abi) => 'no NPU dispatch stack ships for $abi';

/// Each vendor's device probe: null when it passes, else why not. One member
/// per probe, so a vendor whose probe is added to [npuUnreachable] is a
/// compile error in every implementation until it answers.
abstract interface class NpuProbes {
  /// Whether Qualcomm's FastRPC bridge resolves in this Android process: null
  /// when `libcdsprpc.so` opens, else the dlopen error.
  String? androidFastRpc();

  /// Whether this Linux machine can run the Qualcomm NPU stack: null when it
  /// can, else why not.
  String? linuxQualcommNpu();
}

/// The probes of this process, each run once per isolate: the answer cannot
/// change within a process.
const NpuProbes platformNpuProbes = _PlatformNpuProbes();

final class _PlatformNpuProbes implements NpuProbes {
  const _PlatformNpuProbes();

  @override
  String? androidFastRpc() => _androidFastRpcError;

  @override
  String? linuxQualcommNpu() => _linuxQualcommNpuError;
}

/// Whether the FastRPC probe has run in this isolate. Lets a test prove it did
/// not run on a host where its answer is irrelevant.
@visibleForTesting
bool get fastRpcProbed => _fastRpcProbe != null;

/// Whether the Linux probe has run in this isolate; see [fastRpcProbed].
@visibleForTesting
bool get linuxNpuProbed => _linuxNpuProbe != null;

/// The Linux probe's answer: null when it passed, else why not.
(String?,)? _linuxNpuProbe;

/// Whether this Linux machine can run the Qualcomm NPU stack: null when it
/// can, else why not, worded for the person who has to fix it.
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
String? get _linuxQualcommNpuError => (_linuxNpuProbe ??= (
  () {
    if (Abi.current() != Abi.linuxArm64) {
      return 'the Qualcomm NPU stack is built for linux_arm64 only, and this is '
          '${Abi.current()}';
    }
    for (final node in const ['/dev/fastrpc-cdsp', '/dev/dma_heap/system']) {
      try {
        File(node).openSync().closeSync();
      } on FileSystemException catch (e) {
        final errno = e.osError?.errorCode;
        if (errno == 2 && node == '/dev/fastrpc-cdsp') {
          return 'this machine has no Qualcomm compute DSP ($node does not exist)';
        }
        if (errno == 2) continue; // An older kernel without DMA-BUF heaps.
        return errno == 13
            ? '$node is not accessible to this user. Add the user to group '
                  'fastrpc (sudo usermod -aG fastrpc \$USER) and log in again'
            : '$node could not be opened: $e';
      }
    }
    try {
      DynamicLibrary.open('libcdsprpc.so.1');
    } on Object catch (e) {
      return "Qualcomm's FastRPC library libcdsprpc.so.1 did not open ($e); on "
          'Ubuntu it comes with the qcom-fastrpc1 package';
    }
    return null;
  }(),
)).$1;

/// The FastRPC probe's answer: null when it passed, else the dlopen error.
(String?,)? _fastRpcProbe;

/// Whether Qualcomm's FastRPC bridge resolves in this process: null when it
/// does, else the dlopen error, kept for the notice: "no Hexagon DSP" and "the
/// library is not visible to this app's linker namespace" are different
/// answers, and only the error text tells them apart.
///
/// The OS is the wrong granularity on Android. An app that opts in to the
/// Qualcomm stack ships all of it in every `android_arm64` build, so a Tensor,
/// Exynos or Dimensity phone has the libraries in its APK and no Hexagon DSP
/// to run them on. Offering `npu` there costs a 55.1 MiB zip extraction out of
/// the APK into `codeCacheDir` — measured on the native-v0.17.1 bundle, of
/// which 44 MiB is the four per-SoC Skels. `codeCacheDir` is cache-class
/// storage, so "Clear cache" and every app upgrade make it happen again.
///
/// `libcdsprpc.so` is the precondition for the chain: the per-SoC `QnnHtp*Stub`
/// libraries carry it as a `DT_NEEDED`, and the core plugin's manifest declares
/// it `required="false"` so it resolves in the app's namespace where it exists.
/// So one `dlopen` answers whether there is a Hexagon DSP at all, before
/// anything reaches the channel that does the extracting. Necessary, not
/// sufficient: a Snapdragon whose Hexagon version has no Skel in the bundle
/// (only V73/V75/V79/V81 ship) passes this probe too.
String? get _androidFastRpcError => (_fastRpcProbe ??= (
  () {
    try {
      DynamicLibrary.open(qualcommAndroidFastRpcLib);
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }(),
)).$1;

/// Where [vendor]'s NPU runs, for the notice that the NPU was not tried.
String _whereNpuRuns(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm =>
    'Qualcomm Android and Qualcomm Linux arm64 (in apps built with '
        'hooks.user_defines.flutter_edge_ai_litertlm.$qualcommNpuUserDefine: '
        'true)',
  NpuVendor.intel => 'on Windows (Intel LunarLake/PantherLake)',
};

/// The backends to try, in order, for a [preferredBackend] request, the NPU
/// only when [npuAvailable].
List<PreferredBackend> ffiBackendFallbackOrder(
  PreferredBackend? preferredBackend, {
  required bool npuAvailable,
}) => switch (preferredBackend) {
  PreferredBackend.npu => [
    // Offered only where a dispatch stack exists. Dropping it here is what
    // makes the reported `activeBackend` true on the other four platforms.
    if (npuAvailable) PreferredBackend.npu,
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
  // Why npu is off when it is not tried: the build's stack or the device's
  // probe (`chooseNpuVendor`); null words it from the host ([npuNoVendorReason]).
  String? npuUnavailableBecause,
  // The backends to try, in order: what the caller decided (the LLM engine
  // does, from the bundle: `planLiteRtLmLoad`), or [ffiBackendFallbackOrder].
  required List<PreferredBackend> backends,
  // Why the caller left a backend of the request out of [backends] — the
  // model file rules it out (`LiteRtLmLoadPlan.dropped`). The notice below
  // says that instead of a reason about the host.
  Map<PreferredBackend, String> droppedBecause = const {},
}) async {
  final attempts = <BackendInitAttemptFailure>[];
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
    final reason =
        npuUnavailableBecause ?? npuNoVendorReason('${Abi.current()}');
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
