// InferenceModel.createDecider for an engine that scores options
// (OptionScoringModel): the decision litetune writes into the model file, the
// prompt rendered as litetune trained the model, each option scored as the
// model's reply, and the answer. Not exported.
//
// The contract is litetune's decision contract, version 1. Each step mirrors
// litetune's own code (0.5.0):
// - the section and its checks: `decision_verify.section_payload` and
//   `decisions.decision_from`;
// - the prompt: `Decision.render`, byte for byte;
// - the targets: `decision_scripts` ENGINE_SCRIPT (the scoring itself, and
//   its self-check, are the engine's: `OptionScorer`);
// - the answer: `decision_verify._given` and `calibration.answers`, with the
//   probabilities `softmax(s / T)` over the listed options.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../embedding/embedding_modality.dart';
import '../interface.dart' show InferenceModel;
import '../model_management/cancel_token.dart' show CancelToken;
import 'decider.dart';
import 'decider_exceptions.dart';
import 'decider_method.dart';
import 'decider_option.dart';
import 'embedding_decider.dart' show deciderConfidence;
import 'option_scoring.dart';

/// The decision contract version this release reads.
const decisionContractVersion = 1;

/// The last line of every decision prompt (`decisions.ANSWER_LINE`).
const decisionAnswerLine = 'Answer with the id of one option.';

/// Text a chat template or a tokenizer reads as structure rather than as
/// words (`decisions.CONTROL_TEXT`: the turn markers `prompt_mode` knows, then
/// Gemma 3's control tokens). A state carrying one is refused: it would close
/// the user turn early, in a prompt the model was never trained on.
const decisionControlText = [
  '<start_of_turn>',
  '<|turn>',
  '<|im_start|>',
  '<|start_header_id|>',
  '<start_of_image>',
  '<end_of_turn>',
  '<bos>',
  '<eos>',
  '<pad>',
];

/// The keys of a version-1 section payload, every one required.
const _sectionKeys = {
  'contract_version',
  'type',
  'question',
  'options',
  'none_option',
  'scoring',
  'terminator',
  'scored_lengths',
  'temperature',
  'abstain_rule',
  'abstain_below',
};

/// One option as the model was trained on it.
final class DecisionOption {
  const DecisionOption(this.id, [this.description]);

  final String id;

  /// Null for an option trained without one, and for the `none_option`.
  final String? description;

  /// How the prompt lists it.
  String get line => description == null ? '- $id' : '- $id: $description';
}

/// The `litetune.decision` section of a model file: the decision the model
/// was trained on, and how its options were scored when its temperature and
/// threshold were fitted.
final class DecisionSection {
  DecisionSection._({
    required this.type,
    required this.question,
    required this.options,
    required this.noneOption,
    required this.terminator,
    required this.scoredLengths,
    required this.temperature,
    required this.abstainRule,
    required this.abstainBelow,
  });

