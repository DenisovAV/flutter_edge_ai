import '../routing_context.dart';
import '../routing_strategy.dart';

/// Budget-gates a paid [premium] branch against an app-supplied signal, falling
/// back to a free [cheap] branch. The app owns budget accounting (running
/// spend, per-session cap, daily quota) and reduces it to one bool; this
/// package depends on no billing SDK.
///
/// While the budget holds, returns `[premium, cheap]` — premium, with the free
/// branch as a transient-failure fallback (premium can fail and fall through to
/// free; there is nothing to fall back to from free, so a spent budget returns
/// `[cheap]` alone). A request-aware cost *estimator* is a deferred, different
/// strategy — keep the signal a bare `bool Function()`.
@Deprecated('Use RouteRule.budget; removed in 0.5.0.')
class CostStrategy implements RoutingStrategy {
  CostStrategy({
    required this._budgetAvailable,
    required this._premium,
    required this._cheap,
  });

  final bool Function() _budgetAvailable;
  final String _premium;
  final String _cheap;

  @override
  List<String> route(RoutingContext context) =>
      _budgetAvailable() ? [_premium, _cheap] : [_cheap];
}
