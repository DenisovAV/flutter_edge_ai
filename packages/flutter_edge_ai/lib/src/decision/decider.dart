// The decider contract: pick one of N options for an input, or abstain.
//
// One contract for two kinds of decider: an EmbeddingModel's (centroids or a
// linear layer over embeddings) and an InferenceModel's (an LLM trained on the
// question scores each option as its reply). The answer side is shared so an
// app can swap one for the other; what differs between them is said by
// [DeciderCapabilities], [DeciderProvenance] and [AbstainSignalKind].

import 'package:meta/meta.dart' show experimental, immutable;

import '../embedding/embedding_input.dart';
import '../embedding/embedding_modality.dart';
import '../message.dart';
import '../model_management/cancel_token.dart' show CancelToken;
import 'decider_exceptions.dart';
import 'decider_method.dart';
import 'decider_option.dart';
import 'embedding_decider.dart' show chooseAllWithSharedEmbeddings;

/// Picks one of its options for an input — or abstains when none fits.
///
/// Get one from a model: `EmbeddingModel.createDecider` (every embedding
/// backend) or `InferenceModel.createDecider` (an engine that scores options;
/// none does in this release). A decider BORROWS its model and never closes
/// it.
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
  /// [among] restricts the candidates to those option ids, when
  /// `capabilities.supportsAmong`; a decider without it fails with
  /// `DeciderUnsupportedException` for any non-null [among]. Unknown ids
  /// throw [ArgumentError]; an empty set abstains with
  /// [AbstainReason.noCandidates]. [topK] (≥ 1) caps [DeciderAnswer.ranked];
  /// the margin and probabilities still cover every candidate.
  ///
  /// [cancelToken] fails the call with `DeciderCancelledException`; so does a
  /// [close] while the call runs. Work already in flight (an embedding)
  /// finishes and its result is dropped.
  ///
  /// Errors arrive as a FAILED FUTURE: `DeciderUnsupportedException` for
  /// context, [among] or a modality this decider does not take,
  /// `DeciderSpaceMismatchException` when the embedder core now serves is in
  /// another embedding space, `DeciderCancelledException`, the model's own
  /// failures unchanged (`EmbedderClosedException`,
  /// `EmbeddingInputTooLongException` — an input is never truncated — …),
  /// [StateError] after [close].
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
    CancelToken? cancelToken,
  });

  /// The fitted decider as a JSON-encodable map, to be stored and given to
  /// `EmbeddingModel.loadDecider` later instead of fitting again. Versioned;
  /// the format is documented at https://flutteredge.ai/docs/decisions.
  /// Throws [StateError] when an option's metadata is not JSON-encodable.
  ///
  /// `capabilities.storable` says whether this decider has one. This default
  /// throws `DeciderUnsupportedException`: a decider with nothing to store
  /// (one implemented outside core, unless it overrides this) has no
  /// artifact.
  Map<String, Object?> toArtifact() => throw DeciderUnsupportedException(
    '$runtimeType has no artifact: it stores nothing that '
    'EmbeddingModel.loadDecider could restore.',
  );

  /// Whether [choose] can no longer answer: [close] was called, or — for an
  /// embedding decider — its model is closed and core serves none in its
  /// place (a model `getActiveEmbedder` did not build). A decider on a model
  /// core replaced is not closed: its next [choose] takes the replacement.
  bool get isClosed;

  /// Marks this decider closed; [choose] fails afterwards, and a [choose]
  /// still running fails with `DeciderCancelledException`. Idempotent. The
  /// model the decider was created from stays open: it is borrowed.
  Future<void> close();

  /// Answers every one of [deciders] for the same [input], in their order.
  ///
  /// Deciders created from the same `EmbeddingModel` share ONE embedding of
  /// [input] — that is what this adds over calling [choose] on each: three
  /// deciders over one request cost one embedding, not three. Other deciders
  /// are asked one by one. Each answer's `provenance.encodeTime` is the time
  /// of the embedding it used.
  ///
  /// [cancelToken] reaches every decider; the first failure fails the call.
  static Future<List<DeciderAnswer>> chooseAll(
    DeciderInput input,
    List<Decider> deciders, {
    int topK = 5,
    CancelToken? cancelToken,
  }) => chooseAllWithSharedEmbeddings(
    input,
    deciders,
    topK: topK,
    cancelToken: cancelToken,
  );
}

/// What a decider is asked about: the [input] and, for deciders that read
/// one, the conversation so far.
@experimental
@immutable
final class DeciderInput {
  /// [context] is copied. No decider in this release reads it: each fails
  /// with `DeciderUnsupportedException` when it is not empty, rather than
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

  /// Natural-log probability of the candidate under the decider's own model,
  /// normalised over the candidates, before any calibration: the `linear`
  /// method's log-softmax, and `optionScoring`'s `s − logsumexp(s)` over the
  /// options, where `s` is the model's log-probability of the option's id as
  /// its reply.
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

  /// The answer's abstain signal is below the decider's calibrated threshold
  /// (`provenance.abstainSignal < provenance.threshold`): the request fits
  /// none of the candidates. What the signal is — a cosine, a probability —
  /// is `provenance.abstainSignalKind`.
  static const belowThreshold = AbstainReason._('belowThreshold');

  /// `among` left no candidate.
  static const noCandidates = AbstainReason._('noCandidates');

  /// The option the decider's calibration names as "none of these" ranked
  /// first (a model trained with one). It stays in `ranked` and
  /// `probabilities`.
  static const noneOption = AbstainReason._('noneOption');

