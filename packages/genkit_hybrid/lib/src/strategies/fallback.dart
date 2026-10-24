import '../routing_context.dart';
import '../routing_strategy.dart';

/// Returns a fixed priority order of branch keys. The factory tries each in
/// turn until one succeeds (e.g. `['onDevice','cloud']` = PREFER_ON_DEVICE).
@Deprecated('Use RoutePolicy.fallback; removed in 0.5.0.')
class FallbackStrategy implements RoutingStrategy {
  FallbackStrategy(List<String> order) : _order = List.unmodifiable(order) {
    // Throw (not assert) so the check also holds in release/AOT builds,
    // matching hybridModel's empty-branches guard.
    if (order.isEmpty) {
      throw ArgumentError.value(order, 'order', 'must not be empty');
    }
  }

  final List<String> _order;

  @override
  List<String> route(RoutingContext context) => _order;
}
