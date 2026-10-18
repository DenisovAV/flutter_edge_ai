// InferenceModel.createDecider over an engine that scores options, with the
// engine scripted: the parts of the decider that need no model. The decider
// on real models is example/integration_test/litertlm_inference_decider_test.dart.
//
// Fixtures:
// - decision-contract-v1.json: litetune's renderer contract, byte for byte as
//   litetune 0.5.0 ships it (`tests/fixtures/`);
// - decisions-golden-v1-scores.json: the numbers of litetune's golden pack
//   decisions-golden-v1 — the section, and per row the engine's token scores
//   with the probabilities and the answer litetune computed from them.
// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/decision/option_scoring_decider.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'test/decision/fixtures';

/// litetune's contract fixture at 0.5.0 (`46199f4`), pinned by its digest.
const _contractSha256 =
    'bcac6b4fd2f3131b9bb713d9aa5d9270a4dc7707b411985861fa1c7ce552a051';

const _fixed =
    '<start_of_turn>user\nAnswer with one word.<end_of_turn>\n'
    '<start_of_turn>model\n';
final _fixedUser = '${_fixed.substring(0, _fixed.length - 6)}user\n';

Map<String, Object?> _golden() =>
    jsonDecode(
          File('$_fixtures/decisions-golden-v1-scores.json').readAsStringSync(),
        )
        as Map<String, Object?>;

/// A section payload from a contract decision, with the scoring keys added.
Map<String, Object?> _section(
  Map<String, Object?> decision, {
  double temperature = 1.0,
  double? abstainBelow,
}) {
  final listed =
      (decision['options'] as List).length +
      (decision['none_option'] == null ? 0 : 1);
  final choice = decision['type'] == 'choice';
  return {
    ...decision,
    'scoring': 'unique_prefix',
    'terminator': '<end_of_turn>',
    'scored_lengths': List.filled(listed, 1),
    'temperature': temperature,
    'abstain_rule': choice ? 'error_budget' : null,
    'abstain_below': choice ? (abstainBelow ?? 0.5) : null,
  };
}

List<DeciderOption> _optionsOf(Map<String, Object?> payload) => [
  for (final o in (payload['options'] as List).cast<Map<String, Object?>>())
    DeciderOption(o['id'] as String, description: o['description'] as String?),
  if (payload['none_option'] case final String none) DeciderOption(none),
];

InferenceDeciderCalibration _calibrationOf(Map<String, Object?> payload) {
  final below = (payload['abstain_below'] as num?)?.toDouble();
  return InferenceDeciderCalibration(
    temperature: (payload['temperature'] as num).toDouble(),
    abstainBelow: below == null || below == 0 ? null : below,
    noneOption: payload['none_option'] as String?,
  );
}

/// An engine with a table for a tokenizer. Text it has no entry for is a
/// rendered prompt: [_promptIds], ending in `\n`.
final class _Scorer implements OptionScorer {
  _Scorer(this.pieces, {this.selfCheck});

  /// Token id → its text. A text tokenises to the ids whose pieces spell it,
  /// when [_tokens] has it.
  final Map<int, String> pieces;
  final Map<String, List<int>> _tokens = {};

  /// The score of one self-check token after one of the two fixed prompts.
  double Function(String prompt, String token)? selfCheck;

  /// The scores of a decision's targets, by target text.
  Map<String, List<double>>? optionScores;

  int selfCheckCalls = 0;
  int scoreCalls = 0;
  String? lastPrompt;
  String? lastReprefill;
  List<String>? lastTargets;
  String Function(String content)? render;
  bool closed = false;

  static const _promptIds = [
    105,
    2364,
    107,
    900,
    901,
    106,
    107,
    105,
    4368,
    107,
  ];

  void spell(String text, List<int> ids) => _tokens[text] = ids;

  @override
  Future<List<int>> tokenize(String text) async =>
      _tokens[text] ?? (text == '\n' ? [107] : _promptIds);

  @override
  Future<String> detokenize(List<int> ids) async =>
      ids.map((id) => pieces[id] ?? '<$id>').join();

