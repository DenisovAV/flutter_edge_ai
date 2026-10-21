import 'dart:async';

import 'package:genkit/genkit.dart';

/// What made the router's first decision.
///
/// A class with constant instances rather than an enum, so a source added
/// later does not break an app's exhaustive `switch`.
final class RouteSource {
  const RouteSource._(this.name);

  /// The call's `pin`.
  static const pin = RouteSource._('pin');

  /// The decision stamped on the interrupted message a resume answers (or
  /// the on-device default when it has none).
  static const resume = RouteSource._('resume');

  /// A rule of the policy.
  static const rule = RouteSource._('rule');

  /// The classifier's label.
  static const classifier = RouteSource._('classifier');

  /// The classifier abstained; the policy's `onAbstain`.
  static const abstain = RouteSource._('abstain');

  /// The classifier was unavailable; the policy's `onUnavailable`.
  static const unavailable = RouteSource._('unavailable');

  /// `confirmCloud` refused the cloud for a `prefer` decision; the
  /// on-device target.
  static const consentRefused = RouteSource._('consentRefused');

  /// Every source this release knows.
  static const values = [
    pin,
    resume,
    rule,
    classifier,
    abstain,
    unavailable,
    consentRefused,
  ];

  /// Stable name, as in the route info's JSON.
  final String name;

  /// The source named [name]; one this release does not know (written by a
  /// later one) is kept by its name.
  static RouteSource _byName(String name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return RouteSource._(name);
  }

  @override
  String toString() => 'RouteSource.$name';
}

/// How the router routed a call: on `GenerateResult.custom['hybrid']`, on a
/// [HybridRoutingException], and as the output of the `hybrid/route` span.
final class RouteInfo {
  const RouteInfo({
    required this.router,
    required this.policy,
    required this.target,
    required this.model,
    required this.source,
    required this.routeTime,
    this.attempts = const [],
    this.rule,
    this.classifier,
    this.label,
    this.score,
    this.margin,
    this.abstainReason,
    this.reason,
    this.details = const {},
  });

  /// The router's name.
  final String router;

  /// The policy's name.
  final String policy;

  /// The target key that produced the result (the last attempt).
  final String target;

  /// The model name behind [target].
  final String model;

  /// What made the first decision.
  final RouteSource source;

  /// Time spent deciding, classifier and consent included.
  final Duration routeTime;

  /// The targets tried, in order: one entry unless a fallback or a cascade
  /// moved the call.
  final List<String> attempts;

  /// The rule that decided, for [RouteSource.rule].
  final String? rule;

  /// The classifier asked, if one was.
  final String? classifier;

  /// The classifier's label.
  final String? label;

  /// The classifier's score.
  final double? score;

  /// The classifier's margin.
  final double? margin;

  /// The classifier's abstain reason.
  final String? abstainReason;

  /// The deciding rule's or pin's reason, or why the call moved.
  final String? reason;

  /// The classifier's details.
  final Map<String, Object?> details;

  RouteInfo copyWith({
    String? target,
    String? model,
    RouteSource? source,
    Duration? routeTime,
    List<String>? attempts,
    String? reason,
  }) => RouteInfo(
    router: router,
    policy: policy,
    target: target ?? this.target,
    model: model ?? this.model,
    source: source ?? this.source,
    routeTime: routeTime ?? this.routeTime,
    attempts: attempts ?? this.attempts,
    rule: rule,
    classifier: classifier,
    label: label,
    score: score,
    margin: margin,
    abstainReason: abstainReason,
    reason: reason ?? this.reason,
    details: details,
  );

  Map<String, Object?> toJson() => {
    'router': router,
    'policy': policy,
    'target': target,
    'model': model,
    'source': source.name,
    'routeMs': routeTime.inMicroseconds / 1000,
    'attempts': attempts,
    'rule': ?rule,
    'classifier': ?classifier,
    'label': ?label,
    'score': ?score,
    'margin': ?margin,
    'abstainReason': ?abstainReason,
    'reason': ?reason,
    if (details.isNotEmpty) 'details': details,
  };

  /// Reads [toJson]'s output; null when [json] is not one. An optional
  /// field of the wrong type reads as absent.
  static RouteInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final source = json['source'];
    final router = json['router'];
    final policy = json['policy'];
    final target = json['target'];
    final model = json['model'];
    if (source is! String ||
        router is! String ||
        policy is! String ||
        target is! String ||
        model is! String) {
      return null;
    }
    String? text(String key) => switch (json[key]) {
      final String v => v,
      _ => null,
    };
    double? number(String key) => switch (json[key]) {
      final num v => v.toDouble(),
      _ => null,
    };
    final ms = number('routeMs');
    return RouteInfo(
      router: router,
      policy: policy,
      target: target,
      model: model,
      source: RouteSource._byName(source),
      routeTime: Duration(microseconds: ms == null ? 0 : (ms * 1000).round()),
      attempts: List.unmodifiable([
        if (json['attempts'] case final List attempts)
          for (final a in attempts)
            if (a is String) a,
      ]),
      rule: text('rule'),
      classifier: text('classifier'),
      label: text('label'),
      score: number('score'),
      margin: number('margin'),
      abstainReason: text('abstainReason'),
      reason: text('reason'),
      details: switch (json['details']) {
        final Map d => Map.unmodifiable({
          for (final MapEntry(:key, :value) in d.entries)
            if (key is String) key: value,
        }),
        _ => const {},
      },
    );
  }

  @override
  String toString() => 'RouteInfo(${toJson()})';
}

/// The key of [RouteInfo] in `GenerateResult.custom`.
const kHybridRouteKey = 'hybrid';

extension HybridGenerateResult on GenerateResult {
  /// How the router routed this call; null when no router did.
  RouteInfo? get route => RouteInfo.fromJson(custom?[kHybridRouteKey]);
}

/// What `confirmCloud` is asked about.
final class CloudConsentRequest {
  const CloudConsentRequest({
    required this.target,
    required this.model,
    required this.route,
  });

  /// The cloud target key.
  final String target;

  /// Its model name.
  final String model;

  /// The decision so far.
  final RouteInfo route;
}

/// Asked once per call for each cloud target it is about to use (a resume
/// included), outside the router's decision; a cancel of the call ends the
/// wait. False on the decided target keeps a `prefer` call on the device
/// when the router has a `kOnDevice` target, and fails a pin, an `only`
/// decision and a router without that target; false on a fallback target
/// skips it.
typedef CloudConsent = FutureOr<bool> Function(CloudConsentRequest request);
