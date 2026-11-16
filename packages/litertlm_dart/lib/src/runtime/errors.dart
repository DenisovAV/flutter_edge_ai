// Exceptions the runtime throws where the adapter throws a core exception
// instead: lib/src/adapter/runtime_mapping.dart maps each to its core
// counterpart at the boundary, so an app sees the same types as before.

/// An option-scoring run was cancelled. Core: `DeciderCancelledException`.
/// What every exception litertlm_dart throws for a LiteRT-LM failure
/// extends: one type to catch. Programming errors stay [ArgumentError] and
/// [StateError].
abstract class LiteRtLmException implements Exception {
  const LiteRtLmException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
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
