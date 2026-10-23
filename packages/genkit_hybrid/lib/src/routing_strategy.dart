import 'routing_context.dart';

/// Decides which branch(es) to try for a request.
@Deprecated(
  'Use RouteRule and RoutePolicy (defineHybridRouter); removed in 0.5.0.',
)
abstract class RoutingStrategy {
  /// Returns branch keys to try, in priority order.
  ///
  /// - A single-element list = a pure pick (pre-routing).
  /// - A multi-element list = pick + fallback.
  /// - An empty list = "no decision" (used by combinators such as
  ///   [FirstMatch] to signal "skip me, try the next strategy"). At the top
  ///   level the factory treats an empty result as a configuration error.
  List<String> route(RoutingContext context);
}
