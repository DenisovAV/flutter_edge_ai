import 'package:genkit/plugin.dart';

/// Runs a flutter_edge_ai call that loads, opens or feeds a model, and gives
/// the errors it is known to throw a Genkit status.
///
/// - [StateError]: UNAVAILABLE when [hasActiveModel] says nothing is
///   installed, so a hybrid router hands the request to another branch.
///   Otherwise FAILED_PRECONDITION: a model is there but cannot run as the
///   app set it up (no engine registered for it, say), and falling back to
///   another branch would hide that;
/// - [UnsupportedError] (the engine cannot do this here) → UNAVAILABLE: the
///   request may run elsewhere;
/// - [ArgumentError], except a [RangeError] → INVALID_ARGUMENT.
///
/// Anything else is rethrown as it is; Genkit reports it as INTERNAL.
Future<T> withRuntimeErrors<T>(
  String what,
  Future<T> Function() call, {
  required bool Function() hasActiveModel,
}) async {
  try {
    return await call();
  } on GenkitException {
    rethrow;
  } on StateError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: hasActiveModel()
          ? StatusCode.failedPrecondition
          : StatusCode.unavailable,
      cause: e,
      stackTrace: stack,
    );
  } on UnsupportedError catch (e, stack) {
    throw GenkitException(
      '$what: $e',
      status: StatusCode.unavailable,
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
