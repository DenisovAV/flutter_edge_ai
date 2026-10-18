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
// - the targets, the self-check and the scoring: `decision_scripts`
//   ENGINE_SCRIPT;
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

/// The pair the self-check compares: the same text ending in the model turn's
/// opening and in the user turn's (`decision_scripts.FIXED`).
const _selfCheckPrompt =
    '<start_of_turn>user\nAnswer with one word.<end_of_turn>\n'
    '<start_of_turn>model\n';

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
    if (type is! String || !const {'choice', 'noul', 'score'}.contains(type)) {
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
      type: switch (type) {
        'noul' => DeciderQuestionType.noul,
        'score' => DeciderQuestionType.score,
        _ => DeciderQuestionType.choice,
      },
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
  List<DecisionOption> get listed => [
    ...options,
    if (noneOption case final none?) DecisionOption(none),
  ];

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

/// How the engine is scored right after a prefill: `once` re-prefills the
/// prompt's last token once per decision (LiteRT-LM 0.18.0 drops the token
/// before it, #3561), `plain` scores as is (an engine with the fix).
enum OptionScoringMode { once, plain }

/// The mode each model's self-check picked, run once per loaded model.
final _modes = Expando<Future<OptionScoringMode>>('option scoring mode');

/// [InferenceModel.createDecider] on a model whose engine scores options.
Future<Decider> createOptionScoringDecider(
  InferenceModel model,
  OptionScoringModel engine, {
  required String question,
  required List<DeciderOption> options,
  required InferenceDeciderCalibration calibration,
  CancelToken? cancelToken,
}) async {
  final String? payload;
  try {
    payload = await engine.readDecisionSection();
  } on FormatException catch (e) {
    throw DeciderUnsupportedException(
      'The model file of ${model.runtimeType} cannot be read for its '
      'decision section: ${e.message}',
    );
  }
  if (payload == null) {
    throw DeciderUnsupportedException(
      'The model file of ${model.runtimeType} carries no decision section '
      '(litetune.decision): it is a chat model, not one trained to decide. '
      'A model tuned for a decision by litetune carries one when its verify '
      'passed; use EmbeddingModel.createDecider for any other.',
    );
  }
  final DecisionSection section;
  try {
    section = DecisionSection.parse(payload);
  } on FormatException catch (e) {
    throw DeciderUnsupportedException(
      'The decision section of the model file of ${model.runtimeType} is not '
      'one this release reads: ${e.message}',
    );
  }
  checkAgainstDecisionSection(
    section,
    question: question,
    options: options,
    calibration: calibration,
  );
  throwIfDeciderCancelled(cancelToken);
  final scorer = await engine.openOptionScorer();
  try {
    final targets = await optionTargets(scorer, section);
    throwIfDeciderCancelled(cancelToken);
    final mode = await _modeOf(engine, scorer, targets.continuations);
    throwIfDeciderCancelled(cancelToken);
    return OptionScoringDecider._(
      model,
      scorer,
      section,
      List.unmodifiable(options),
      targets.texts,
      mode,
    );
  } catch (_) {
    await scorer.close();
    rethrow;
  }
}

/// Throws [ArgumentError] unless [question], [options] and [calibration] are
/// the ones [section] was trained and fitted with. The app's option order
/// may differ: the prompt lists the trained order.
void checkAgainstDecisionSection(
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
  final missing = listed.keys.where((id) => !given.contains(id)).toList();
  if (missing.isNotEmpty) {
    throw ArgumentError.value(
      missing,
      'options',
      'are trained options the call leaves out. A subset of the trained '
          'options is not measured; pass all of '
          '${listed.keys.toList()}',
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
  if (calibration.temperature != section.temperature) {
    throw ArgumentError.value(
      calibration.temperature,
      'calibration.temperature',
      'is not the temperature fitted for this model (${section.temperature})',
    );
  }
  final below = section.calibrationAbstainBelow;
  if (calibration.abstainBelow != below) {
    throw ArgumentError.value(
      calibration.abstainBelow,
      'calibration.abstainBelow',
      'is not the threshold fitted for this model ($below)',
    );
  }
  if (calibration.noneOption != section.noneOption) {
    throw ArgumentError.value(
      calibration.noneOption,
      'calibration.noneOption',
      'is not the none option this model was trained with '
          '(${section.noneOption})',
    );
  }
}

/// Each listed option's target text and the token ids of its whole target
/// (`<id><terminator>`).
typedef OptionTargets = ({List<String> texts, List<List<int>> continuations});

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
  final continuations = [
    for (final option in listed)
      await scorer.tokenize('${option.id}${section.terminator}'),
  ];
  for (var i = 0; i < listed.length; i++) {
    if (continuations[i].isEmpty) {
      throw DeciderUnsupportedException(
        'The option "${listed[i].id}" tokenises to nothing.',
      );
    }
  }
  final texts = <String>[];
  final lengths = <int>[];
  for (var i = 0; i < listed.length; i++) {
    final ids = continuations[i];
    var k = 1;
    while (_sharesPrefix(continuations, i, k)) {
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
    continuations: List<List<int>>.unmodifiable(continuations),
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

Future<OptionScoringMode> _modeOf(
  OptionScoringModel engine,
  OptionScorer scorer,
  List<List<int>> continuations,
) {
  final known = _modes[engine];
  if (known != null) return known;
  final check = optionScoringSelfCheck(scorer, continuations);
  _modes[engine] = check;
  // A check that failed runs again for the next decider: it may have failed
  // on a closed model rather than on the engine.
  unawaited(
    check.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_modes[engine], check)) _modes[engine] = null;
      },
    ),
  );
  return check;
}

/// Whether this engine scores right after a prefill without the prompt's
/// second-to-last token (LiteRT-LM #3561), from two prompts that differ only
/// in that token: identical scores mean it is dropped ([OptionScoringMode.once]),
/// different ones that it is not ([OptionScoringMode.plain]). Each of the first
/// three options' first token that tokenises back to itself is scored on
/// both, twice. A mix, or no comparison at all, is an engine nobody measured:
/// `DeciderUnsupportedException`.
Future<OptionScoringMode> optionScoringSelfCheck(
  OptionScorer scorer,
  List<List<int>> continuations,
) async {
  final probes = <String>[];
  for (var j = 0; j < math.min(3, continuations.length); j++) {
    final first = continuations[j].first;
    final z = await scorer.detokenize([first]);
    if (_sameIds(await scorer.tokenize(z), [first])) probes.add(z);
  }
  const a = _selfCheckPrompt;
  final b = '${a.substring(0, a.length - 'model\n'.length)}user\n';
  final ia = await scorer.tokenize(a);
  final ib = await scorer.tokenize(b);
  final differing = [
    for (var i = 0; i < math.min(ia.length, ib.length); i++)
      if (ia[i] != ib[i]) i,
  ];
  final diffs = <double>[];
  if (ia.length == ib.length &&
      differing.length == 1 &&
      differing.single == ia.length - 2) {
    for (final z in probes) {
      for (var repeat = 0; repeat < 2; repeat++) {
        diffs.add(
          (await _oneToken(scorer, a, z) - await _oneToken(scorer, b, z)).abs(),
        );
      }
    }
  }
  if (diffs.isEmpty) {
    throw const DeciderUnsupportedException(
      'The scoring self-check had nothing to compare: none of the first three '
      'options starts with a token that tokenises back to itself, or the '
      'check\'s two prompts do not differ in their second-to-last token alone. '
      'Without it the engine\'s scoring mode cannot be told.',
    );
  }
  final most = diffs.reduce(math.max);
  final least = diffs.reduce(math.min);
  if (most == 0) return OptionScoringMode.once;
  if (least > 0) return OptionScoringMode.plain;
  throw DeciderUnsupportedException(
    'The scoring self-check is mixed: of ${diffs.length} comparisons some '
    'scored identically and some did not (largest difference $most). This '
    'engine scores in a way nobody has measured.',
  );
}

Future<double> _oneToken(OptionScorer scorer, String prompt, String z) async {
  final run = await scorer.score(prompt, [z]);
  final scores = run.tokenScores.single;
  if (scores.length != 1) {
    throw DeciderUnsupportedException(
      'The one-token target "$z" scored ${scores.length} tokens.',
    );
  }
  return scores.single;
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
    this.mode,
  ) : _listedIndex = {
        for (var i = 0; i < _section.listed.length; i++)
          _section.listed[i].id: i,
      };

  final InferenceModel _model;
  final OptionScorer _scorer;
  final DecisionSection _section;
  final List<String> _targets;
  final Map<String, int> _listedIndex;

  /// The scoring mode the model's self-check picked.
  final OptionScoringMode mode;

  bool _closed = false;

  @override
  final List<DeciderOption> options;

  @override
  DeciderCapabilities get capabilities => const DeciderCapabilities(
    modalities: {EmbeddingModality.text},
    calibratedProbabilities: true,
    supportsContext: false,
    supportsAmong: false,
    storable: false,
  );

  @override
  bool get isClosed => _closed || _model.isClosed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _scorer.close();
  }

  void _stillWanted(CancelToken? token) {
    throwIfDeciderCancelled(token);
    if (_closed) {
      throw const DeciderCancelledException('The decider was closed.');
    }
  }

  @override
  Future<DeciderAnswer> decide(DeciderRequest request) async {
    if (isClosed) {
      throw StateError(
        _closed ? 'The decider is closed.' : 'The decider\'s model is closed.',
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
    final rendered = await _scorer.renderUserMessage(_section.render(state));
    _stillWanted(token);
    if (rendered.isEmpty || rendered.startsWith('<bos>')) {
      throw DeciderUnsupportedException(
        'The engine rendered the prompt as '
        '${rendered.isEmpty ? 'empty text' : 'text that starts with <bos>, '
                  'which the scoring session adds itself'}.',
      );
    }
    final ids = await _scorer.tokenize(rendered);
    if (ids.isEmpty) {
      throw const DeciderUnsupportedException(
        'The engine tokenised the rendered prompt to nothing.',
      );
    }
    final last = await _scorer.detokenize([ids.last]);
    if (!rendered.endsWith(last) ||
        !_sameIds(await _scorer.tokenize(last), [ids.last])) {
      throw DeciderUnsupportedException(
        'The prompt\'s last token ${ids.last} does not round-trip as '
        '${jsonEncode(last)}, so it cannot be prefilled again on its own.',
      );
    }
    final renderTime = watch.elapsed;
    _stillWanted(token);
    final run = await _scorer.score(
      rendered,
      _targets,
      reprefill: mode == OptionScoringMode.once ? last : null,
      cancelToken: token,
    );
    _stillWanted(token);
    final sums = <double>[];
    for (var j = 0; j < _targets.length; j++) {
      final scores = j < run.tokenScores.length ? run.tokenScores[j] : null;
      if (scores == null ||
          scores.length != _section.scoredLengths[j] ||
          scores.any((s) => !s.isFinite)) {
        throw DeciderUnsupportedException(
          'The engine returned no usable scores for the option '
          '"${_section.listed[j].id}": $scores.',
        );
      }
      sums.add(scores.fold(0.0, (a, s) => a + s));
    }
    return _answer(
      request,
      sums,
      encodeTime: renderTime + run.prefillTime,
      scoreTime: run.scoreTime,
    );
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
    var mt = double.negativeInfinity;
    for (final x in s) {
      m = math.max(m, x);
      mt = math.max(mt, x / t);
    }
    var sum = 0.0;
    var sumT = 0.0;
    for (final x in s) {
      sum += math.exp(x - m);
      sumT += math.exp(x / t - mt);
    }
    final logSum = m + math.log(sum);
    final scores = [for (final x in s) x - logSum];
    final p = [for (final x in s) math.exp(x / t - mt) / sumT];
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final byScore = scores[b].compareTo(scores[a]);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
    final top = order.first;
    final pmax = p.reduce(math.max);
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
    double? expectedLevel;
    if (identical(type, DeciderQuestionType.score)) {
      expectedLevel = 0;
      for (var i = 0; i < n; i++) {
        expectedLevel = expectedLevel! + p[i] * int.parse(ids[i]);
      }
    }
    return DeciderAnswer(
      choice: reason == null ? ids[top] : null,
      ranked: [
        for (final i in order.take(request.topK))
          RankedOption(id: ids[i], score: scores[i], probability: p[i]),
      ],
      scoreKind: ScoreKind.logprob,
      margin: n >= 2 ? scores[order[0]] - scores[order[1]] : double.infinity,
      confidence: n >= 2 ? deciderConfidence(pmax, n) : null,
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
      noul: identical(type, DeciderQuestionType.noul)
          ? probabilities['yes']
          : null,
      expectedLevel: expectedLevel,
      legend: identical(type, DeciderQuestionType.score)
          ? {for (final o in _section.options) o.id: o.description!}
          : null,
    );
  }
}
