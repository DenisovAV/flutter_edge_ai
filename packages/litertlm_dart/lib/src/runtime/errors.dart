// The base of litertlm_dart's exceptions, and two of them.
// flutter_edge_ai_litertlm maps each to its core counterpart at the boundary
// (lib/src/adapter/runtime_mapping.dart).

/// What every exception litertlm_dart throws for a LiteRT-LM failure
/// extends: one type to catch. Programming errors stay [ArgumentError] and
/// [StateError].
abstract base class LiteRtLmException implements Exception {
  const LiteRtLmException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// An option-scoring run was cancelled. Core: `DeciderCancelledException`.
/// A LiteRT-LM call failed: [message] names the call and native's status.
/// Kotlin's `LiteRtLmJniException`.
final class LiteRtLmNativeException extends LiteRtLmException {
  const LiteRtLmNativeException(super.message);

  @override
  String toString() => 'LiteRtLmNativeException: $message';
}

final class ScoringCancelledException extends LiteRtLmException {
  const ScoringCancelledException(super.message);

  @override
  String toString() => 'ScoringCancelledException: $message';
}

/// LiteRT-LM refused a response constraint (a JSON schema LLGuidance cannot
/// compile). Core: `ResponseFormatUnsupportedException`.
final class ConstraintUnsupportedException extends LiteRtLmException {
  const ConstraintUnsupportedException(super.message);

  @override
  String toString() => 'ConstraintUnsupportedException: $message';
}
