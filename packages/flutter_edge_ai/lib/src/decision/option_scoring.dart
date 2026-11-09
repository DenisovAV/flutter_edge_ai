// The engine side of InferenceModel.createDecider: what an engine supplies so
// that core can score options with it, through the scorer its
// InferenceModel.openOptionScorer returns. Core owns the decider itself —
// reading the decision, the prompt, the targets, the call's checks and the
// answer — once for every engine; an engine implements these calls and
// whatever its runtime needs to return exact scores.

import 'package:meta/meta.dart' show experimental, immutable;

import '../model_management/cancel_token.dart' show CancelToken;

/// An engine's calls for scoring options, on one loaded model: what its
/// `InferenceModel.openOptionScorer` returns. Core makes one call at a time
/// on a scorer (a decider runs its decisions one after another); every call
/// runs on the model's own engine, ordered with its other native work.
///
/// An `abstract base class`, so that a member added in a later release
/// reaches every engine with its default body. Extend it.
///
/// Experimental: may change in a minor release while the API settles.
@experimental
abstract base class OptionScorer {
  /// For engines.
  const OptionScorer();

  /// The model's token ids for [text], as its tokenizer splits it — control
  /// tokens written as text (`<end_of_turn>`) included — with no BOS added.
  Future<List<int>> tokenize(String text);

  /// The text of [ids].
  Future<String> detokenize(List<int> ids);

  /// One user message with [content], rendered by the model's own chat
  /// template up to where the model's reply begins: the prompt [score] takes.
  Future<String> renderUserMessage(String content);

  /// Called once, before the first [score], with the decision's targets. An
  /// engine checks here what it has to before it can score them exactly
  /// (LiteRT-LM finds out how its version scores after a prefill, in debug
  /// and profile builds only: a release build scores in the mode the check
  /// picked on every engine measured), and fails with
  /// `DeciderUnsupportedException` when it cannot. Nothing by default.
  Future<void> prepare(List<String> targets) async {}

  /// The exact natural-log probability of each token of each of [targets] as
  /// the model's continuation of [prompt] — the text [renderUserMessage]
  /// returned, after the BOS the engine adds — each target scored on its own,
  /// tokenised as [tokenize] splits it.
  ///
  /// Returns one list per target, in order. Fails with
  /// `DeciderCancelledException` once [cancelToken] is cancelled, between
  /// targets at the latest; with [StateError] once the model or the scorer
  /// is closed.
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    CancelToken? cancelToken,
  });

  /// Releases what the scorer holds. The model stays open. Idempotent.
  ///
  /// Core also calls it to cancel: when a `createDecider` is cancelled while
  /// [prepare] runs, and when the app closes the decider while [score] runs.
  /// An engine should stop its native work for this scorer then; the calls
  /// in flight may fail with [StateError], which core reports as the cancel.
  Future<void> close();
}

/// What one [OptionScorer.score] call returned.
@experimental
@immutable
final class OptionScoringRun {
  /// [tokenScores] is copied.
  OptionScoringRun({
    required List<List<double>> tokenScores,
    required this.prefillTime,
    required this.scoreTime,
  }) : tokenScores = List.unmodifiable([
         for (final scores in tokenScores) List<double>.unmodifiable(scores),
       ]);

  /// For each target, the natural-log probability of each of its tokens.
  /// Unmodifiable.
  final List<List<double>> tokenScores;

  /// Time spent on the prompt's prefill.
  final Duration prefillTime;

  /// Time spent scoring the targets.
  final Duration scoreTime;
}
