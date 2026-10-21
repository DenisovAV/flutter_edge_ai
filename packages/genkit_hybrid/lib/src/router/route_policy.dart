import 'dart:async';

import 'package:genkit/genkit.dart';

import 'route_classifier.dart';
import 'route_decision.dart';
import 'route_rule.dart';

/// Judges a cascade attempt's result: true keeps it, false escalates to the
/// next target of the policy's `fallback`. Runs outside the router's
/// decision, so a judge that calls the router itself is routed on its own;
/// a cancel of the call ends the wait for it.
typedef CascadeCheck = FutureOr<bool> Function(GenerateResult result);

/// How a router decides. A router holds several, by name; a call picks one.
final class RoutePolicy {
  const RoutePolicy({
    this.rules = const [],
    this.classifier,
    this.labels = const {},
    this.onAbstain,
    this.onUnavailable,
    this.fallback = const [],
    this.cascade,
  });

  /// Run in order before the classifier; the first decision wins.
  final List<RouteRule> rules;

  /// Asked only when no rule decided.
  final RouteClassifier? classifier;

  /// Classifier label → decision. A label not in it fails the call. Map a
  /// label that must stay on the device to `RouteDecision.only(kOnDevice)`:
  /// a `prefer` may still move along [fallback].
  final Map<String, RouteDecision> labels;

  /// Where an abstain goes. Null: `RouteDecision.only(kOnDevice)`, which
  /// never moves; the router must then have a `kOnDevice` target.
  final RouteDecision? onAbstain;

  /// Where a request goes while the classifier is unavailable. Null: the
  /// call fails, so a classifier that never loads is not hidden.
  final RouteDecision? onUnavailable;

  /// Targets a `prefer` decision may move to, in order: when its target
  /// lacks a capability the request needs, when [cascade] rejects a result,
  /// or after a transient failure before any tool ran or chunk was sent. A
  /// failure moves the call to the cloud only when Genkit reports it as
  /// UNAVAILABLE, DEADLINE_EXCEEDED, RESOURCE_EXHAUSTED or UNIMPLEMENTED:
  /// INTERNAL and errors without a Genkit status are what a device bug or an
  /// over-long input raises on every request.
  final List<String> fallback;

  /// Judges each attempt but the last; null for no cascade.
  final CascadeCheck? cascade;
}

/// [policy] with its own unmodifiable copies of its collections. Not
/// exported.
RoutePolicy frozenPolicy(RoutePolicy policy) => RoutePolicy(
  rules: List.unmodifiable(policy.rules),
  classifier: policy.classifier,
  labels: Map.unmodifiable(policy.labels),
  onAbstain: policy.onAbstain,
  onUnavailable: policy.onUnavailable,
  fallback: List.unmodifiable(policy.fallback),
  cascade: policy.cascade,
);