  /// Parses a section payload. Throws [FormatException] naming the field for
  /// one this release does not read.
  factory DecisionSection.parse(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (e) {
      throw FormatException('it is not JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('it is not a JSON object');
    }
    final version = decoded['contract_version'];
    if (version is! int || version != decisionContractVersion) {
      throw FormatException(
        'its contract_version is ${jsonEncode(version)}; this release reads '
        'version $decisionContractVersion',
      );
    }
    final unknown = decoded.keys.toSet().difference(_sectionKeys);
    final missing = _sectionKeys.difference(decoded.keys.toSet());
    if (unknown.isNotEmpty || missing.isNotEmpty) {
      throw FormatException(
        'its keys differ from version $decisionContractVersion\'s: '
        '${unknown.isEmpty ? '' : 'unknown ${unknown.toList()}'}'
        '${unknown.isNotEmpty && missing.isNotEmpty ? ', ' : ''}'
        '${missing.isEmpty ? '' : 'missing ${missing.toList()}'}',
      );
    }
    final type = decoded['type'];
    final questionType = type is String
        ? deciderQuestionTypeByName(type)
        : null;
    if (questionType == null) {
      throw FormatException(
        'its type ${jsonEncode(type)} is not choice, noul or score',
      );
    }
    final question = _line(decoded['question'], 'question');
    final rawOptions = decoded['options'];
    if (rawOptions is! List || rawOptions.isEmpty) {
      throw const FormatException('its options are not a non-empty list');
    }
    final options = <DecisionOption>[];
    for (var i = 0; i < rawOptions.length; i++) {
      final entry = rawOptions[i];
      if (entry is! Map<String, Object?> ||
          entry.keys.toSet().difference(const {
            'id',
            'description',
          }).isNotEmpty) {
        throw FormatException(
          'its options[$i] is not an object with an id and, optionally, a '
          'description',
        );
      }
      final description = entry['description'];
      options.add(
        DecisionOption(
          _line(entry['id'], 'options[$i].id'),
          description == null
              ? null
              : _line(description, 'options[$i].description'),
        ),
      );
    }
    final noneValue = decoded['none_option'];
    final noneOption = noneValue == null
        ? null
        : _line(noneValue, 'none_option');
    final ids = <String>{};
    for (final id in [for (final o in options) o.id, ?noneOption]) {
      if (id.contains(': ')) {
        throw FormatException(
          'its option id "$id" contains ": ", which the prompt would read as '
          'an id and a description',
        );
      }
      if (!ids.add(id)) {
        throw FormatException('it lists the option id "$id" twice');
      }
    }
    if (decoded['scoring'] != 'unique_prefix') {
      throw FormatException(
        'its scoring ${jsonEncode(decoded['scoring'])} is not unique_prefix',
      );
    }
    final terminator = decoded['terminator'];
    if (terminator is! String || terminator.isEmpty) {
      throw const FormatException('its terminator is not a non-empty string');
    }
    final rawLengths = decoded['scored_lengths'];
    if (rawLengths is! List ||
        rawLengths.length != ids.length ||
        rawLengths.any((n) => n is! int || n < 1)) {
      throw FormatException(
        'its scored_lengths ${jsonEncode(rawLengths)} are not one positive '
        'count per listed option (${ids.length})',
      );
    }
    final temperature = decoded['temperature'];
    if (temperature is! num || !(temperature > 0 && temperature.isFinite)) {
      throw FormatException(
        'its temperature ${jsonEncode(temperature)} is not positive and '
        'finite',
      );
    }
    final rule = decoded['abstain_rule'];
    final below = decoded['abstain_below'];
    if (type == 'choice') {
      if (rule != 'reject_target' && rule != 'error_budget') {
        throw FormatException(
          'its abstain_rule ${jsonEncode(rule)} is not reject_target or '
          'error_budget, as a choice question\'s is',
        );
      }
      if (below is! num || !(below >= 0 && below < 1)) {
        throw FormatException(
          'its abstain_below ${jsonEncode(below)} is not a probability in '
          '[0, 1)',
        );
      }
      if (ids.length < 2) {
        throw const FormatException('a choice question lists two options');
      }
    } else {
      if (rule != null || below != null || noneOption != null) {
        throw FormatException(
          'a $type question never abstains: its abstain_rule, abstain_below '
          'and none_option are null',
        );
      }
      if (type == 'noul') {
        if (options.length != 2 ||
            options[0].id != 'no' ||
            options[1].id != 'yes') {
          throw const FormatException(
            'a noul question\'s options are "no" and "yes", in that order',
          );
        }
      } else {
        for (var i = 0; i < options.length; i++) {
          if (options[i].id != '$i' || options[i].description == null) {
            throw const FormatException(
              'a score question\'s options are the levels "0", "1", … lowest '
              'first, each with its text',
            );
          }
        }
        if (options.length < 2) {
          throw const FormatException('a score question has two levels');
        }
      }
    }
    return DecisionSection._(
      type: questionType,
      question: question,
      options: List.unmodifiable(options),
      noneOption: noneOption,
      terminator: terminator,
      scoredLengths: List.unmodifiable(rawLengths.cast<int>()),
      temperature: temperature.toDouble(),
      abstainRule: rule as String?,
      abstainBelow: (below as num?)?.toDouble(),
    );
  }

  final DeciderQuestionType type;
  final String question;

  /// The trained options, without the `none_option`, in the trained order.
  final List<DecisionOption> options;

  /// The id the model was trained to give for "none of these"; Choice only.
  final String? noneOption;

  /// What follows each id in its target (`<end_of_turn>` for Gemma 3).
  final String terminator;

  /// How many tokens of each listed option's target were scored when the
  /// temperature and the threshold were fitted.
  final List<int> scoredLengths;

  final double temperature;

  /// `reject_target` or `error_budget` for Choice, null for Noul and Score.
  final String? abstainRule;

  /// The probability below which a Choice answer abstains; null for Noul and
  /// Score. 0 means only the `none_option` abstains.
  final double? abstainBelow;

  /// The options as the prompt lists them: the trained ones, then the
  /// `none_option`.
  late final List<DecisionOption> listed = List.unmodifiable([
    ...options,
    if (noneOption case final none?) DecisionOption(none),
  ]);

  /// The threshold as `InferenceDeciderCalibration.abstainBelow` carries it:
  /// a threshold of 0 never abstains, so it is null there.
  double? get calibrationAbstainBelow =>
      abstainBelow == null || abstainBelow == 0 ? null : abstainBelow;

  /// The user message for [state] (`Decision.render`), byte for byte.
  String render(String state) =>
      '$state\n\nQuestion: $question\nOptions:\n'
      '${listed.map((o) => o.line).join('\n')}\n$decisionAnswerLine';

  static String _line(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('its $field is not a non-empty string');
    }
    if (value.contains('\n') || value.contains('\r')) {
      throw FormatException(
        'its $field spans lines, which the prompt would read as more options',
      );
    }
    for (final marker in decisionControlText) {
      if (value.contains(marker)) {
        throw FormatException('its $field contains the control text $marker');
      }
    }
    return value;
  }
}

