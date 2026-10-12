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
