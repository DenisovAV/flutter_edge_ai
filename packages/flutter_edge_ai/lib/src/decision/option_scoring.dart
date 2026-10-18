// The engine side of InferenceModel.createDecider: what an engine supplies so
// that core can score options with it. Core owns the decider itself — reading
// the decision, the prompt, the targets, the self-check and the answer — once
// for every engine; an engine only implements these calls.

import 'package:meta/meta.dart' show experimental, immutable;

import '../model_management/cancel_token.dart' show CancelToken;

/// Implemented by an `InferenceModel` whose engine can score options, which
/// is what `InferenceModel.createDecider` needs. Exported for engines
/// (`package:flutter_edge_ai/engine.dart`); an app never calls it.
///
/// Experimental: may change in a minor release while the API settles.
@experimental
abstract interface class OptionScoringModel {
  /// The decision the model file was trained for: the UTF-8 JSON payload of
  /// its `litetune.decision` section, as litetune's `bundle` wrote it. Null
  /// when the file carries none: it is an ordinary chat model, and
  /// `createDecider` refuses it.
  ///
  /// Throws [FormatException] when the file cannot be read as the engine's
  /// container, or carries the section more than once.
  Future<String?> readDecisionSection();

  /// The engine's scoring calls, for one decider. Fails with
  /// `DeciderUnsupportedException` when this model cannot score here — a
  /// backend option scoring is not measured on, for one — and with
  /// [StateError] when the model is closed.
  Future<OptionScorer> openOptionScorer();
}

/// An engine's calls for scoring options, on one loaded model. Every call
/// runs on the model's own engine, ordered with its other native work.
///
/// Experimental: may change in a minor release while the API settles.
@experimental
abstract interface class OptionScorer {
  /// The model's token ids for [text], as its tokenizer splits it, with no
  /// BOS added.
  Future<List<int>> tokenize(String text);

  /// The text of [ids].
  Future<String> detokenize(List<int> ids);

  /// One user message with [content], rendered by the model's own chat
  /// template up to where the model's reply begins — the text a session
  /// without a prompt template is prefilled with. Without the BOS the session
  /// adds.
  Future<String> renderUserMessage(String content);

  /// Scores each of [targets] as the model's continuation of [prompt], in one
  /// fresh session that applies no prompt template:
  /// 1. prefill [prompt];
  /// 2. with more than one target, save a checkpoint;
  /// 3. prefill [reprefill] once, when given;
  /// 4. for each target, score it, then rewind to the checkpoint.
  ///
  /// Returns, for each target in order, the log-probability of each of its
  /// tokens. [cancelToken] is checked before the session starts; a run that
  /// started is not interrupted.
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    String? reprefill,
    CancelToken? cancelToken,
  });

  /// Releases what the scorer holds. The model stays open.
  Future<void> close();
}

/// What one [OptionScorer.score] call returned.
@experimental
@immutable
final class OptionScoringRun {
  const OptionScoringRun({
    required this.tokenScores,
    required this.prefillTime,
    required this.scoreTime,
  });

  /// For each target, the natural-log probability of each of its tokens.
  final List<List<double>> tokenScores;

  /// Time spent on the prefills.
  final Duration prefillTime;

  /// Time spent scoring the targets.
  final Duration scoreTime;
}
