// Why a `.litertlm` LLM load failed, as the native engine reports it. Plain
// Dart, exported on every platform, so an app that catches them compiles for
// the web too (the web engine reports its own errors).

import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;

/// Failure details for a single backend initialization attempt.
class BackendInitAttemptFailure {
  const BackendInitAttemptFailure({
    required this.backend,
    required this.error,
    required this.stackTrace,
  });

  /// Backend used for this initialization attempt.
  final PreferredBackend backend;

  /// Error reported while initializing [backend]: a
  /// [LiteRtLmEngineCreateException] when the native engine refused it, a
  /// [NpuDispatchUnavailableException] when the NPU could not be reached.
  final Object error;

  /// Stack trace captured with [error].
  final StackTrace stackTrace;

  @override
  String toString() => '${backend.name}: $error';
}

/// Every backend the load tried failed: one attempt with
/// `LiteRtLmEngine(backendFallback: false)` or an NPU-compiled bundle, else one
/// per backend of the fallback order. [attempts] says why each failed.
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
    if (attempts.length == 1) {
      return 'BackendInitException: the model did not load on '
          '${lastAttempt.backend.name}: $failures';
    }
    return 'BackendInitException: all FFI backends failed. '
        'Last attempted ${lastAttempt.backend.name}. '
        'Attempts: $failures';
  }
}

/// The NPU cannot be reached on this device: no dispatch stack in the build,
/// no Qualcomm FastRPC or DSP on the device, or a dispatch directory that
/// could not be prepared. [message] says which.
class NpuDispatchUnavailableException implements Exception {
  const NpuDispatchUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'NpuDispatchUnavailableException: $message';
}

/// LiteRT-LM's `engine_create` returned no engine for a backend.
class LiteRtLmEngineCreateException implements Exception {
  const LiteRtLmEngineCreateException(
    this.message, {
    this.nativeCode,
    this.nativeMessage,
  });

  /// What failed and, when known, what to try.
  final String message;

  /// The status code LiteRT-LM reported for the failed create (its C API's
  /// last error), or null when it reported none.
  final int? nativeCode;

  /// LiteRT-LM's own message for the failed create, e.g. "Main backend
  /// constraint mismatch. Model requires one of [npu] but Main backend is
  /// gpu", or null when it reported none.
  final String? nativeMessage;

  @override
  String toString() => 'LiteRtLmEngineCreateException: $message';
}
