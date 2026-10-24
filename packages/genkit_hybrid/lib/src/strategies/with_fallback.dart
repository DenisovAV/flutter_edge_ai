import '../routing_context.dart';
import '../routing_strategy.dart';

/// Wraps an [inner] strategy and appends a fixed [fallbackOrder] tail to its
/// pick, turning a pure pick into pick + fallback. Keys already produced by
/// [inner] are not duplicated (inner order preserved, then remaining tail).
@Deprecated('Use RoutePolicy.fallback; removed in 0.5.0.')
class WithFallback implements RoutingStrategy {
  WithFallback(this._inner, {required List<String> fallbackOrder})
    : _fallbackOrder = List.unmodifiable(fallbackOrder);

  final RoutingStrategy _inner;
  final List<String> _fallbackOrder;

  @override
  List<String> route(RoutingContext context) {
    final result = <String>[..._inner.route(context)];
    for (final key in _fallbackOrder) {
      if (!result.contains(key)) result.add(key);
    }
    return List.unmodifiable(result);
  }
}
