import 'hybrid_target.dart' show kOnDevice;
import 'route_decision.dart';
import 'route_request.dart';

/// A synchronous routing rule. A policy runs its rules in order before its
/// classifier; the first that returns a decision wins, and null means "no
/// decision, ask the next".
///
/// Deterministic constraints belong here, not in a classifier: what must
/// stay on the device, what cannot run offline, what is too long. Each
/// built-in names the 0.3 strategy it replaces.
///
/// An `abstract base class`, so a member can be added later with a default
/// without breaking a rule: extend it, as a `final` or `base` class, or use
/// [RouteRule.custom].
abstract base class RouteRule {
  const RouteRule();

  /// Any app rule: [decide] returns a decision or null. Was
  /// `PreRoutingStrategy`.
  factory RouteRule.custom(
    String name,
    RouteDecision? Function(RouteRequest request) decide,
  ) = _CustomRule;

  /// While [isOnline] is false, `only` [to]; online, no decision. Was
  /// `ConnectivityStrategy`. The app supplies the signal; this package
  /// depends on no connectivity SDK.
  factory RouteRule.offline({required bool Function() isOnline, String to}) =
      _OfflineRule;

  /// A request whose text is at most [maxChars] characters goes to [small],
  /// a longer one to [large], both `prefer`. Was `InputSizeStrategy`. It
  /// counts characters, not tokens.
  factory RouteRule.inputSize({
    required int maxChars,
    required String small,
    required String large,
  }) = _InputSizeRule;

  /// While [available] says the budget holds, `prefer` [premium] (put
  /// [cheap] in the policy's `fallback` to fall back to it); spent, `only`
  /// [cheap]. Was `CostStrategy`. The app owns budget accounting.
  factory RouteRule.budget({
    required bool Function() available,
    required String premium,
    required String cheap,
  }) = _BudgetRule;

  /// Shown in the route info and the trace.
  String get name;

  /// The decision for [request], or null for none.
  RouteDecision? decide(RouteRequest request);
}

final class _CustomRule extends RouteRule {
  const _CustomRule(this.name, this._decide);

  @override
  final String name;
  final RouteDecision? Function(RouteRequest request) _decide;

  @override
  RouteDecision? decide(RouteRequest request) => _decide(request);
}

final class _OfflineRule extends RouteRule {
  const _OfflineRule({required this.isOnline, this.to = kOnDevice});

  final bool Function() isOnline;
  final String to;

  @override
  String get name => 'offline';

  @override
  RouteDecision? decide(RouteRequest request) =>
      isOnline() ? null : RouteDecision.only(to, reason: 'offline');
}

final class _InputSizeRule extends RouteRule {
  _InputSizeRule({
    required this.maxChars,
    required this.small,
    required this.large,
  }) {
    if (maxChars < 0) {
      throw ArgumentError.value(maxChars, 'maxChars', 'must not be negative');
    }
  }

  final int maxChars;
  final String small;
  final String large;

  @override
  String get name => 'inputSize';

  @override
  RouteDecision? decide(RouteRequest request) => request.textLength > maxChars
      ? RouteDecision.prefer(large, reason: 'over $maxChars characters')
      : RouteDecision.prefer(small, reason: 'at most $maxChars characters');
}

final class _BudgetRule extends RouteRule {
  const _BudgetRule({
    required this.available,
    required this.premium,
    required this.cheap,
  });

  final bool Function() available;
  final String premium;
  final String cheap;

  @override
  String get name => 'budget';

  @override
  RouteDecision? decide(RouteRequest request) => available()
      ? RouteDecision.prefer(premium, reason: 'budget available')
      : RouteDecision.only(cheap, reason: 'budget spent');
}

/// The target keys a built-in rule can name, so the router can check them
/// when it is defined; null for a custom rule, whose decisions are checked
/// when it makes them. Not exported.
Set<String>? builtInRuleTargets(RouteRule rule) => switch (rule) {
  _OfflineRule(:final to) => {to},
  _InputSizeRule(:final small, :final large) => {small, large},
  _BudgetRule(:final premium, :final cheap) => {premium, cheap},
  _ => null,
};
