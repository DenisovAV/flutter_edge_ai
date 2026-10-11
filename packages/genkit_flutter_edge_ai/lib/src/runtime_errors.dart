import 'package:genkit/plugin.dart';

/// Runs a flutter_edge_ai call that loads or opens a model, and gives the
/// errors it is known to throw a Genkit status.
///
/// - [StateError] (no model installed, or none active) → UNAVAILABLE, so a
///   hybrid router falls back to another branch instead of reporting a bug;
/// - [UnsupportedError] (the engine cannot do what was asked) → UNIMPLEMENTED;
/// - [ArgumentError] → INVALID_ARGUMENT.
///
/// Anything else is rethrown as it is; Genkit reports it as INTERNAL.
Future<T> withRuntimeErrors<T>(String what, Future<T> Function() call) async {
  try {
    return await call();
  } on GenkitException {
    rethrow;
  } on StateError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: StatusCode.unavailable,
      cause: e,
      stackTrace: stack,
    );
  } on UnsupportedError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: StatusCode.unimplemented,
      cause: e,
      stackTrace: stack,
    );
  } on ArgumentError catch (e, stack) {
    throw GenkitException(
      '$what: ${e.message}',
      status: StatusCode.invalidArgument,
      cause: e,
      stackTrace: stack,
    );
  }
}
