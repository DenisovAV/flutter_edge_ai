/// Where a rule, a pin or the router sends a request.
///
/// A [RouteDecision.prefer] may move: to the next target of the policy's
/// `fallback` after a transient failure, along the cascade, or to a capable
/// target when the chosen one lacks what the request needs. A
/// [RouteDecision.only] never moves, like Firebase AI Logic's
/// ONLY_ON_DEVICE / ONLY_IN_CLOUD modes: the call fails instead.
final class RouteDecision {
  /// Sends the request to [target], which may still move.
  const RouteDecision.prefer(this.target, {this.reason}) : isOnly = false;

  /// Sends the request to [target] and nowhere else.
  const RouteDecision.only(this.target, {this.reason}) : isOnly = true;

  /// A key of the router's `targets`.
  final String target;

  /// Whether the request must stay on [target].
  final bool isOnly;

  /// Why, for the route info and the trace.
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is RouteDecision &&
      other.target == target &&
      other.isOnly == isOnly &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(target, isOnly, reason);

  @override
  String toString() =>
      'RouteDecision.${isOnly ? 'only' : 'prefer'}($target'
      '${reason == null ? '' : ', reason: $reason'})';
}
