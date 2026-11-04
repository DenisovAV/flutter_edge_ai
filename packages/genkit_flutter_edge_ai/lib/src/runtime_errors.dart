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

/// [error], a typed-response failure, as a Genkit error. The status says
/// whether genkit_hybrid hands the request to its next branch (its
/// `isTransient`: UNAVAILABLE, DEADLINE_EXCEEDED, RESOURCE_EXHAUSTED,
/// INTERNAL and UNIMPLEMENTED; a router moves a call to a cloud target on
/// all of them but INTERNAL):
///
/// - [gemma.ResponseFormatUnsupportedException] → UNIMPLEMENTED. Only a
///   refusal the engine finds once the turn runs gets here (LiteRT-LM's
///   compiler rejecting a schema at the first send): one known when the chat
///   opens sends the schema in the prompt instead. A model that cannot
///   enforce the schema is a capability gap, as a request with tools on a
///   model configured without them is;
/// - [gemma.IncompleteStructuredOutputException] by its end:
///   - [gemma.TurnEnd.outputLimit] → OUT_OF_RANGE, not transient: the
///     request's own `maxOutputTokens` cut the value, and only a larger one
///     fixes it;
///   - [gemma.TurnEnd.contextLimit] → RESOURCE_EXHAUSTED: this model's
///     context window is full, and a model with a larger one may take it;
///   - [gemma.TurnEnd.closed] → UNAVAILABLE: the model was closed or
///     replaced under the turn, as when none is loaded;
///   - [gemma.TurnEnd.stopped] → ABORTED, not transient. A stop the caller
///     asked for is reported as Genkit's cancel before it gets here;
/// - [gemma.NonConformingStructuredOutputException] → INTERNAL: the engine
///   accepted a format it did not enforce, an engine bug. A fallback or
///   cascade model tries its next branch; a router does not move the call
///   to the cloud.
///
/// The core exception is the [GenkitException.cause], with the partial or
/// non-conforming text on it.
GenkitException structuredOutputError(
  String what,
  gemma.StructuredOutputException error,
  StackTrace stack,
) {
  final status = switch (error) {
    gemma.ResponseFormatUnsupportedException() => StatusCode.unimplemented,
    gemma.IncompleteStructuredOutputException(:final end) => switch (end) {
      gemma.TurnEnd.outputLimit => StatusCode.outOfRange,
      gemma.TurnEnd.contextLimit => StatusCode.resourceExhausted,
      gemma.TurnEnd.closed => StatusCode.unavailable,
      gemma.TurnEnd.stopped => StatusCode.aborted,
      // Core never ends an incomplete value this way.
      gemma.TurnEnd.endOfSequence => StatusCode.internal,
    },
    gemma.NonConformingStructuredOutputException() => StatusCode.internal,
  };
  return GenkitException(
    '$what: $error',
    status: status,
    cause: error,
    stackTrace: stack,
  );
}
