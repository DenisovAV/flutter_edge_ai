// The decider contract: pick one of N options for an input, or abstain.

import 'package:meta/meta.dart' show experimental, immutable;

import '../embedding/embedding_input.dart';
import '../embedding/embedding_modality.dart';
import '../message.dart';
import 'decider_exceptions.dart';
import 'decider_method.dart';
import 'decider_option.dart';
import 'embedding_decider.dart' show chooseAllWithSharedEmbeddings;

/// Picks one of its options for an input — or abstains when none fits.
///
/// Get one from a model: `EmbeddingModel.createDecider` (every embedding
/// backend) or `InferenceModel.createDecider` (engines that score options;
/// none does yet). A decider BORROWS its model and never closes it.
///
/// `abstract base`: outside core it can be extended (by a `base`, `final` or
/// `sealed` class) but not implemented, so a member added here in a later
/// release reaches every subclass through this class instead of breaking it.
/// Extend it for a decider of your own or a test fake — `final class
/// FakeDecider extends Decider` implementing [capabilities], [options],
/// [isClosed], [choose] and [close].
///
/// Experimental: the members may change in a minor release while the API
/// settles.
@experimental
abstract base class Decider {
  /// For subclasses.
  const Decider();

  /// What this decider can do.
  DeciderCapabilities get capabilities;

  /// The options, in the order they were given. Unmodifiable.
  List<DeciderOption> get options;

  /// The option for [input], or an abstention.
  ///
  /// [among] restricts the candidates to those option ids (unknown ids throw
  /// [ArgumentError]; an empty set abstains with
  /// [AbstainReason.noCandidates]). [topK] (≥ 1) caps
  /// [DeciderAnswer.ranked]; the margin and probabilities still cover every
  /// candidate.
  ///
  /// Errors arrive as a FAILED FUTURE: `DeciderUnsupportedException` for
  /// context this decider does not take, `DeciderSpaceMismatchException` when
  /// the embedder core now serves is in another embedding space, the model's
  /// own failures unchanged (`EmbedderClosedException`,
  /// `EmbeddingInputTooLongException` — an input is never truncated — …),
  /// [StateError] after [close].
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
  });

  /// The fitted decider as a JSON-encodable map, to be stored and given to
  /// `EmbeddingModel.loadDecider` later instead of fitting again. Versioned;
  /// the format is documented at https://flutteredge.ai/docs/decisions.
  /// Throws [StateError] when an option's metadata is not JSON-encodable.
  ///
  /// This default throws `DeciderUnsupportedException`: a decider with
  /// nothing to store (one implemented outside core, unless it overrides
  /// this) has no artifact.
  Map<String, Object?> toArtifact() => throw DeciderUnsupportedException(
    '$runtimeType has no artifact: it stores nothing that '
    'EmbeddingModel.loadDecider could restore.',
  );

  /// Whether [choose] can no longer answer: [close] was called, or — for an
  /// embedding decider — its model is closed and core serves none in its
  /// place (a model `getActiveEmbedder` did not build). A decider on a model
  /// core replaced is not closed: its next [choose] takes the replacement.
  bool get isClosed;

  /// Marks this decider closed; [choose] fails afterwards. Idempotent. The
  /// model the decider was created from stays open: it is borrowed.
  Future<void> close();

  /// Answers every one of [deciders] for the same [input], in their order.
  ///
  /// Deciders created from the same `EmbeddingModel` share ONE embedding of
  /// [input] — that is what this adds over calling [choose] on each: three
  /// deciders over one request cost one embedding, not three. Other deciders
  /// are asked one by one. Each answer's `provenance.embedTime` is the time
  /// of the embedding it used.
  ///
  /// The first failure fails the call.
  static Future<List<DeciderAnswer>> chooseAll(
    DeciderInput input,
    List<Decider> deciders, {
    int topK = 5,
  }) => chooseAllWithSharedEmbeddings(input, deciders, topK: topK);
}

/// What a decider is asked about: the [input] and, for deciders that read
/// one, the conversation so far.
@experimental
@immutable
final class DeciderInput {
  /// [context] is copied. An embedding decider takes none and fails with
  /// `DeciderUnsupportedException` when it is not empty, rather than
  /// ignoring it.
  DeciderInput(this.input, {List<Message> context = const []})
    : context = List.unmodifiable(context);

