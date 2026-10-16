// The checks of InferenceModel.createDecider that need no engine. They run
// before the call asks whether the model can score options at all, so an
// argument that is wrong today fails the same way once an engine can: an app
// that falls back to an embedding decider on DeciderUnsupportedException does
// not start failing on ArgumentError after an upgrade. Not exported.

import '../model_management/cancel_token.dart' show CancelToken;
import 'decider.dart' show throwIfDeciderCancelled;
import 'decider_method.dart';
import 'decider_option.dart';

/// Throws [ArgumentError] for a [question], [options] or [calibration] that no
/// language-model decider can use, then `DeciderCancelledException` when
/// [cancelToken] is already cancelled.
void checkInferenceDeciderArguments({
  required String question,
  required List<DeciderOption> options,
  required InferenceDeciderCalibration calibration,
  CancelToken? cancelToken,
}) {
  if (question.trim().isEmpty) {
    throw ArgumentError.value(question, 'question', 'must not be blank');
  }
  if (options.isEmpty) {
    throw ArgumentError.value(options, 'options', 'must not be empty');
  }
  final ids = <String>{};
  for (final option in options) {
    if (!ids.add(option.id)) {
      throw ArgumentError.value(
        option.id,
        'options',
        'two options share the id "${option.id}"',
      );
    }
    if (option.examples.isNotEmpty) {
      throw ArgumentError.value(
        option.id,
        'options',
        'option "${option.id}" has examples: a language-model decider lists '
            'each option by its id and description and scores the id; it '
            'takes no examples, and refuses them rather than ignoring them',
      );
    }
  }
  final temperature = calibration.temperature;
  if (temperature != null && !(temperature > 0 && temperature.isFinite)) {
    throw ArgumentError.value(
      temperature,
      'calibration.temperature',
      'must be positive and finite',
    );
  }
  final abstainBelow = calibration.abstainBelow;
  if (abstainBelow != null) {
    if (temperature == null) {
      throw ArgumentError.value(
        abstainBelow,
        'calibration.abstainBelow',
        'is a probability threshold: it needs a temperature',
      );
    }
    if (!(abstainBelow > 0 && abstainBelow < 1)) {
      throw ArgumentError.value(
        abstainBelow,
        'calibration.abstainBelow',
        'must be in (0, 1)',
      );
    }
  }
  final noneOption = calibration.noneOption;
  if (noneOption != null && !ids.contains(noneOption)) {
    throw ArgumentError.value(
      noneOption,
      'calibration.noneOption',
      'is not one of the options',
    );
  }
  throwIfDeciderCancelled(cancelToken);
}
