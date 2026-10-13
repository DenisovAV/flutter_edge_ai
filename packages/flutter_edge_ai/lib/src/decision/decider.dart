// The decider contract: pick one of N options for an input, or abstain.

import 'package:meta/meta.dart' show experimental, immutable;

import '../embedding/embedding_input.dart';
import '../embedding/embedding_modality.dart';
import '../message.dart';
import 'decider_method.dart';
import 'decider_option.dart';
import 'embedding_decider.dart' show chooseAllWithSharedEmbeddings;

/// Picks one of its options for an input — or abstains when none fits.
///
/// Get one from a model: `EmbeddingModel.createDecider` (every embedding
/// backend) or `InferenceModel.createDecider` (engines that score options;
/// none does yet). A decider BORROWS its model and never closes it.
///
/// Experimental: the members may change in a minor release while the API
/// settles. `implements` it only for test fakes.
@experimental
abstract interface class Decider {
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
  /// context this decider does not take, the model's own failures unchanged
  /// (`EmbedderClosedException`, `EmbeddingInputTooLongException` — an input
  /// is never truncated — …), [StateError] after [close].
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
  });

  /// The fitted decider as a JSON-encodable map, to be stored and given to
  /// `EmbeddingModel.loadDecider` later instead of fitting again. Versioned;
  /// see the README for the format. Throws [UnsupportedError] for a decider
  /// with nothing to store, and [StateError] when an option's metadata is
  /// not JSON-encodable.
  Map<String, Object?> toArtifact();

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
@experimental
enum ScoreKind {
  /// Cosine similarity in [-1, 1] (the `centroid` method). Not a probability.
  cosine,

  /// Natural-log probability under the decider's own model, before any
  /// calibration (the `linear` method; option scoring by an LLM).
  logprob,
}

/// Why a decider abstained.
@experimental
enum AbstainReason {
  /// The request's abstain signal — its highest cosine to a candidate's
  /// centroid — is below the calibrated threshold: it fits none of them.
  belowThreshold,

  /// `among` left no candidate.
  noCandidates,
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
    required this.questionKinds,
    required this.modalities,
  });

  /// The most options it takes, or null for no limit of its own.
  final int? maxOptions;

  /// Whether `DeciderInput.context` is read.
  final bool supportsContext;

  /// Whether answers carry calibrated probabilities and a confidence.
  final bool calibratedProbabilities;

  /// The Jev question kinds it answers. Only `choice` for now.
  final Set<String> questionKinds;

  /// What an input may carry.
  final Set<EmbeddingModality> modalities;
}

/// A decider's answer.
@experimental
@immutable
final class DeciderAnswer {
  /// For deciders implemented outside core (and test fakes). Lists are
  /// copied.
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
           : Map.unmodifiable(probabilities);

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
