// The LLM engine's backend fallback: each backend of the load plan in turn,
// until one initializes, with the notices an app sees when its request could
// not be honoured. Adapter side: it throws core-facing BackendInitException
// (PreferredBackend) and names `InferenceModel.activeBackend`.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';

import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import '../litert_lm_load_errors.dart';
import 'runtime_mapping.dart';

String _wire(PreferredBackend backend) => ffiBackendWireName(backend.toRuntime);

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
  // An attempt whose failure means the backend is not there at all rather
  // than that it failed (an NPU this device cannot reach): with backends left
  // it is dropped with the notice a request that cannot be honoured gets,
  // and is no attempt; as the last one it is a failed attempt.
  bool Function(PreferredBackend backend, Object error)? skipAttempt,
  // An error no other backend can avoid: thrown as it is.
  bool Function(Object error)? isFatal,
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
      '${_wire(preferredBackend!)} was requested, but '
      '$fileReason — trying ${backends.map(_wire).join(" -> ")} '
      'instead. InferenceModel.activeBackend names what actually ran.',
    );
  } else if (preferredBackend == PreferredBackend.npu &&
      !backends.contains(PreferredBackend.npu)) {
    final reason =
        npuUnavailableBecause ?? npuNoVendorReason('${Abi.current()}');
    // ignore: avoid_print
    print(
      '[flutter_edge_ai] WARNING: $logTag npu was requested, but $reason — '
      'trying ${backends.map(_wire).join(" -> ")} instead. NPU '
      'runs on ${npuSentenceList(NpuStack.values.map(whereNpuRuns))}. '
      'InferenceModel.activeBackend names what actually ran.',
    );
  }

  for (final backend in backends) {
    final client = createClient();
    try {
      await initializeClient(client, backend);
      return (client: client, activeBackend: backend);
    } on Exception catch (error, stackTrace) {
      if (isFatal?.call(error) ?? false) {
        await shutdownClient(client);
        // An NPU an encoder needs, out of reach, whatever the text backend:
        // one NPU attempt that failed, as it always was.
        if (backend != PreferredBackend.npu &&
            error is NpuDispatchUnavailableException) {
          Error.throwWithStackTrace(
            BackendInitException(
              attempts: [
                BackendInitAttemptFailure(
                  backend: PreferredBackend.npu,
                  error: error,
                  stackTrace: stackTrace,
                ),
              ],
            ),
            stackTrace,
          );
        }
        rethrow;
      }
      if (backend != backends.last &&
          (skipAttempt?.call(backend, error) ?? false)) {
        await shutdownClient(client);
        final rest = backends.sublist(backends.indexOf(backend) + 1);
        // ignore: avoid_print
        print(
          '[flutter_edge_ai] WARNING: $logTag ${_wire(backend)} was requested, '
          'but ${error is NpuDispatchUnavailableException ? error.message : error} '
          '— trying ${rest.map(_wire).join(" -> ")} instead. NPU runs on '
          '${npuSentenceList(NpuStack.values.map(whereNpuRuns))}. '
          'InferenceModel.activeBackend names what actually ran.',
        );
        continue;
      }
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
        '$logTag ${_wire(backend)} backend failed: $error',
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
        '[flutter_edge_ai] WARNING: $logTag ${_wire(backend)} '
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
