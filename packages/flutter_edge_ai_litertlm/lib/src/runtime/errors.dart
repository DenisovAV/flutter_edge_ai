// Exceptions the runtime throws where the adapter throws a core exception
// instead: lib/src/adapter/runtime_mapping.dart maps each to its core
// counterpart at the boundary, so an app sees the same types as before.

/// An option-scoring run was cancelled. Core: `DeciderCancelledException`.
final class ScoringCancelledException implements Exception {
  const ScoringCancelledException(this.message);

  final String message;

  @override
  String toString() => 'ScoringCancelledException: $message';
}

/// LiteRT-LM refused a response constraint (a JSON schema LLGuidance cannot
/// compile). Core: `ResponseFormatUnsupportedException`.
final class ConstraintUnsupportedException implements Exception {
  const ConstraintUnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'ConstraintUnsupportedException: $message';
}