/// A token score above this is not a log-probability (they are ≤ 0), with
/// room for float rounding.
const _maxTokenScore = 1e-4;

/// The options' probabilities, `exp(logsumexp(s))`, sum to at most 1 for an
/// engine that returns log-probabilities: the targets are prefix-free. This
/// is the rounding allowed above 0 for `logsumexp(s)`.
const _maxLogSumExp = 1e-3;

/// [InferenceModel.createDecider] on a model whose engine scores options.
Future<Decider> createOptionScoringDecider(
  OptionScoringModel model, {
  required String question,
  required List<DeciderOption> options,
  required InferenceDeciderCalibration calibration,
  CancelToken? cancelToken,
}) async {
  final String? payload;
  try {
    payload = await model.readDecisionSection();
  } on FormatException catch (e) {
    throw DeciderUnsupportedException(
      'The decision of the model file of ${model.runtimeType} cannot be '
      'read: $e',
    );
  }
  if (payload == null) {
    throw DeciderUnsupportedException(
      'The model file of ${model.runtimeType} carries no decision (a '
      'litetune.decision section): it is an ordinary chat model. A model '
      'tuned for a decision by LiteTune carries one when its verify passed; '
      'use EmbeddingModel.createDecider for any other.',
    );
  }
  final DecisionSection section;
  try {
    section = DecisionSection.parse(payload);
  } on FormatException catch (e) {
    throw DeciderUnsupportedException(
      'The decision in the model file of ${model.runtimeType} is not one '
      'this release reads: ${e.message}',
    );
  }
  final decided = checkAgainstDecisionSection(
    section,
    question: question,
    options: options,
    calibration: calibration,
  );
  throwIfDeciderCancelled(cancelToken);
  final scorer = await model.openOptionScorer();
  // A cancel while the engine prepares (LiteRT-LM's self-check is a couple
  // of dozen native runs) closes the scorer, which stops the runs this scorer
  // started; the StateError a closed scorer then throws reads as the cancel
  // it is. Only that one: a failure from before the cancel stays a failure.
  var creating = true;
  var closedByCancel = false;
  if (cancelToken != null) {
    unawaited(
      cancelToken.whenCancelled.then((_) {
        if (!creating) return;
        closedByCancel = true;
        unawaited(
          scorer.close().catchError((Object e) {
            // ignore: avoid_print
            print(
              '[flutter_edge_ai] closing the option scorer on a cancelled '
              'createDecider failed: $e',
            );
          }),
        );
      }),
    );
  }
  try {
    final targets = await optionTargets(scorer, section);
    throwIfDeciderCancelled(cancelToken);
    await scorer.prepare(targets.texts);
    throwIfDeciderCancelled(cancelToken);
    // The decision must fit the model's context with the shortest input: a
    // prompt with a one-character state, its BOS, the longest target and a
    // token an engine may prefill again.
    final fixed = await scorer.tokenize(
      await scorer.renderUserMessage(section.render('.')),
    );
    final least = fixed.length + 2 + section.scoredLengths.reduce(math.max);
    if (least > model.maxTokens) {
      throw DeciderUnsupportedException(
        'This decision needs $least tokens of context before any input — its '
        'question and ${section.listed.length} options — and the model is '
        'loaded with maxTokens ${model.maxTokens}. Load it with a larger '
        'maxTokens.',
      );
    }
    throwIfDeciderCancelled(cancelToken);
    creating = false;
    return OptionScoringDecider._(
      model,
      scorer,
      section,
      decided,
      targets.texts,
    );
  } catch (e, st) {
    creating = false;
    final cancelled = e is StateError && closedByCancel;
    try {
      await scorer.close();
    } on Object catch (closeError) {
      // The creation's own failure is the one the caller needs; release
      // builds hear about this one too.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai] closing the option scorer after a failed '
        'createDecider failed too: $closeError',
      );
    }
    if (cancelled) {
      throw const DeciderCancelledException('The decision was cancelled.');
    }
    Error.throwWithStackTrace(e, st);
  }
}

