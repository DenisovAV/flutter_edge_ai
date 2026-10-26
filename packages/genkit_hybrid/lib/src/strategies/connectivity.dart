import '../routing_context.dart';
import '../routing_strategy.dart';

/// Routes by network availability. The app supplies [isOnline]; the package
/// depends on no connectivity SDK.
@Deprecated('Use RouteRule.offline; removed in 0.5.0.')
class ConnectivityStrategy implements RoutingStrategy {
  ConnectivityStrategy({
    required this._isOnline,
    required this._online,
    required this._offline,
  });

  final bool Function() _isOnline;
  final String _online;
  final String _offline;

  @override
  List<String> route(RoutingContext context) => [
    _isOnline() ? _online : _offline,
  ];
}
