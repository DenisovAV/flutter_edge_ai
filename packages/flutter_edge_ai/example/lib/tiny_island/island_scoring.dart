import 'dart:math' as math;

import 'island_decider.dart';

/// Turns per-option scores into an [IslandDecision]: ranked best first, the
/// margin between the first two, a softmax probability at [temperature], and
/// an abstention when the best score is under [threshold] (out of scope) or
/// the first two are closer than [minMargin] (ambiguous).
///
/// Shared by the embedding stand-in and the keyword fake, so both answer in
/// the same shape the core Decider will.
IslandDecision rankIslandOptions({
  required Map<String, double> scores,
  required double threshold,
  required double minMargin,
  required double temperature,
  required Duration embedTime,
  required Duration scoreTime,
  int topK = 5,
}) {
  if (scores.isEmpty) throw ArgumentError.value(scores, 'scores', 'is empty');
  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final best = sorted.first.value;
  // Softmax over every option, shifted by the best for stability.
  var sum = 0.0;
  for (final entry in sorted) {
    sum += math.exp((entry.value - best) / temperature);
  }
  final ranked = [
    for (final entry in sorted.take(topK))
      IslandRankedOption(
        id: entry.key,
        score: entry.value,
        probability: math.exp((entry.value - best) / temperature) / sum,
      ),
  ];
  final margin = sorted.length > 1 ? best - sorted[1].value : best;
  final reason = best < threshold
      ? IslandAbstainReason.outOfScope
      : margin < minMargin
      ? IslandAbstainReason.ambiguous
      : null;
  return IslandDecision(
    choice: reason == null ? sorted.first.key : null,
    ranked: ranked,
    margin: margin,
    abstainReason: reason,
    threshold: threshold,
    embedTime: embedTime,
    scoreTime: scoreTime,
    optionCount: scores.length,
  );
}