/// Throws [ArgumentError] unless [question], [options] and [calibration] are
/// the ones [section] was trained and fitted with, and returns the decider's
/// options: the app's, in the app's order, with the none option appended
/// when [InferenceDeciderCalibration.fromModel] let the app leave it out.
/// The prompt lists the trained order whatever the app's is.
List<DeciderOption> checkAgainstDecisionSection(
  DecisionSection section, {
  required String question,
  required List<DeciderOption> options,
  required InferenceDeciderCalibration calibration,
}) {
  if (question != section.question) {
    throw ArgumentError.value(
      question,
      'question',
      'is not the question this model was trained on: "${section.question}"',
    );
  }
  final listed = {for (final o in section.listed) o.id: o};
  final given = {for (final o in options) o.id};
  final unknown = given.where((id) => !listed.containsKey(id)).toList();
  if (unknown.isNotEmpty) {
    throw ArgumentError.value(
      unknown,
      'options',
      'are not options this model was trained on (${listed.keys.toList()})',
    );
  }
  final none = section.noneOption;
  final noneLeftOut =
      calibration.fromModelFile && none != null && !given.contains(none);
  final missing = [
    for (final id in listed.keys)
      if (!given.contains(id) && !(noneLeftOut && id == none)) id,
  ];
  if (missing.isNotEmpty) {
    throw ArgumentError.value(
      missing,
      'options',
      'are trained options the call leaves out. A subset of the trained '
          'options is not measured; pass all of '
          '${section.options.map((o) => o.id).toList()}',
    );
  }
  for (final option in options) {
    final description = option.description;
    final trained = listed[option.id]!.description;
    if (description != null &&
        description != trained &&
        description != option.id) {
      throw ArgumentError.value(
        description,
        'options',
        'option "${option.id}" was trained '
            '${trained == null ? 'without a description' : 'with the description "$trained"'}; '
            'the prompt lists the trained one',
      );
    }
  }
  if (!calibration.fromModelFile) {
    if (calibration.temperature != section.temperature) {
      throw ArgumentError.value(
        calibration.temperature,
        'calibration.temperature',
        'is not the temperature fitted for this model build '
            '(${section.temperature}); pass '
            'InferenceDeciderCalibration.fromModel() to use the file\'s',
      );
    }
    final below = section.calibrationAbstainBelow;
    if (calibration.abstainBelow != below) {
      throw ArgumentError.value(
        calibration.abstainBelow,
        'calibration.abstainBelow',
        'is not the threshold fitted for this model build ($below); pass '
            'InferenceDeciderCalibration.fromModel() to use the file\'s',
      );
    }
    if (calibration.noneOption != none) {
      throw ArgumentError.value(
        calibration.noneOption,
        'calibration.noneOption',
        'is not the none option this model was trained with ($none)',
      );
    }
  }
  return List.unmodifiable([...options, if (noneLeftOut) DeciderOption(none)]);
}