  @override
  Future<String> renderUserMessage(String content) async =>
      render?.call(content) ??
      '<start_of_turn>user\n$content<end_of_turn>\n<start_of_turn>model\n';

  @override
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    String? reprefill,
    CancelToken? cancelToken,
  }) async {
    if (prompt == _fixed || prompt == _fixedUser) {
      selfCheckCalls++;
      return OptionScoringRun(
        tokenScores: [
          for (final t in targets) [selfCheck!(prompt, t)],
        ],
        prefillTime: Duration.zero,
        scoreTime: Duration.zero,
      );
    }
    scoreCalls++;
    lastPrompt = prompt;
    lastReprefill = reprefill;
    lastTargets = targets;
    return OptionScoringRun(
      tokenScores: [for (final t in targets) optionScores![t]!],
      prefillTime: const Duration(milliseconds: 3),
      scoreTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<void> close() async => closed = true;
}

/// The two fixed self-check prompts, differing in their second-to-last token
/// alone.
void _spellFixedPair(_Scorer s) {
  s.spell(_fixed, [
    105,
    2364,
    107,
    7925,
    607,
    886,
    3658,
    236761,
    106,
    107,
    105,
    4368,
    107,
  ]);
  s.spell(_fixedUser, [
    105,
    2364,
    107,
    7925,
    607,
    886,
    3658,
    236761,
    106,
    107,
    105,
    2364,
    107,
  ]);
}

/// An engine that drops the second-to-last token (LiteRT-LM 0.18.0).
double _dropped(String prompt, String token) => -1.5;

/// An engine with the #3561 fix: the two prompts score differently.
double _notDropped(String prompt, String token) =>
    prompt == _fixed ? -1.5 : -2.0;

final class _Model extends InferenceModel implements OptionScoringModel {
  _Model(this.payload, this.scorer);

  final String? payload;
  final _Scorer scorer;
  int opened = 0;
  bool closedModel = false;

  @override
  bool get isClosed => closedModel;

  @override
  Future<String?> readDecisionSection() async => payload;

  @override
  Future<OptionScorer> openOptionScorer() async {
    opened++;
    return scorer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The emotion golden pack's engine: its option tokens and their pieces.
_Scorer _emotionScorer() {
  final s = _Scorer({
    37918: 'sad',
    1788: 'ness',
    106: '<end_of_turn>',
    3672: 'joy',
    21867: 'love',
    4751: 'anger',
    143355: 'fear',
    192564: 'surprise',
    107: '\n',
  }, selfCheck: _dropped);
  final ids = (_golden()['option_token_ids'] as List).cast<List>();
  const options = ['sadness', 'joy', 'love', 'anger', 'fear', 'surprise'];
  for (var i = 0; i < options.length; i++) {
    final row = ids[i].cast<int>();
    s.spell('${options[i]}<end_of_turn>', row);
    s.spell(s.pieces[row.first]!, [row.first]);
  }
  _spellFixedPair(s);
  return s;
}

void main() {
  group('the prompt: litetune\'s contract, byte for byte', () {
    final bytes = File(
      '$_fixtures/decision-contract-v1.json',
    ).readAsBytesSync();
    final contract = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

    test('the fixture is litetune\'s', () {
      expect(sha256.convert(bytes).toString(), _contractSha256);
      expect(contract['contract_version'], decisionContractVersion);
    });

    for (final c in (contract['cases'] as List).cast<Map<String, Object?>>()) {
      test('${c['name']}', () {
        final decision = c['decision'] as Map<String, Object?>;
        final section = DecisionSection.parse(jsonEncode(_section(decision)));
        expect(section.render(c['state'] as String), c['prompt']);
        expect(section.type.name, decision['type']);
        // The trained answer is one the prompt lists.
        final completion = c['completion'] as String;
        expect(section.listed.map((o) => o.id), contains(completion));
      });
    }
  });

  group('the section', () {
    final golden = _golden();
    final payload = golden['payload'] as Map<String, Object?>;

    test('the golden pack\'s reads as written', () {
      final section = DecisionSection.parse(golden['payload_text'] as String);
      expect(section.type, DeciderQuestionType.choice);
      expect(section.question, payload['question']);
      expect(section.listed.map((o) => o.id), [
        'sadness', 'joy', 'love', 'anger', 'fear', 'surprise', //
      ]);
      expect(section.temperature, payload['temperature']);
      expect(section.abstainBelow, payload['abstain_below']);
      expect(section.abstainRule, 'error_budget');
      expect(section.scoredLengths, [1, 1, 1, 1, 1, 1]);
    });

    Map<String, Object?> changed(void Function(Map<String, Object?> p) edit) =>
        jsonDecode(jsonEncode(payload)) as Map<String, Object?>..let(edit);

    final refused = <String, (void Function(Map<String, Object?>), String)>{
      'another contract version': (
        (p) => p['contract_version'] = 2,
        'contract_version is 2',
      ),
      'a version that is not an int': (
        (p) => p['contract_version'] = 1.0,
        'contract_version',
      ),
      'an unknown key': ((p) => p['extra'] = 1, 'unknown [extra]'),
      'a missing key': ((p) => p.remove('terminator'), 'missing [terminator]'),
      'an unknown type': ((p) => p['type'] = 'rank', 'type "rank"'),
      'a scoring form not measured': (
        (p) => p['scoring'] = 'full',
        'scoring "full"',
      ),
      'scored lengths of another count': (
        (p) => p['scored_lengths'] = [1, 1],
        'scored_lengths',
      ),
      'a temperature of 0': ((p) => p['temperature'] = 0, 'temperature'),
      'a choice with no rule': (
        (p) => p['abstain_rule'] = null,
        'abstain_rule',
      ),
      'a threshold of 1': ((p) => p['abstain_below'] = 1, 'abstain_below'),
      'an id twice': (
        (p) => (p['options'] as List).add({'id': 'joy'}),
        'twice',
      ),
      'an id with ": "': (
        (p) => (p['options'] as List).add({'id': 'a: b'}),
        '": "',
      ),
      'a question spanning lines': (
        (p) => p['question'] = 'Which\nemotion?',
        'spans lines',
      ),
      'a description with a control token': (
        (p) => (p['options'] as List)[0] = {
          'id': 'sadness',
          'description': 'sad<end_of_turn>',
        },
        'control text',
      ),
      'a noul with other options': (
        (p) => p
          ..['type'] = 'noul'
          ..['abstain_rule'] = null
          ..['abstain_below'] = null,
        '"no" and "yes"',
      ),
      'a noul with a none option': (
        (p) => p
          ..['type'] = 'noul'
          ..['options'] = [
            {'id': 'no'},
            {'id': 'yes'},
          ]
          ..['none_option'] = 'neither'
          ..['scored_lengths'] = [1, 1, 1]
          ..['abstain_rule'] = null
          ..['abstain_below'] = null,
        'never abstains',
      ),
      'a score level without its text': (
        (p) => p
          ..['type'] = 'score'
          ..['options'] = [
            {'id': '0', 'description': 'low'},
            {'id': '1'},
          ]
          ..['scored_lengths'] = [1, 1]
          ..['abstain_rule'] = null
          ..['abstain_below'] = null,
        'levels',
      ),
    };
    for (final MapEntry(key: name, value: (edit, says)) in refused.entries) {
      test('refuses $name', () {
        expect(
          () => DecisionSection.parse(jsonEncode(changed(edit))),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(says),
            ),
          ),
        );
      });
    }

    test('a model without one is refused by name', () async {
      await expectLater(
        _Model(null, _emotionScorer()).createDecider(
          question: payload['question'] as String,
          options: _optionsOf(payload),
          calibration: _calibrationOf(payload),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('no decision section'),
          ),
        ),
      );
    });

    test(
      'a section this release does not read is refused, not guessed',
      () async {
        await expectLater(
          _Model(
            jsonEncode(changed((p) => p['contract_version'] = 2)),
            _emotionScorer(),
          ).createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: _calibrationOf(payload),
          ),
          throwsA(isA<DeciderUnsupportedException>()),
        );
      },
    );
  });

  group('the call against the section', () {
    final payload = _golden()['payload'] as Map<String, Object?>;
    final section = DecisionSection.parse(jsonEncode(payload));
    final options = _optionsOf(payload);
    final calibration = _calibrationOf(payload);
    final question = payload['question'] as String;

    void check({
      String? q,
      List<DeciderOption>? o,
      InferenceDeciderCalibration? c,
    }) => checkAgainstDecisionSection(
      section,
      question: q ?? question,
      options: o ?? options,
      calibration: c ?? calibration,
    );

    Matcher refusing(String name, String says) => throwsA(
      isA<ArgumentError>()
          .having((e) => e.name, 'name', name)
          .having((e) => e.message, 'message', contains(says)),
    );

    test('the trained ones pass, in any order, a description equal to its id '
        'too', () {
      check();
      check(o: options.reversed.toList());
      check(
        o: [for (final o in options) DeciderOption(o.id, description: o.id)],
      );
    });

    test('another question is refused, naming the trained one', () {
      expect(() => check(q: 'Which emotion?'), refusing('question', question));
    });

    test('a subset is refused', () {
      expect(
        () => check(o: options.sublist(1)),
        refusing('options', 'leaves out'),
      );
    });

    test('an option not trained is refused', () {
      expect(
        () => check(o: [...options, DeciderOption('calm')]),
        refusing('options', 'not options this model was trained on'),
      );
    });

    test('another description is refused', () {
      expect(
        () => check(
          o: [
            DeciderOption('sadness', description: 'blue'),
            ...options.skip(1),
          ],
        ),
        refusing('options', 'trained without a description'),
      );
    });

    test('another temperature, threshold or none option is refused', () {
      expect(
        () => check(c: const InferenceDeciderCalibration(temperature: 1.0)),
        refusing('calibration.temperature', '${payload['temperature']}'),
      );
      expect(
        () => check(
          c: InferenceDeciderCalibration(temperature: calibration.temperature),
        ),
        refusing('calibration.abstainBelow', '${payload['abstain_below']}'),
      );
      expect(
        () => check(
          o: [...options, DeciderOption('none')],
          c: InferenceDeciderCalibration(
            temperature: calibration.temperature,
            abstainBelow: calibration.abstainBelow,
            noneOption: 'none',
          ),
        ),
        refusing('options', 'not options this model was trained on'),
      );
    });

    test('a threshold of 0 is passed as none: it never abstains', () {
      final zero = DecisionSection.parse(
        jsonEncode({...payload, 'abstain_below': 0}),
      );
      expect(zero.calibrationAbstainBelow, isNull);
      checkAgainstDecisionSection(
        zero,
        question: question,
        options: options,
        calibration: InferenceDeciderCalibration(
          temperature: calibration.temperature,
        ),
      );
    });
  });

  group('the golden pack\'s arithmetic', () {
    final golden = _golden();
    final payload = golden['payload'] as Map<String, Object?>;
    const ids = ['sadness', 'joy', 'love', 'anger', 'fear', 'surprise'];

    test('every row: litetune\'s probabilities and answer from its engine '
        'scores, abstentions included', () async {
      final scorer = _emotionScorer();
      final model = _Model(golden['payload_text'] as String, scorer);
      final decider = await model.createDecider(
        question: payload['question'] as String,
        options: _optionsOf(payload),
        calibration: _calibrationOf(payload),
      );
      expect(((decider as dynamic).mode as Enum).name, golden['mode']);
      var abstained = 0;
      for (final row in (golden['rows'] as List).cast<Map<String, Object?>>()) {
        final scores = (row['engine_token_scores'] as List).cast<List>();
        scorer.optionScores = {
          for (var j = 0; j < ids.length; j++)
            scorer.pieces[((golden['option_token_ids'] as List)[j] as List)
                .first]!: scores[j]
                .cast<num>()
                .map((s) => s.toDouble())
                .toList(),
        };
        final answer = await decider.choose(
          DeciderInput(EmbeddingInput.text('state ${row['index']}')),
          topK: ids.length,
        );
        final want = (row['probabilities'] as List).cast<num>();
        for (var j = 0; j < ids.length; j++) {
          expect(answer.probabilities![ids[j]], closeTo(want[j], 1e-12));
        }
        expect(answer.ranked.first.id, row['engine_argmax']);
        expect(answer.choice, row['answer'], reason: 'row ${row['index']}');
        if (row['answer'] == null) {
          abstained++;
          expect(answer.abstainReason, AbstainReason.belowThreshold);
          expect(
            answer.provenance.abstainSignal,
            lessThan(payload['abstain_below'] as num),
          );
        }
        expect(answer.provenance.method, DeciderMethod.optionScoring);
        expect(
          answer.provenance.abstainSignalKind,
          AbstainSignalKind.topProbability,
        );
        expect(answer.provenance.threshold, payload['abstain_below']);
        expect(answer.scoreKind, ScoreKind.logprob);
        expect(answer.questionType, DeciderQuestionType.choice);
        // One decision is one scoring pass, the last token prefilled again
        // (mode once), on the trained order's unique prefixes.
        expect(scorer.lastReprefill, '\n');
        expect(scorer.lastTargets, [
          'sad',
          'joy',
          'love',
          'anger',
          'fear',
          'surprise',
        ]);
        expect(scorer.lastPrompt, contains('Options:\n- sadness\n- joy\n'));
      }
      expect(abstained, 2);
      await decider.close();
      expect(scorer.closed, isTrue);
    });
  });

  group('the self-check', () {
    final golden = _golden();
    final payload = golden['payload'] as Map<String, Object?>;

    Future<Decider> create(_Model model) => model.createDecider(
      question: payload['question'] as String,
      options: _optionsOf(payload),
      calibration: _calibrationOf(payload),
    );

    test('identical scores pick once, different ones plain; it runs once per '
        'model', () async {
      final scorer = _emotionScorer();
      final model = _Model(golden['payload_text'] as String, scorer);
      expect(_modeName(await create(model)), 'once');
      // First three options' first tokens, twice each, on both prompts.
      expect(scorer.selfCheckCalls, 12);
      await create(model);
      expect(scorer.selfCheckCalls, 12, reason: 'cached for the model');

      final fixed = _emotionScorer()..selfCheck = _notDropped;
      expect(
        _modeName(
          await create(_Model(golden['payload_text'] as String, fixed)),
        ),
        'plain',
      );
    });

    test('a mix of identical and different scores is refused', () async {
      var call = 0;
      final scorer = _emotionScorer()
        ..selfCheck = (prompt, token) =>
            prompt == _fixed ? -1.0 : (call++ < 2 ? -1.0 : -1.3);
      await expectLater(
        create(_Model(golden['payload_text'] as String, scorer)),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('mixed'),
          ),
        ),
      );
      expect(scorer.closed, isTrue);
    });

    test('no comparison at all is refused, not taken for once', () async {
      // Every option starts with `refund`, whose token does not tokenise
      // back to itself; the unique prefixes (three tokens) do.
      final probes = _Scorer({
        1: 'refund',
        2: '_',
        3: 'status',
        4: 'policy',
        5: 'fee',
        106: '<end_of_turn>',
        107: '\n',
      }, selfCheck: _dropped);
      probes
        ..spell('refund_status<end_of_turn>', [1, 2, 3, 106])
        ..spell('refund_policy<end_of_turn>', [1, 2, 4, 106])
        ..spell('refund_fee<end_of_turn>', [1, 2, 5, 106])
        ..spell('refund_status', [1, 2, 3])
        ..spell('refund_policy', [1, 2, 4])
        ..spell('refund_fee', [1, 2, 5])
        ..spell('refund', [1, 1]);
      _spellFixedPair(probes);
      final refunds = jsonEncode({
        'contract_version': 1,
        'type': 'choice',
        'question': 'What does the customer want?',
        'options': [
          {'id': 'refund_status'},
          {'id': 'refund_policy'},
          {'id': 'refund_fee'},
        ],
        'none_option': null,
        'scoring': 'unique_prefix',
        'terminator': '<end_of_turn>',
        'scored_lengths': [3, 3, 3],
        'temperature': 1.0,
        'abstain_rule': 'error_budget',
        'abstain_below': 0.4,
      });
      await expectLater(
        _Model(refunds, probes).createDecider(
          question: 'What does the customer want?',
          options: [
            DeciderOption('refund_status'),
            DeciderOption('refund_policy'),
            DeciderOption('refund_fee'),
          ],
          calibration: const InferenceDeciderCalibration(
            temperature: 1.0,
            abstainBelow: 0.4,
          ),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('nothing to compare'),
          ),
        ),
      );
      expect(probes.selfCheckCalls, 0);
      // The pair differs elsewhere than its second-to-last token.
      final other = _emotionScorer()
        ..spell(_fixedUser, [
          105,
          2364,
          107,
          7925,
          607,
          886,
          3658,
          236761,
          106,
          107,
          105,
          2364,
          108,
        ]);
      await expectLater(
        create(_Model(golden['payload_text'] as String, other)),
        throwsA(isA<DeciderUnsupportedException>()),
      );
    });

    test('a failed check runs again for the next decider', () async {
      final scorer = _emotionScorer()
        ..selfCheck = (_, _) => throw StateError('engine gone');
      final model = _Model(golden['payload_text'] as String, scorer);
      await expectLater(create(model), throwsStateError);
      scorer.selfCheck = _dropped;
      expect(_modeName(await create(model)), 'once');
    });
  });

  group('the targets', () {
    /// Options `refund_status` and `refund_policy` share their first two
    /// tokens; `cancel` is one token.
    _Scorer scorer() {
      final s = _Scorer({
        1: 'refund',
        2: '_',
        3: 'status',
        4: 'policy',
        5: 'cancel',
        106: '<end_of_turn>',
        107: '\n',
      }, selfCheck: _dropped);
      s
        ..spell('refund_status<end_of_turn>', [1, 2, 3, 106])
        ..spell('refund_policy<end_of_turn>', [1, 2, 4, 106])
        ..spell('cancel<end_of_turn>', [5, 106])
        ..spell('refund_status', [1, 2, 3])
        ..spell('refund_policy', [1, 2, 4])
        ..spell('cancel', [5])
        ..spell('refund', [1]);
      _spellFixedPair(s);
      return s;
    }

    DecisionSection section(List<int> lengths) => DecisionSection.parse(
      jsonEncode({
        'contract_version': 1,
        'type': 'choice',
        'question': 'What does the customer want?',
        'options': [
          {'id': 'refund_status'},
          {'id': 'refund_policy'},
          {'id': 'cancel'},
        ],
        'none_option': null,
        'scoring': 'unique_prefix',
        'terminator': '<end_of_turn>',
        'scored_lengths': lengths,
        'temperature': 1.0,
        'abstain_rule': 'error_budget',
        'abstain_below': 0.4,
      }),
    );

    test('a multi-token unique prefix is the shortest one no other option '
        'shares', () async {
      final t = await optionTargets(scorer(), section([3, 3, 1]));
      expect(t.texts, ['refund_status', 'refund_policy', 'cancel']);
    });

    test('a prefix that does not tokenise back is scored in full', () async {
      final s = scorer()..spell('refund_status', [1, 2, 9]);
      final t = await optionTargets(s, section([4, 3, 1]));
      expect(t.texts, [
        'refund_status<end_of_turn>',
        'refund_policy',
        'cancel',
      ]);
    });

    test('lengths other than the section\'s are refused', () async {
      await expectLater(
        optionTargets(scorer(), section([1, 1, 1])),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('[3, 3, 1]'),
          ),
        ),
      );
    });

    test('an option that is a prefix of another is refused', () async {
      final s = scorer()..spell('refund_policy<end_of_turn>', [1, 2, 3, 106]);
      await expectLater(
        optionTargets(s, section([4, 4, 1])),
        throwsA(isA<DeciderUnsupportedException>()),
      );
    });
  });

  group('Noul and Score', () {
    Future<(DeciderAnswer, Decider)> answer(
      Map<String, Object?> decision,
      Map<String, double> scores, {
      double temperature = 1.0,
    }) async {
      final payload = _section(decision, temperature: temperature);
      final s = _Scorer({106: '<end_of_turn>', 107: '\n'}, selfCheck: _dropped);
      var id = 1000;
      final pieces = <int, String>{};
      for (final optionId in [
        for (final o in (payload['options'] as List).cast<Map>())
          o['id'] as String,
        if (payload['none_option'] case final String none) none,
      ]) {
        final i = id++;
        pieces[i] = optionId;
        s.spell('$optionId<end_of_turn>', [i, 106]);
        s.spell(optionId, [i]);
      }
      s.pieces.addAll(pieces);
      _spellFixedPair(s);
      s.optionScores = {
        for (final e in scores.entries) e.key: [e.value],
      };
      final decider = await _Model(jsonEncode(payload), s).createDecider(
        question: payload['question'] as String,
        options: _optionsOf(payload),
        calibration: _calibrationOf(payload),
      );
      return (
        await decider.choose(DeciderInput(EmbeddingInput.text('a state'))),
        decider,
      );
    }

    final cases =
        (jsonDecode(
                  File(
                    '$_fixtures/decision-contract-v1.json',
                  ).readAsStringSync(),
                )
                as Map)['cases']
            as List;
    Map<String, Object?> decisionOf(String name) =>
        (cases.firstWhere((c) => (c as Map)['name'] == name) as Map)['decision']
            as Map<String, Object?>;

    test('a noul answer is P(yes), never an abstention', () async {
      final (a, decider) = await answer(decisionOf('noul'), {
        'no': -2.0,
        'yes': -0.5,
      }, temperature: 1.5);
      expect(a.questionType, DeciderQuestionType.noul);
      expect(a.choice, 'yes');
      expect(a.abstainReason, isNull);
      expect(a.noul, a.probabilities!['yes']);
      // softmax over (-2.0, -0.5) at T 1.5: 1 / (1 + e^(-1.5 / 1.5)).
      expect(a.noul, closeTo(1 / (1 + math.exp(-1.5 / 1.5)), 1e-12));
      expect(a.toJevJson(), {'type': 'noul', 'noul': a.noul});
      expect(a.provenance.threshold, isNull);
      expect(decider.capabilities.calibratedProbabilities, isTrue);
    });

    test('a score answer carries its expected level and legend', () async {
      final (a, _) = await answer(decisionOf('score'), {
        '0': -3.0,
        '1': -1.0,
        '2': -0.2,
      });
      expect(a.questionType, DeciderQuestionType.score);
      expect(a.choice, '2');
      final p = a.probabilities!;
      expect(a.expectedLevel, closeTo(p['1']! + 2 * p['2']!, 1e-12));
      expect(a.legend, {
        '0': 'not urgent',
        '1': 'somewhat urgent',
        '2': 'very urgent',
      });
      final jev = a.toJevJson();
      expect(jev['type'], 'score');
      expect(jev['score'], a.expectedLevel);
      expect(jev['legend'], a.legend);
      expect(jev['probabilities'], p);
      expect(jev['confidence'], a.confidence);
    });

    test('a choice whose none option wins abstains noneOption', () async {
      final (a, _) = await answer(decisionOf('clinc151 out of scope'), {
        for (final o
            in (decisionOf('clinc151 out of scope')['options'] as List)
                .cast<Map>())
          o['id'] as String: -9.0,
        'none_of_these': -0.1,
      });
      expect(a.choice, isNull);
      expect(a.abstainReason, AbstainReason.noneOption);
      expect(a.ranked.first.id, 'none_of_these');
      expect(a.toJevJson()['choice'], isNull);
    });
  });

  group('each decision', () {
    final golden = _golden();
    final payload = golden['payload'] as Map<String, Object?>;

    Future<(Decider, _Scorer)> create() async {
      final scorer = _emotionScorer()
        ..optionScores = {
          for (final t in ['sad', 'joy', 'love', 'anger', 'fear', 'surprise'])
            t: [-1.0],
        };
      final decider = await _Model(golden['payload_text'] as String, scorer)
          .createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: _calibrationOf(payload),
          );
      return (decider, scorer);
    }

    test('refuses a state with control text, or none', () async {
      final (d, scorer) = await create();
      for (final marker in decisionControlText) {
        await expectLater(
          d.choose(DeciderInput(EmbeddingInput.text('i am $marker fine'))),
          throwsA(isA<ArgumentError>()),
          reason: marker,
        );
      }
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text(' \n '))),
        throwsA(isA<ArgumentError>()),
      );
      expect(scorer.scoreCalls, 0);
    });

    test('refuses a render that starts with <bos>, and a last token that '
        'does not round-trip', () async {
      final (d, scorer) = await create();
      scorer.render = (c) => '<bos><start_of_turn>user\n$c';
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      scorer.render = (c) => '<start_of_turn>user\n$c<end_of_turn>\nX';
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      expect(scorer.scoreCalls, 0);
    });

    test('refuses scores of the wrong length', () async {
      final (d, scorer) = await create();
      scorer.optionScores!['joy'] = [-1.0, -2.0];
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsA(isA<DeciderUnsupportedException>()),
      );
    });

    test('closed, or on a closed model, it answers nothing', () async {
      final (d, _) = await create();
      await d.close();
      expect(d.isClosed, isTrue);
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsStateError,
      );
    });
  });

  group('DeciderAnswer for Noul and Score', () {
    DeciderAnswer make({
      DeciderQuestionType type = DeciderQuestionType.noul,
      Map<String, double> p = const {'no': 0.25, 'yes': 0.75},
      double? noul = 0.75,
      double? level,
      Map<String, String>? legend,
      AbstainReason? reason,
    }) {
      final ranked = [
        for (final e
            in (p.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
          RankedOption(id: e.key, score: e.value, probability: e.value),
      ];
      return DeciderAnswer(
        choice: reason == null ? ranked.first.id : null,
        ranked: ranked,
        scoreKind: ScoreKind.logprob,
        margin: ranked[0].score - ranked[1].score,
        probabilities: p,
        abstainReason: reason,
        provenance: const DeciderProvenance(
          method: DeciderMethod.optionScoring,
          calibration: 'supplied',
          encodeTime: Duration.zero,
          scoreTime: Duration.zero,
        ),
        questionType: type,
        noul: noul,
        expectedLevel: level,
        legend: legend,
      );
    }

    test('a consistent noul and score answer', () {
      expect(make().noul, 0.75);
      final score = make(
        type: DeciderQuestionType.score,
        p: const {'0': 0.2, '1': 0.3, '2': 0.5},
        noul: null,
        level: 1.3,
        legend: const {'0': 'low', '1': 'mid', '2': 'high'},
      );
      expect(score.expectedLevel, 1.3);
    });

    test('contradictions are refused', () {
      expect(() => make(noul: 0.5), throwsArgumentError);
      expect(() => make(noul: null), throwsArgumentError);
      expect(() => make(p: const {'a': 0.25, 'b': 0.75}), throwsArgumentError);
      expect(() => make(reason: AbstainReason.noneOption), throwsArgumentError);
      expect(
        () => make(
          type: DeciderQuestionType.score,
          p: const {'0': 0.2, '1': 0.3, '2': 0.5},
          noul: null,
          level: 1.0,
          legend: const {'0': 'low', '1': 'mid', '2': 'high'},
        ),
        throwsArgumentError,
      );
      expect(
        () => make(
          type: DeciderQuestionType.score,
          p: const {'0': 0.2, '1': 0.3, '2': 0.5},
          noul: null,
          level: 1.3,
          legend: const {'0': 'low', '1': 'mid'},
        ),
        throwsArgumentError,
      );
      expect(
        () => make(type: DeciderQuestionType.choice),
        throwsArgumentError,
        reason: 'a choice answer has no noul',
      );
    });
  });
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}

/// The scoring mode the decider's self-check picked.
String _modeName(Decider decider) => ((decider as dynamic).mode as Enum).name;
