// The seam between the Tiny Island screen and whatever picks the action.
//
// It mirrors the approved core API (`EmbeddingModel.createDecider(...)` →
// `Decider.choose(...)` → `DeciderAnswer`, being built on
// `feat/decision-engine`) so that, when it lands, one adapter class maps a
// `DeciderAnswer` onto an [IslandDecision] and the screen does not change:
//
//   DeciderAnswer.choice        → IslandDecision.choice (null = abstained)
//   DeciderAnswer.ranked        → IslandDecision.ranked (id, score, probability)
//   DeciderAnswer.margin        → IslandDecision.margin
//   DeciderAnswer.abstainReason → IslandDecision.abstainReason
//   DeciderAnswer.provenance    → IslandDecision.embedTime / scoreTime

/// One ranked option of a decision.
final class IslandRankedOption {
  const IslandRankedOption({
    required this.id,
    required this.score,
    this.probability,
  });

  /// The action id, e.g. `walk_to(tree)`.
  final String id;

  /// Similarity of the request to the option (cosine, higher is closer).
  final double score;

  /// The decider's probability for this option, when it gives one.
  final double? probability;
}

/// Why the decider chose nothing.
enum IslandAbstainReason {
  /// The best option is not close enough: the request is about something
  /// else.
  outOfScope,

  /// Two different options are too close to tell apart.
  ambiguous,
}

/// What the decider answered for one request.
final class IslandDecision {
  const IslandDecision({
    required this.choice,
    required this.ranked,
    required this.margin,
    this.abstainReason,
    this.threshold,
    required this.embedTime,
    required this.scoreTime,
    required this.optionCount,
  }) : assert((choice == null) == (abstainReason != null));

  /// The chosen action id; null when the decider abstained.
  final String? choice;

  /// The best options, best first (at most the decider's top-k).
  final List<IslandRankedOption> ranked;

  /// Score of the best option minus the second best.
  final double margin;

  /// Set exactly when [choice] is null.
  final IslandAbstainReason? abstainReason;

  /// The score the best option had to reach, when the decider has one.
  final double? threshold;

  /// How long embedding the request took.
  final Duration embedTime;

  /// How long scoring every option took.
  final Duration scoreTime;

  /// How many options the decider chose among.
  final int optionCount;

  bool get abstained => choice == null;

  Duration get totalTime => embedTime + scoreTime;
}

/// Picks one island action for a request, or abstains.
abstract interface class IslandDecider {
  /// What decides, for the HUD, e.g. "EmbeddingGemma 2 (270M)".
  String get name;

  /// What it runs on (`cpu`, `npu`, `gpu`), when known.
  String? get backend;

  /// How many options it chooses among.
  int get optionCount;

  /// Chooses an action for [request]. Errors arrive as a failed future.
  Future<IslandDecision> decide(String request);

  /// Releases what the decider holds.
  Future<void> close();
}