/// Each listed option's target text and the token ids of its whole target
/// (`<id><terminator>`).
typedef OptionTargets = ({List<String> texts, List<List<int>> wholeTargetIds});

/// The targets of [section]'s listed options: each one's shortest unique
/// prefix (the first k ids of `<id><terminator>`, k the smallest no other
/// option shares), or its whole target where that prefix does not tokenise
/// back to the same ids. Throws `DeciderUnsupportedException` when the
/// counts differ from the section's `scored_lengths`: a tokenizer that splits
/// an id another way scores other targets than the calibration saw.
Future<OptionTargets> optionTargets(
  OptionScorer scorer,
  DecisionSection section,
) async {
  final listed = section.listed;
  final whole = [
    for (final option in listed)
      await scorer.tokenize('${option.id}${section.terminator}'),
  ];
  for (var i = 0; i < listed.length; i++) {
    if (whole[i].isEmpty) {
      throw DeciderUnsupportedException(
        'The option "${listed[i].id}" tokenises to nothing.',
      );
    }
  }
  final texts = <String>[];
  final lengths = <int>[];
  for (var i = 0; i < listed.length; i++) {
    final ids = whole[i];
    var k = 1;
    while (_sharesPrefix(whole, i, k)) {
      k++;
      if (k > ids.length) {
        throw DeciderUnsupportedException(
          'The option "${listed[i].id}" is a prefix of another option, so no '
          'prefix of it is unique.',
        );
      }
    }
    if (k == ids.length) {
      texts.add('${listed[i].id}${section.terminator}');
      lengths.add(ids.length);
      continue;
    }
    final prefix = ids.sublist(0, k);
    final text = await scorer.detokenize(prefix);
    if (_sameIds(await scorer.tokenize(text), prefix)) {
      texts.add(text);
      lengths.add(k);
    } else {
      texts.add('${listed[i].id}${section.terminator}');
      lengths.add(ids.length);
    }
  }
  if (!_sameIds(lengths, section.scoredLengths)) {
    throw DeciderUnsupportedException(
      'This engine scores the options on $lengths tokens, and the model was '
      'calibrated on ${section.scoredLengths}: its tokenizer splits an option '
      'another way, so the fitted temperature and threshold do not apply.',
    );
  }
  return (
    texts: List<String>.unmodifiable(texts),
    wholeTargetIds: List<List<int>>.unmodifiable([
      for (final ids in whole) List<int>.unmodifiable(ids),
    ]),
  );
}

bool _sharesPrefix(List<List<int>> all, int i, int k) {
  final mine = _head(all[i], k);
  for (var j = 0; j < all.length; j++) {
    if (j != i && _sameIds(_head(all[j], k), mine)) return true;
  }
  return false;
}

List<int> _head(List<int> ids, int k) =>
    ids.sublist(0, math.min(k, ids.length));

