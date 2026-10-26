import 'dart:async';

import 'package:genkit/genkit.dart';

import 'route_info.dart';

/// Zone key of the routed call a refusal belongs to: set by the router's
/// entry points around their call, cleared inside a tool of one.
final Object _callKey = Object();

/// The router refused a call: a cloud model reached without the router
/// choosing it, a second router, an unknown label or target, an unavailable
/// classifier without `onUnavailable`, no capable target, the cloud refused
/// with no on-device target, a caller `config`.
///
/// `router.generate`, `generateStream` and a `HybridPrompt` throw it. A call
/// through plain `ai.generate` or a plain `Prompt` gets Genkit's `failed`
/// result instead, with this exception on `GenerateResult.cause`.
final class HybridRoutingException extends GenkitException {
  HybridRoutingException(
    super.message, {
    required super.status,
    super.cause,
    this.route,
  }) : _call = Zone.current[_callKey];

  /// How far the router got, when it had decided.
  final RouteInfo? route;

  /// The entry-point call it was made in, if any.
  final Object? _call;
}

/// Runs [body] as the routed call [call]: a refusal made inside it belongs
/// to [call]. Not exported.
R inRoutedCall<R>(Object call, R Function() body) =>
    runZoned(body, zoneValues: {_callKey: call});

/// Runs [body] outside any routed call, as a tool of one runs: a refusal
/// made there belongs to no entry point. Not exported.
R outsideRoutedCalls<R>(R Function() body) =>
    runZoned(body, zoneValues: {_callKey: null});

/// The refusal of [call] behind [error], looking through the `cause` of each
/// GenkitException on the way (a model action may wrap what it threw); null
/// when [call]'s router did not refuse. A refusal of another call, a
/// sub-agent's in a tool, is not [call]'s. Not exported.
HybridRoutingException? routingFailureOf(Object? error, Object call) {
  for (var e = error, depth = 0; e != null && depth < 8; depth++) {
    if (e is HybridRoutingException && identical(e._call, call)) return e;
    e = e is GenkitException ? e.cause : null;
  }
  return null;
}

/// [result], or [call]'s refusal thrown when [result] failed on one. Not
/// exported.
GenerateResult<O> checkedRoutingResult<O>(
  GenerateResult<O> result,
  Object call,
) {
  if (result.finishReason == FinishReason.failed) {
    final refusal = routingFailureOf(result.cause, call);
    if (refusal != null) throw refusal;
  }
  return result;
}