  /// The request to decide on: text, an image, audio — what the decider's
  /// `capabilities.modalities` lists.
  final EmbeddingInput input;

  /// Earlier turns, for deciders whose `capabilities.supportsContext` is
  /// true. Unmodifiable.
  final List<Message> context;
}

/// What a score in [DeciderAnswer.ranked] is.
///
/// A class with constant instances rather than an enum, as [DeciderMethod]
/// is, so a kind added in a later release does not break an app's
/// exhaustive `switch`.
@experimental
@immutable
final class ScoreKind {
  const ScoreKind._(this.name);

  /// Cosine similarity in [-1, 1] (the `centroid` method). Not a probability.
  static const cosine = ScoreKind._('cosine');

  /// Natural-log probability under the decider's own model, before any
  /// calibration (the `linear` method; option scoring by an LLM).
  static const logprob = ScoreKind._('logprob');

  /// Every kind this release knows, in declaration order.
  static const values = [cosine, logprob];

  /// Stable name: `cosine`, `logprob`.
  final String name;

  @override
  String toString() => 'ScoreKind.$name';
}

/// Why a decider abstained.
///
/// A class with constant instances rather than an enum, as [DeciderMethod]
/// is, so a reason added in a later release does not break an app's
/// exhaustive `switch`.
@experimental
@immutable
final class AbstainReason {
  const AbstainReason._(this.name);

  /// The request's abstain signal — its highest cosine to a candidate's
  /// centroid — is below the calibrated threshold: it fits none of them.
  static const belowThreshold = AbstainReason._('belowThreshold');

  /// `among` left no candidate.
  static const noCandidates = AbstainReason._('noCandidates');

  /// Every reason this release knows, in declaration order.
  static const values = [belowThreshold, noCandidates];

  /// Stable name: `belowThreshold`, `noCandidates`.
  final String name;

  @override
  String toString() => 'AbstainReason.$name';
}

/// One candidate of an answer.
@experimental
@immutable
final class RankedOption {
  const RankedOption({required this.id, required this.score, this.probability});

  /// The option's id.
  final String id;

  /// The raw score, of the answer's [DeciderAnswer.scoreKind]. Higher is
  /// better. Never a probability on its own.
  final double score;

  /// The calibrated probability, or null when the decider's probabilities are
  /// not calibrated.
  final double? probability;

  @override
  String toString() =>
      'RankedOption($id, $score${probability == null ? '' : ', p $probability'})';
}

/// Where an answer came from.
@experimental
@immutable
final class DeciderProvenance {
  const DeciderProvenance({
    required this.method,
    required this.calibration,
    required this.spaceId,
    required this.embedTime,
    required this.scoreTime,
    this.threshold,
    this.similarity,
  });

  /// How the options were scored.
  final DeciderMethod method;

  /// The calibration kind: `none`, `crossFit`, `minSimilarity` or
  /// `labelled`.
  final String calibration;

  /// The embedding space the decider works in: the model's identity, its
  /// dimension, its backend and the task prefix.
  final String spaceId;

  /// Time spent embedding the input (shared by `Decider.chooseAll`'s
  /// answers over one embedding).
  final Duration embedTime;

  /// Time spent scoring the candidates.
  final Duration scoreTime;

  /// The abstain threshold the signal was compared with; null when the
  /// decider never abstains.
  final double? threshold;

  /// The abstain signal: the input's highest cosine to a candidate's
  /// centroid. Null when there was no candidate.
  final double? similarity;
}

/// What a decider can do.
@experimental
@immutable
final class DeciderCapabilities {
  const DeciderCapabilities({
    required this.maxOptions,
    required this.supportsContext,
    required this.calibratedProbabilities,
    required this.modalities,
  });

  /// The most options it takes, or null for no limit of its own.
  final int? maxOptions;

  /// Whether `DeciderInput.context` is read.
  final bool supportsContext;

  /// Whether answers carry calibrated probabilities and a confidence.
  final bool calibratedProbabilities;

  /// What an input may carry.
  final Set<EmbeddingModality> modalities;
}

