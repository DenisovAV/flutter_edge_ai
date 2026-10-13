// The failures of the decider API that are not argument errors. Every
// asynchronous decider method delivers them as a FAILED FUTURE.

import 'package:meta/meta.dart' show experimental;

/// Common base of every decider failure. Not sealed, so a later kind of
/// failure is an additive change; catch this to handle them all.
///
/// Argument errors (an unknown option id in `among`, duplicate option ids, a
/// calibration the options cannot support) are [ArgumentError]s, and a
/// malformed artifact is a [FormatException]: those are bugs in the calling
/// code or in the stored data, not states of the decider.
@experimental
abstract base class DeciderException implements Exception {
  const DeciderException(this.message);

  /// What happened, in words meant for a developer.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The decider, or the model asked for one, cannot do what was asked — for
/// example an `InferenceModel` that does not score options, or a decider that
/// takes no conversation context given some.
///
/// Check `Decider.capabilities` to avoid it.
@experimental
final class DeciderUnsupportedException extends DeciderException {
  const DeciderUnsupportedException(super.message);
}

/// A stored decider was fitted in another embedding space than the embedder
/// asked to load it: another model file, dimension, backend or task prefix.
///
/// Vectors from two spaces are not comparable (an NPU bundle's vectors sit at
/// cosine 0.8–0.9 to the CPU file's), so the artifact is refused instead of
/// silently giving wrong answers. Fit the decider again on this embedder.
@experimental
final class DeciderSpaceMismatchException extends DeciderException {
  const DeciderSpaceMismatchException(
    super.message, {
    required this.expected,
    required this.actual,
  });

  /// The space the artifact was fitted in.
  final String expected;

  /// The space of the embedder that was asked to load it.
  final String actual;
}
