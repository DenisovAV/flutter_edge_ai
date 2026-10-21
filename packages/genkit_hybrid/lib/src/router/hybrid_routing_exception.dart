import 'package:genkit/genkit.dart';

import 'route_info.dart';

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
  });

  /// How far the router got, when it had decided.
  final RouteInfo? route;
}

/// The router's refusal behind [error], looking through the `cause` of each
/// GenkitException on the way (a model action may wrap what it threw); null
/// when the router did not refuse. Not exported.
HybridRoutingException? routingFailureOf(Object? error) {
  for (var e = error, depth = 0; e != null && depth < 8; depth++) {
    if (e is HybridRoutingException) return e;
    e = e is GenkitException ? e.cause : null;
  }
  return null;
}

/// [result], or the router's refusal thrown when [result] failed on one.
/// Not exported.
GenerateResult<O> checkedRoutingResult<O>(GenerateResult<O> result) {
  if (result.finishReason == FinishReason.failed) {
    final refusal = routingFailureOf(result.cause);
    if (refusal != null) throw refusal;
  }
  return result;
}
