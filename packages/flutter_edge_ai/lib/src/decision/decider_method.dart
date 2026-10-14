// How a decider scores options, and how it decides when to abstain.

import 'package:meta/meta.dart' show experimental, immutable;

import '../embedding/embedding_input.dart';

/// How an embedding decider scores a request against its options.
///
/// A class with constant instances rather than an enum, so a method added in a
/// later release does not break an app's exhaustive `switch`.
@experimental
@immutable
final class DeciderMethod {
  const DeciderMethod._(this.name);

  /// Cosine between the request and each option's centroid — the normalised
  /// mean of the option's example (and description) embeddings. No fitting:
  /// options can come from descriptions alone (zero-shot).
  ///
  /// Measured on CLINC150 (150 options) with EmbeddingGemma 2: 1.1–1.4 points
  /// below [linear] at 5–30 examples per option, level on HWU64 (64 options).
  static const centroid = DeciderMethod._('centroid');

  /// Softmax regression on the frozen embeddings, fitted on the options'
  /// inputs when the decider is created, with L2 weight decay fixed at 1e-5
  /// (the value held-out rows and cross-fitting both picked in the
  /// measurements). Ranks by the regression's log-probability.
  ///
  /// The best measured method at 5–30 examples per option. Needs at least two
  /// options. Fitting costs time that grows with options × inputs and memory
  /// of about 2 · 20 · (dimension · options + options) · 8 bytes for the
  /// optimiser's history (37 MB at 768 × 150, ~0.5 GB at 2000 options).
  /// Natively it runs on an isolate of its own, which a cancel kills; on web
  /// it runs on the page's thread in slices of a few milliseconds, yielding
  /// to the event loop between them. Measured fit times:
  /// https://flutteredge.ai/docs/decisions.
  static const linear = DeciderMethod._('linear');

  /// Stable name, also used in artifacts: `centroid`, `linear`.
  final String name;

  @override
  String toString() => 'DeciderMethod.$name';
}

/// The method named [name], or null for a name this release does not know.
/// Not exported.
DeciderMethod? deciderMethodByName(String name) => switch (name) {
  'centroid' => DeciderMethod.centroid,
  'linear' => DeciderMethod.linear,
  _ => null,
};

/// How a decider decides to abstain ("none of these"), and whether its
/// probabilities are calibrated.
///
/// The abstain signal of an embedding decider is the request's highest cosine
/// to an option centroid, not a softmax probability: with few options any
/// request looks confident to a softmax (measured: it rejects 2.7–21.7 % of
/// out-of-scope requests at 2–20 options), while the cosine rejects 87–99 %.
@experimental
@immutable
final class DeciderCalibration {
  /// Never abstain: every request gets the best-scoring option.
  const DeciderCalibration.none()
    : kind = 'none',
      keep = null,
      threshold = null,
      maxError = null,
      _labelled = null;

  /// The default. The threshold comes from the options' own inputs: a 5-fold
  /// cross-fit (input `i` of each option is in fold `i % 5`), each held-out
  /// input scored against the centroids of the other folds, and the threshold
  /// set to keep [keep] of those held-out scores.
  ///
  /// No labelled data needed. Measured with EmbeddingGemma 2 at 2–20 options
  /// and 10 examples each: 90–94 % of in-scope requests answered and 87–99 %
  /// of out-of-scope requests refused — which requests are answered depends
  /// on the threshold alone, the same for both methods. The error on the
  /// answered ones was measured with [DeciderMethod.linear] only: ≤ 0.8 %
  /// there, and 6.8 % at 150 options with 5 examples, over a 5 % budget (use
  /// [DeciderCalibration.fromLabelled] there). The default
  /// [DeciderMethod.centroid] is less accurate, so its error on answered
  /// requests is higher; it was not measured.
  ///
  /// Needs at least two inputs (description plus examples) per option; a
  /// zero-shot option set takes [DeciderCalibration.minSimilarity] or
  /// [DeciderCalibration.none]. [keep] must be in (0, 1].
  const DeciderCalibration.crossFit({double this.keep = 0.95})
    : kind = 'crossFit',
      threshold = null,
      maxError = null,
      _labelled = null;

  /// A fixed threshold on the request's highest cosine to an option centroid.
  ///
  /// It belongs to one model file and one prompt, not to the API: 0.875 was
  /// measured for EmbeddingGemma 2 int4 text 270m with the decider's prompt
  /// (CLINC150, 5–10 examples per option); another embedder needs its own
  /// value. [threshold] must be in [-1, 1].
  const DeciderCalibration.minSimilarity(double this.threshold)
    : kind = 'minSimilarity',
      keep = null,
      maxError = null,
      _labelled = null;

  /// Calibration on held-out labelled requests, which must not repeat the
  /// options' own examples.
  ///
  /// The decider embeds [labelled] once at creation and fits:
  /// - the abstain threshold: the lowest cosine at which the labelled rows
  ///   answered at or above it (rows of one cosine together) keep their
  ///   error within [maxError];
  /// - a softmax temperature, by negative log-likelihood on a grid of 241
  ///   values from 1e-3 to 10 — the decider then reports calibrated
  ///   probabilities and a confidence.
  ///
  /// `createDecider` fails with [ArgumentError] when no threshold keeps the
  /// error within [maxError], and when the best temperature is an end of the
  /// grid: rows all answered right with room to spare (1e-3) — which would
  /// report a near-tie as certain — or all answered poorly (10) cannot
  /// calibrate. Give it real held-out requests, some of them hard; one row
  /// is never enough.
  ///
  /// [maxError] must be in [0, 1). Every `optionId` must name an option.
  /// [labelled] is copied: a later change to the caller's list does not
  /// reach the calibration.
  DeciderCalibration.fromLabelled(
    List<({EmbeddingInput input, String optionId})> labelled, {
    double this.maxError = 0.05,
  }) : kind = 'labelled',
       keep = null,
       threshold = null,
       _labelled = List.unmodifiable(labelled);

  /// `none`, `crossFit`, `minSimilarity` or `labelled`.
  final String kind;

  /// The share of held-out inputs a [DeciderCalibration.crossFit] keeps.
  final double? keep;

  /// The fixed threshold of [DeciderCalibration.minSimilarity].
  final double? threshold;

  /// The error budget of [DeciderCalibration.fromLabelled].
  final double? maxError;

  final List<({EmbeddingInput input, String optionId})>? _labelled;

  @override
  String toString() => switch (kind) {
    'crossFit' => 'DeciderCalibration.crossFit(keep: $keep)',
    'minSimilarity' => 'DeciderCalibration.minSimilarity($threshold)',
    'labelled' =>
      'DeciderCalibration.fromLabelled(${_labelled?.length} rows, '
          'maxError: $maxError)',
    _ => 'DeciderCalibration.none()',
  };
}

/// The labelled rows of a [DeciderCalibration.fromLabelled], for the decider
/// that fits them. Not exported.
List<({EmbeddingInput input, String optionId})>? labelledRowsOf(
  DeciderCalibration calibration,
) => calibration._labelled;
