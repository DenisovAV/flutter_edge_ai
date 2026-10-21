import 'package:genkit/genkit.dart';

import 'route_request.dart';

/// The port a classifier implements: given the request, a label or an
/// abstain. The policy's `labels` maps a label to a target, so a classifier
/// knows nothing about models.
///
/// genkit_flutter_edge_ai's `deciderRouteClassifier` implements it over an
/// on-device decider; an app can implement it over anything.
///
/// An abstract class rather than an interface, so a member can be added
/// later with a default without breaking implementations: always `extend`
/// it.
abstract class RouteClassifier {
  const RouteClassifier();

  /// Shown in the route info and the trace.
  String get name;

  /// Classifies [request]. Throw [RouteClassifierUnavailableException] when
  /// not ready (the policy's `onUnavailable` decides); any other throw fails
  /// the call — an error is never an abstain.
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  });
}

/// What a [RouteClassifier] answered.
sealed class RouteVerdict {
  const RouteVerdict({this.details = const {}});

  /// The classifier chose [label].
  const factory RouteVerdict.label(
    String label, {
    double? score,
    double? margin,
    Map<String, Object?> details,
  }) = LabelVerdict;

  /// The classifier fits none of its labels, for [reason].
  const factory RouteVerdict.abstain(
    String reason, {
    Map<String, Object?> details,
  }) = AbstainVerdict;

  /// Classifier-specific values for the route info and the trace. Must be
  /// JSON-encodable.
  final Map<String, Object?> details;
}

/// A classifier's choice.
final class LabelVerdict extends RouteVerdict {
  const LabelVerdict(this.label, {this.score, this.margin, super.details});

  final String label;

  /// How confident, higher is more confident; the classifier's own scale.
  final double? score;

  /// How clearly [label] won over the runner-up; finite or null.
  final double? margin;
}

/// A classifier that fits none of its labels.
final class AbstainVerdict extends RouteVerdict {
  const AbstainVerdict(this.reason, {super.details});

  final String reason;
}

/// Thrown by a classifier that cannot answer yet (still loading, replaced
/// while answering). The policy's `onUnavailable` decides; without it the
/// call fails.
final class RouteClassifierUnavailableException implements Exception {
  const RouteClassifierUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'RouteClassifierUnavailableException: $message';
}