/// A decider's answer.
@experimental
@immutable
final class DeciderAnswer {
  /// For deciders implemented outside core (and test fakes). Lists are
  /// copied.
  ///
  /// Throws [ArgumentError] for an answer that contradicts itself: exactly
  /// one of [choice] and [abstainReason] is set; [choice] is the first of
  /// [ranked] when [ranked] is not empty; [ranked] is sorted by score,
  /// highest first; [confidence] is in [0, 1] and only given with
  /// [probabilities]; a [RankedOption.probability] equals that option's
  /// entry in [probabilities] when both are given.
  DeciderAnswer({
    required this.choice,
    required List<RankedOption> ranked,
    required this.scoreKind,
    required this.margin,
    required this.provenance,
    this.confidence,
    this.abstainReason,
    Map<String, double>? probabilities,
  }) : ranked = List.unmodifiable(ranked),
       probabilities = probabilities == null
           ? null
           : Map.unmodifiable(probabilities) {
    if ((choice == null) == (abstainReason == null)) {
      throw ArgumentError(
        'A DeciderAnswer has either a choice or an abstainReason, exactly '
        'one of them; got choice $choice, abstainReason $abstainReason.',
      );
    }
    if (choice != null && this.ranked.isNotEmpty) {
      if (this.ranked.first.id != choice) {
        throw ArgumentError.value(
          choice,
          'choice',
          'is not the best ranked option (${this.ranked.first.id})',
        );
      }
    }
    for (var i = 1; i < this.ranked.length; i++) {
      if (!(this.ranked[i - 1].score >= this.ranked[i].score)) {
        throw ArgumentError.value(
          this.ranked.map((r) => r.score).toList(),
          'ranked',
          'must be sorted by score, highest first',
        );
      }
    }
    final p = this.probabilities;
    if (confidence case final c?) {
      if (p == null) {
        throw ArgumentError.value(
          c,
          'confidence',
          'is only given with calibrated probabilities',
        );
      }
      if (!(c >= 0 && c <= 1)) {
        throw ArgumentError.value(c, 'confidence', 'must be in [0, 1]');
      }
    }
    if (p != null) {
      for (final r in this.ranked) {
        if (r.probability case final rp? when rp != p[r.id]) {
          throw ArgumentError.value(
            rp,
            'ranked',
            'option "${r.id}" has probability $rp, but probabilities says '
                '${p[r.id]}',
          );
        }
      }
    }
  }

  /// The chosen option's id, or null when the decider abstained.
  final String? choice;

  /// The best candidates, best first, at most `topK` of them. On a tie the
  /// option given first ranks first. Unmodifiable.
  final List<RankedOption> ranked;

  /// What the scores in [ranked] are.
  final ScoreKind scoreKind;

  /// Best score minus the runner-up's: how clearly the top candidate won.
  /// [double.infinity] with a single candidate, 0 with none.
  final double margin;

  /// Jev's confidence, `(N · pmax − 1) / (N − 1)` over the N candidates: 0
  /// for a uniform distribution, 1 when one option takes all. A spread
  /// measure, not an accuracy. Null unless probabilities are calibrated, and
  /// with fewer than two candidates.
  final double? confidence;

  /// Why the decider abstained; null when it chose.
  final AbstainReason? abstainReason;

  /// Every candidate's calibrated probability (they sum to 1), not only the
  /// ranked ones. Null unless the decider's probabilities are calibrated.
  final Map<String, double>? probabilities;

  /// Where this answer came from.
  final DeciderProvenance provenance;

  /// The answer in Jev's Choice answer shape, e.g.
  /// `{"type": "choice", "choice": "returns", "probabilities": {...},`
  /// `"confidence": 0.93}`. `probabilities`
  /// (every candidate, summing to 1) and `confidence` appear only when
  /// calibrated. Jev has no abstention: an abstained answer has
  /// `"choice": null`.
  Map<String, Object?> toJevJson() => {
    'type': 'choice',
    'choice': choice,
    if (probabilities case final p?) 'probabilities': {...p},
    'confidence': ?confidence,
  };

  @override
  String toString() =>
      'DeciderAnswer(${choice ?? 'abstained: ${abstainReason?.name}'}, '
      'margin $margin, ${ranked.join(', ')})';
}