bool _sameIds(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The decider of an `InferenceModel` whose engine scores options. Borrows
/// the model and never closes it.
final class OptionScoringDecider extends Decider {
  OptionScoringDecider._(
    this._model,
    this._scorer,
    this._section,
    this.options,
    this._targets,
  ) : _listedIndex = {
        for (var i = 0; i < _section.listed.length; i++)
          _section.listed[i].id: i,
      };

  final OptionScoringModel _model;
  final OptionScorer _scorer;
  final DecisionSection _section;
  final List<String> _targets;
  final Map<String, int> _listedIndex;

  Future<void>? _closing;

  @override
  final List<DeciderOption> options;

  @override
  DeciderCapabilities get capabilities => DeciderCapabilities(
    modalities: const {EmbeddingModality.text},
    calibratedProbabilities: true,
    supportsContext: false,
    supportsAmong: false,
    storable: false,
    questionType: _section.type,
  );

  @override
  bool get isClosed => _closing != null || _model.isClosed;

  @override
  Future<void> close() => _closing ??= _scorer.close();

  /// [call] on the scorer, failing with `DeciderCancelledException` when the
  /// request was cancelled or the decider closed before or while it ran — a
  /// closed scorer's own `StateError` included.
  Future<T> _scorerCall<T>(
    CancelToken? token,
    Future<T> Function() call,
  ) async {
    _stillWanted(token);
    final T result;
    try {
      result = await call();
    } on StateError {
      _stillWanted(token);
      rethrow;
    }
    _stillWanted(token);
    return result;
  }

  void _stillWanted(CancelToken? token) {
    throwIfDeciderCancelled(token);
    if (_closing != null) {
      throw const DeciderCancelledException('The decider was closed.');
    }
  }

  /// The decision running now, or the last one; the next waits for it.
  Future<void> _lane = Future<void>.value();

  /// One decision at a time: [OptionScorer] promises its engine one call at a
  /// time, and two `choose` calls left unawaited would interleave theirs. A
  /// cancel still answers at once while the decision waits its turn; a
  /// decision that was waiting when [close] came fails as cancelled, as the
  /// running one does.
  @override
  Future<DeciderAnswer> decide(DeciderRequest request) {
    final queuedOpen = _closing == null;
    final answer = _lane.then((_) => _decide(request, queuedOpen: queuedOpen));
    _lane = answer.then<void>((_) {}, onError: (Object _) {});
    final token = request.cancelToken;
    if (token == null) return answer;
    final out = Completer<DeciderAnswer>();
    unawaited(
      token.whenCancelled.then((_) {
        if (!out.isCompleted) {
          out.completeError(
            const DeciderCancelledException('The decision was cancelled.'),
          );
        }
      }),
    );
    unawaited(
      answer.then(
        (value) {
          if (!out.isCompleted) out.complete(value);
        },
        onError: (Object e, StackTrace st) {
          if (!out.isCompleted) out.completeError(e, st);
        },
      ),
    );
    return out.future;
  }

  Future<DeciderAnswer> _decide(
    DeciderRequest request, {
    required bool queuedOpen,
  }) async {
    if (_closing != null && queuedOpen) {
      throw const DeciderCancelledException('The decider was closed.');
    }
    if (isClosed) {
      throw StateError(
        _closing != null
            ? 'The decider is closed.'
            : 'The decider\'s model is closed.',
      );
    }
    final state = request.input.input.text!;
    if (state.trim().isEmpty) {
      throw ArgumentError.value(
        state,
        'input',
        'is empty: there is no state to decide about',
      );
    }
    for (final marker in decisionControlText) {
      if (state.contains(marker)) {
        throw ArgumentError.value(
          state,
          'input',
          'contains $marker, which the chat template would read as a control '
              'token rather than as part of the state; the model was never '
              'trained on such a prompt',
        );
      }
    }
    final token = request.cancelToken;
    final watch = Stopwatch()..start();
    final rendered = await _scorerCall(
      token,
      () => _scorer.renderUserMessage(_section.render(state)),
    );
    if (rendered.isEmpty) {
      throw const DeciderUnsupportedException(
        'The engine rendered the prompt as empty text.',
      );
    }
    final ids = await _scorerCall(token, () => _scorer.tokenize(rendered));
    final needed = ids.length + 2 + _section.scoredLengths.reduce(math.max);
    if (needed > _model.maxTokens) {
      throw ArgumentError.value(
        state,
        'input',
        'renders to a prompt of ${ids.length} tokens; with its targets the '
            'decision needs $needed, more than the model\'s context '
            '(maxTokens ${_model.maxTokens}). It is never truncated: shorten '
            'the input, or load the model with a larger maxTokens',
      );
    }
    final renderTime = watch.elapsed;
    final run = await _scorerCall(
      token,
      () => _scorer.score(rendered, _targets, cancelToken: token),
    );
    final sums = _sums(run);
    return _answer(
      request,
      sums,
      encodeTime: renderTime + run.prefillTime,
      scoreTime: run.scoreTime,
    );
  }

  /// Each listed option's score, summed over its tokens, after checking that
  /// the engine returned log-probabilities of the right shape.
  List<double> _sums(OptionScoringRun run) {
    if (run.tokenScores.length != _targets.length) {
      throw DeciderUnsupportedException(
        'The engine returned scores for ${run.tokenScores.length} targets, '
        'and was asked for ${_targets.length}.',
      );
    }
    final sums = <double>[];
    for (var j = 0; j < _targets.length; j++) {
      final scores = run.tokenScores[j];
      final id = _section.listed[j].id;
      if (scores.length != _section.scoredLengths[j]) {
        throw DeciderUnsupportedException(
          'The engine scored ${scores.length} tokens of the option "$id"; its '
          'target has ${_section.scoredLengths[j]}.',
        );
      }
      for (final s in scores) {
        if (!(s <= _maxTokenScore)) {
          throw DeciderUnsupportedException(
            'The engine scored a token of the option "$id" $s: not a '
            'log-probability, which is never above 0.',
          );
        }
      }
      sums.add(scores.fold(0.0, (a, s) => a + s));
    }
    final m = sums.reduce(math.max);
    final lse = m + math.log(sums.fold(0.0, (a, s) => a + math.exp(s - m)));
    if (!(lse <= _maxLogSumExp)) {
      throw DeciderUnsupportedException(
        'The options\' probabilities sum to ${math.exp(lse)}, above 1: the '
        'engine does not return log-probabilities.',
      );
    }
    return sums;
  }

  DeciderAnswer _answer(
    DeciderRequest request,
    List<double> listedSums, {
    required Duration encodeTime,
    required Duration scoreTime,
  }) {
    // Candidates in the order the app gave its options (choose's order and
    // its tie-break); each scored where the prompt listed it.
    final ids = request.candidates;
    final n = ids.length;
    final s = [for (final id in ids) listedSums[_listedIndex[id]!]];
    final t = _section.temperature;
    var m = double.negativeInfinity;
    for (final x in s) {
      m = math.max(m, x);
    }
    var sum = 0.0;
    var sumT = 0.0;
    for (final x in s) {
      sum += math.exp(x - m);
      sumT += math.exp((x - m) / t);
    }
    final logSum = m + math.log(sum);
    final p = [for (final x in s) math.exp((x - m) / t) / sumT];
    // Ranked by the raw sums, so the first is the most probable option too.
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final bySum = s[b].compareTo(s[a]);
        return bySum != 0 ? bySum : a.compareTo(b);
      });
    final top = order.first;
    final probabilities = {for (var i = 0; i < n; i++) ids[i]: p[i]};
    final type = _section.type;
    AbstainReason? reason;
    double? threshold;
    if (identical(type, DeciderQuestionType.choice)) {
      threshold = _section.calibrationAbstainBelow;
      if (ids[top] == _section.noneOption) {
        reason = AbstainReason.noneOption;
      } else if (threshold != null && p[top] < threshold) {
        reason = AbstainReason.belowThreshold;
      }
    }
    return DeciderAnswer(
      choice: reason == null ? ids[top] : null,
      ranked: [
        for (final i in order.take(request.topK))
          RankedOption(id: ids[i], score: s[i] - logSum, probability: p[i]),
      ],
      scoreKind: ScoreKind.logprob,
      margin: n >= 2 ? s[order[0]] - s[order[1]] : double.infinity,
      confidence: n >= 2 ? deciderConfidence(p[top], n) : null,
      abstainReason: reason,
      probabilities: probabilities,
      provenance: DeciderProvenance(
        method: DeciderMethod.optionScoring,
        calibration: 'supplied',
        encodeTime: encodeTime,
        scoreTime: scoreTime,
        threshold: threshold,
        abstainSignal: p[top],
        abstainSignalKind: AbstainSignalKind.topProbability,
      ),
      questionType: type,
      legend: identical(type, DeciderQuestionType.score)
          ? {for (final o in _section.options) o.id: o.description!}
          : null,
    );
  }
}
