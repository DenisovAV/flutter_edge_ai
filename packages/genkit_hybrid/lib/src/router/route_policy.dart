import 'dart:async';

import 'package:genkit/genkit.dart';

import 'route_classifier.dart';
import 'route_rule.dart';

/// Judges a cascade attempt's result: true keeps it, false escalates to the
/// next target of the policy's `fallback`. Runs outside the router's
/// decision, so a judge that calls the router itself is routed on its own.
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

  /// Classifier label → target key. A label not in it fails the call.
  final Map<String, String> labels;

  /// Where an abstain goes. Null: the `kOnDevice` target, which the router
  /// must then have.
  final String? onAbstain;

  /// Where a request goes while the classifier is unavailable. Null: the
  /// call fails, so a classifier that never loads is not hidden.
  final String? onUnavailable;

  /// Targets tried in order after a `prefer` decision fails transiently on
  /// the first turn, or when the chosen target lacks a capability the
  /// request needs, or when [cascade] rejects a result.
  final List<String> fallback;

  /// Judges each attempt but the last; null for no cascade.
  final CascadeCheck? cascade;
}