  /// Every reason this release knows, in declaration order.
  static const values = [belowThreshold, noCandidates, noneOption];

  /// Stable name: `belowThreshold`, `noCandidates`, `noneOption`.
  final String name;

  @override
  String toString() => 'AbstainReason.$name';
}

/// What [DeciderProvenance.abstainSignal] is.
///
/// A class with constant instances rather than an enum, so a kind added in a
/// later release does not break an app's exhaustive `switch`.
@experimental
@immutable
final class AbstainSignalKind {
  const AbstainSignalKind._(this.name);

  /// The input's highest cosine to a candidate's centroid (an embedding
  /// decider, either method). Not a probability.
  static const topCosine = AbstainSignalKind._('topCosine');

  /// The highest calibrated probability over the candidates (an inference
  /// decider calibrated with a temperature).
  static const topProbability = AbstainSignalKind._('topProbability');

  /// Every kind this release knows, in declaration order.
  static const values = [topCosine, topProbability];

  /// Stable name: `topCosine`, `topProbability`.
  final String name;

  @override
  String toString() => 'AbstainSignalKind.$name';
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
    required this.encodeTime,
    required this.scoreTime,
    this.spaceId,
    this.threshold,
    this.abstainSignal,
    this.abstainSignalKind,
  });

  /// How the options were scored.
  final DeciderMethod method;

  /// The calibration kind: `none`, `crossFit`, `minSimilarity` or `labelled`
  /// for an embedding decider; `none` or `supplied` (values fitted offline,
  /// for one model and one question) for an inference decider.
  final String calibration;

  /// The embedding space an embedding decider works in: the model's
  /// identity, its dimension, its backend, the image budget of a decider
  /// fitted on images, and the task prefix. Null for a decider that compares
  /// no vectors (an inference decider).
  final String? spaceId;

  /// Time spent on the input once: its embedding (shared by
  /// `Decider.chooseAll`'s answers over one embedding), or an inference
  /// decider's prompt prefill.
  final Duration encodeTime;

  /// Time spent scoring the candidates.
  final Duration scoreTime;

  /// The abstain threshold [abstainSignal] was compared with; null when the
  /// decider never abstains on a threshold.
  final double? threshold;

  /// The value compared with [threshold], of the kind [abstainSignalKind]
  /// names; reported even when there is no threshold. Null when there was no
  /// candidate, and when the decider has no such signal (an uncalibrated
  /// inference decider).
  final double? abstainSignal;

  /// What [abstainSignal] is; null exactly when it is null.
  final AbstainSignalKind? abstainSignalKind;
}

/// What a decider can do.
@experimental
@immutable
final class DeciderCapabilities {
  const DeciderCapabilities({
    required this.modalities,
    required this.calibratedProbabilities,
    required this.supportsContext,
    required this.supportsAmong,
    required this.storable,
  });

  /// What an input may carry.
  final Set<EmbeddingModality> modalities;

  /// Whether answers carry calibrated probabilities and a confidence.
  final bool calibratedProbabilities;

  /// Whether `DeciderInput.context` is read.
  final bool supportsContext;

  /// Whether `choose(among:)` is honoured. Without it a non-null `among`
  /// fails with `DeciderUnsupportedException`.
  final bool supportsAmong;

  /// Whether `toArtifact()` returns an artifact that
  /// `EmbeddingModel.loadDecider` restores.
  final bool storable;
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
  /// entry in [probabilities] when both are given; the provenance's abstain
  /// signal and its kind are both set or both null; an answer that abstains
  /// with [AbstainReason.belowThreshold] has its signal below the threshold
  /// (both set), and one that chooses with both set has it at or above;
  /// [AbstainReason.noneOption] comes with candidates in [ranked] and may
  /// have its signal on either side (the none option wins first);
  /// [AbstainReason.noCandidates] comes with nothing ranked and no signal.
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
    _checkAbstention();
  }

  void _checkAbstention() {
    final signal = provenance.abstainSignal;
    final threshold = provenance.threshold;
    if ((signal == null) != (provenance.abstainSignalKind == null)) {
      throw ArgumentError(
        'provenance.abstainSignal and provenance.abstainSignalKind are both '
        'set or both null; got $signal and ${provenance.abstainSignalKind}.',
      );
    }
    final reason = abstainReason;
    if (identical(reason, AbstainReason.belowThreshold)) {
      if (signal == null || threshold == null || !(signal < threshold)) {
        throw ArgumentError.value(
          signal,
          'provenance.abstainSignal',
          'an answer abstains belowThreshold only with its signal below the '
              'threshold ($threshold)',
        );
      }
    } else if (choice != null && signal != null && threshold != null) {
      if (!(signal >= threshold)) {
        throw ArgumentError.value(
          signal,
          'provenance.abstainSignal',
          'is below the threshold ($threshold), so the answer abstains '
              'belowThreshold instead of choosing $choice',
        );
      }
    }
    if (identical(reason, AbstainReason.noneOption) && ranked.isEmpty) {
      throw ArgumentError.value(
        ranked,
        'ranked',
        'an answer that abstains noneOption ranks the options it scored',
      );
    }
    if (identical(reason, AbstainReason.noCandidates)) {
      if (ranked.isNotEmpty) {
        throw ArgumentError.value(
          ranked,
          'ranked',
          'an answer that abstains noCandidates had no candidate to rank',
        );
      }
      if (signal != null) {
        throw ArgumentError.value(
          signal,
          'provenance.abstainSignal',
          'an answer that abstains noCandidates had no candidate to measure',
        );
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
