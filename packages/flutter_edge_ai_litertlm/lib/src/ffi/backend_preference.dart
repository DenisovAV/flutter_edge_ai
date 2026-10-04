import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/core/domain/platform_types.dart';

/// Whether this host ships an NPU dispatch stack at all.
///
/// Exactly two do: Android carries the Qualcomm QNN stack and Windows carries
/// Intel's (`LiteRtDispatch.dll` + OpenVino + TBB), each in its own native
/// tarball. Nothing ships for macOS, Linux or iOS.
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
bool get hostShipsNpuDispatch {
  final os = Platform.operatingSystem;
  // `&&`, so the probe runs on Android only. As a plain argument it was
  // evaluated on every host that asked for npu: a dlopen of a Qualcomm library
  // on macOS, Linux and iOS, and on Windows a LoadLibrary that walks PATH.
  return npuDispatchShipsFor(
    os,
    androidHasFastRpc: os == 'android' && _androidHasFastRpc,
  );
}

/// Whether the FastRPC probe has run in this isolate. Lets a test prove it did
/// not run on a host where its answer is irrelevant.
@visibleForTesting
bool get fastRpcProbed => _fastRpcProbe != null;

/// The rule behind [hostShipsNpuDispatch], as a pure function.
///
/// Split out because `Platform.operatingSystem` has no override seam — `dart:io`'s
/// `IOOverrides` covers files, directories and sockets, not the platform — so the
/// Android and Windows arms are otherwise unreachable from a `flutter test` run
/// on a Mac, and a test can only restate the implementation back at itself.
bool npuDispatchShipsFor(
  String operatingSystem, {
  required bool androidHasFastRpc,
}) => switch (operatingSystem) {
  'windows' => true, // Per OS, knowingly too coarse — see hostShipsNpuDispatch.
  'android' => androidHasFastRpc,
  _ => false,
};

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

/// Why npu is not on offer here, worded per platform.
///
/// Android is its own case: the stack DOES ship there, in every arm64 build —
/// what is missing is the device's FastRPC. Saying "no NPU dispatch stack ships
/// for android" and then "NPU is available on Android" in one line was the
/// shape this replaced.
@visibleForTesting
String npuUnavailableReason(String operatingSystem, {String? fastRpcError}) =>
    operatingSystem == 'android'
    ? 'this device has no Qualcomm FastRPC (libcdsprpc.so did not open'
          '${fastRpcError == null ? '' : ': $fastRpcError'}), so the bundled '
          'NPU stack cannot run here'
    : 'no NPU dispatch stack ships for $operatingSystem';

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
/// Why CPU differs per encoder:
/// - VISION: its graph carries `STABLEHLO_COMPOSITE` ops the Metal (iOS/macOS)
///   and WebGPU (Windows/Linux) LiteRT delegates cannot prepare — it hard-fails
///   at `conversation_create` with no backend fallback (LiteRT-LM#2461, open
///   upstream). CPU is the mandatory-safe default (matching the vision
///   *adapter*, which LiteRT-LM already pins to CPU unconditionally).
/// - AUDIO: runs fine on either backend (verified on Metal); CPU is a
///   conservative default, but GPU is often faster (Gemma 3n audio ~2× CPU).
///
/// Both stay overridable: pass `PreferredBackend.gpu` for a vision model whose
/// section bakes a gpu-only `backend_constraint`, or for faster GPU audio.
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

/// Failure details for a single FFI backend initialization attempt.
class BackendInitAttemptFailure {
  const BackendInitAttemptFailure({
    required this.backend,
    required this.error,
    required this.stackTrace,
  });

  /// Backend used for this initialization attempt.
  final PreferredBackend backend;

  /// Error reported while initializing [backend].
  final Object error;

  /// Stack trace captured with [error].
  final StackTrace stackTrace;

  @override
  String toString() => '${ffiBackendWireName(backend)}: $error';
}

/// Exception thrown after every FFI backend fallback attempt fails.
class BackendInitException implements Exception {
  BackendInitException({required Iterable<BackendInitAttemptFailure> attempts})
    : attempts = List.unmodifiable(attempts) {
    if (this.attempts.isEmpty) {
      throw ArgumentError.value(
        attempts,
        'attempts',
        'must contain at least one failed backend attempt',
      );
    }
  }

  /// Failed backend attempts in the order they were tried.
  final List<BackendInitAttemptFailure> attempts;

  /// Last backend attempt, usually the most actionable failure.
  BackendInitAttemptFailure get lastAttempt => attempts.last;

  @override
  String toString() {
    final failures = attempts.map((attempt) => attempt.toString()).join('; ');
    return 'BackendInitException: all FFI backends failed. '
        'Last attempted ${ffiBackendWireName(lastAttempt.backend)}. '
        'Attempts: $failures';
  }
}

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
}) async {
  final attempts = <BackendInitAttemptFailure>[];
  final backends = ffiBackendFallbackOrder(
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
  if (preferredBackend == PreferredBackend.npu &&
      !backends.contains(PreferredBackend.npu)) {
    final reason = npuUnavailableReason(
      Platform.operatingSystem,
      fastRpcError: _fastRpcProbeError,
    );
    // ignore: avoid_print
    print(
      '[flutter_edge_ai] WARNING: $logTag npu was requested, but $reason — '
      'trying ${backends.map(ffiBackendWireName).join(" -> ")} instead. NPU '
      'runs on Qualcomm Snapdragon Android and on Windows (Intel '
      'LunarLake/PantherLake). InferenceModel.activeBackend names what '
      'actually ran.',
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
