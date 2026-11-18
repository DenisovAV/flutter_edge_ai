// Why a `.litertlm` LLM load failed, as the native engine reports it. Plain
// Dart, exported on every platform, so an app that catches them compiles for
// the web too (the web engine reports its own errors).

import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;

import 'package:litertlm_dart/common.dart';

export 'package:litertlm_dart/common.dart'
    show LiteRtLmEngineCreateException, NpuDispatchUnavailableException;

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
