import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

/// Runs a flutter_edge_ai call that loads, opens or feeds a model, and gives
/// the errors it is known to throw a Genkit status.
///
/// - [gemma.NoActiveModelError] (nothing installed yet) → UNAVAILABLE, so a
///   hybrid router hands the request to another branch;
/// - any other [StateError] → FAILED_PRECONDITION: a model is there but cannot
///   run as the app set it up (no engine registered for it, say), and falling
///   back to another branch would hide that;
/// - [UnsupportedError] (this engine or platform cannot do what was asked) →
///   UNIMPLEMENTED, which a hybrid router also hands to its next branch;
/// - [ArgumentError], except a [RangeError] → INVALID_ARGUMENT.
///
/// Anything else is rethrown as it is; Genkit reports it as INTERNAL.
Future<T> withRuntimeErrors<T>(String what, Future<T> Function() call) async {
  try {
    return await call();
  } on GenkitException {
    rethrow;
  } on gemma.NoActiveModelError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: StatusCode.unavailable,
      cause: e,
      stackTrace: stack,
    );
  } on StateError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: StatusCode.failedPrecondition,
      cause: e,
      stackTrace: stack,
    );
  } on UnsupportedError catch (e, stack) {
    throw GenkitException(
      '$what: $e',
      status: StatusCode.unimplemented,
      cause: e,
      stackTrace: stack,
    );
  } on RangeError {
    // An index out of range is a bug, not the caller's argument.
    rethrow;
  } on ArgumentError catch (e, stack) {
    throw GenkitException(
      '$what: $e',
      status: StatusCode.invalidArgument,
      cause: e,
      stackTrace: stack,
    );
  }
}

/// [error], a typed-response failure, as a Genkit error.
///
/// None of these statuses moves the request off the device: genkit_hybrid's
/// router moves a call to a cloud target on UNAVAILABLE, DEADLINE_EXCEEDED,
/// RESOURCE_EXHAUSTED and UNIMPLEMENTED, and its deprecated `hybridModel`,
/// `hybridModelOnDeviceCloud` and `cascadeModel` (`isTransient`) on those and
/// INTERNAL. A reply that failed its schema here is this model's, and would
/// fail the same way again; sending the prompt to the cloud instead is the
/// app's decision, not a side effect of a status.
///
/// - [gemma.IncompleteStructuredOutputException] by its end:
///   - [gemma.TurnEnd.outputLimit] and [gemma.TurnEnd.contextLimit] →
///     OUT_OF_RANGE: the request's `maxOutputTokens` or the model's context
///     window cut the value. A plain turn that fills either ends normally
///     and stays local too;
///   - [gemma.TurnEnd.closed] → ABORTED: the model was closed or replaced
///     under the turn, which fails a plain turn locally as well;
///   - [gemma.TurnEnd.stopped] → ABORTED. A turn the caller's cancel ended
///     is reported as Genkit's cancel before it gets here;
/// - [gemma.NonConformingStructuredOutputException] → FAILED_PRECONDITION:
///   the engine accepted a format it did not enforce, an engine bug, as a
///   `refusalFor` that throws is;
/// - [gemma.ResponseFormatUnsupportedException] → FAILED_PRECONDITION. A
///   refusal at the first send runs the request again prompt-only, so this
///   is reported only when that cannot happen: a chunk already reached the
///   caller.
///
/// The core exception is the [GenkitException.cause], with the partial or
/// non-conforming text on it.
GenkitException structuredOutputError(
  String what,
  gemma.StructuredOutputException error,
  StackTrace stack,
) {
  final status = switch (error) {
    gemma.ResponseFormatUnsupportedException() => StatusCode.failedPrecondition,
    gemma.IncompleteStructuredOutputException(:final end) => switch (end) {
      gemma.TurnEnd.outputLimit ||
      gemma.TurnEnd.contextLimit => StatusCode.outOfRange,
      gemma.TurnEnd.closed || gemma.TurnEnd.stopped => StatusCode.aborted,
      // Core never ends an incomplete value this way.
      gemma.TurnEnd.endOfSequence => StatusCode.internal,
    },
    gemma.NonConformingStructuredOutputException() =>
      StatusCode.failedPrecondition,
  };
  return GenkitException(
    '$what: $error',
    status: status,
    cause: error,
    stackTrace: stack,
  );
}
