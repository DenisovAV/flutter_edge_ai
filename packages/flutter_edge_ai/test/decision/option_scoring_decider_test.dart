// InferenceModel.createDecider over an engine that scores options, with the
// engine scripted: the parts of the decider that need no model. The decider
// on real models is example/integration_test/litertlm_inference_decider_test.dart;
// LiteRT-LM's scoring self-check is tested in flutter_edge_ai_litertlm.
//
// Fixtures:
// - decision-contract-v1.json: litetune's renderer contract, byte for byte as
//   litetune 0.5.0 ships it (`tests/fixtures/`);
// - decisions-golden-v1-scores.json: the numbers of litetune's golden pack
//   decisions-golden-v1 — the section, and per row the engine's token scores
//   with the probabilities and the answer litetune computed from them.
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/decision/embedding_decider.dart'
    show deciderConfidence;
import 'package:flutter_edge_ai/src/decision/option_scoring_decider.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'test/decision/fixtures';

/// litetune's contract fixture at 0.5.0 (`46199f4`), pinned by its digest.
const _contractSha256 =
    'bcac6b4fd2f3131b9bb713d9aa5d9270a4dc7707b411985861fa1c7ce552a051';

const _emotionIds = ['sadness', 'joy', 'love', 'anger', 'fear', 'surprise'];
const _emotionTargets = ['sad', 'joy', 'love', 'anger', 'fear', 'surprise'];

Map<String, Object?> _golden() =>
    jsonDecode(
          File('$_fixtures/decisions-golden-v1-scores.json').readAsStringSync(),
        )
        as Map<String, Object?>;

Map<String, Object?> _contractCase(String name) {
  final contract =
      jsonDecode(
            File('$_fixtures/decision-contract-v1.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  return (contract['cases'] as List).cast<Map<String, Object?>>().firstWhere(
    (c) => c['name'] == name,
  );
}

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
/// rendered prompt, of [promptLength] tokens.
final class _Scorer extends OptionScorer {
  _Scorer(this.pieces);

  /// Token id → its text.
  final Map<int, String> pieces;
  final Map<String, List<int>> _tokens = {};

  int promptLength = 10;

  /// The scores of a decision's targets, by target text.
  Map<String, List<double>> optionScores = {};

  /// When set, `tokenize` of a rendered prompt waits for it.
  Completer<void>? tokenizeGate;

  int scoreCalls = 0;
  int renderCalls = 0;
  int prepareCalls = 0;

  /// When set, `prepare` waits for it, then fails if the scorer was closed.
  Completer<void>? prepareGate;

  /// When set, `close` waits for it before the scorer reads as closed.
  Completer<void>? closeGate;
  List<String>? prepared;
  String? lastPrompt;
  List<String>? lastTargets;
  CancelToken? lastToken;
  Object? prepareError;
  bool closed = false;

  void spell(String text, List<int> ids) => _tokens[text] = ids;

  void _open() {
    if (closed) throw StateError('The option scorer is closed.');
  }

  @override
  Future<List<int>> tokenize(String text) async {
    _open();
    final known = _tokens[text];
    if (known != null) return known;
    final gate = tokenizeGate;
    if (gate != null) {
      await gate.future;
      _open();
    }
    return List.generate(promptLength, (i) => 900 + i);
  }

  @override
  Future<String> detokenize(List<int> ids) async {
    _open();
    return ids.map((id) => pieces[id] ?? '<$id>').join();
  }

  @override
  Future<String> renderUserMessage(String content) async {
    _open();
    renderCalls++;
    return '<start_of_turn>user\n$content<end_of_turn>\n<start_of_turn>model\n';
  }

  @override
  Future<void> prepare(List<String> targets) async {
    prepareCalls++;
    prepared = targets;
    if (prepareGate case final gate?) {
      await gate.future;
      _open();
    }
    if (prepareError case final error?) throw error;
  }

  @override
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    CancelToken? cancelToken,
  }) async {
    _open();
    scoreCalls++;
    lastPrompt = prompt;
    lastTargets = targets;
    lastToken = cancelToken;
    return OptionScoringRun(
      tokenScores: [for (final t in targets) optionScores[t]!],
      prefillTime: const Duration(milliseconds: 3),
      scoreTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<void> close() async {
    if (closeGate case final gate?) await gate.future;
    closed = true;
  }
}

final class _Model extends InferenceModel with OptionScoringModel {
  _Model(this.payload, this.scorer, {this.context = 1024, this.readError});

  final String? payload;
  final Object? readError;
  final _Scorer scorer;
  final int context;
  bool closedModel = false;

  @override
  int get maxTokens => context;

  @override
  bool get isClosed => closedModel;

  @override
  Future<String?> readDecisionSection() async {
    if (readError case final error?) throw error;
    return payload;
  }

  @override
  Future<OptionScorer> openOptionScorer() async => scorer;

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
  });
  final ids = (_golden()['option_token_ids'] as List).cast<List>();
  for (var i = 0; i < _emotionIds.length; i++) {
    final row = ids[i].cast<int>();
    s.spell('${_emotionIds[i]}<end_of_turn>', row);
    s.spell(s.pieces[row.first]!, [row.first]);
  }
  s.optionScores = {
    for (final t in _emotionTargets) t: [-2.0],
  };
  return s;
}

/// The emotion decider, created as the golden pack's call creates it.
Future<(Decider, _Scorer)> _emotionDecider({
  List<DeciderOption>? options,
  InferenceDeciderCalibration? calibration,
  int context = 1024,
}) async {
  final golden = _golden();
  final payload = golden['payload'] as Map<String, Object?>;
  final scorer = _emotionScorer();
  final decider =
      await _Model(
        golden['payload_text'] as String,
        scorer,
        context: context,
      ).createDecider(
        question: payload['question'] as String,
        options: options ?? _optionsOf(payload),
        calibration: calibration ?? _calibrationOf(payload),
      );
  return (decider, scorer);
}

void _setEmotionRow(_Scorer scorer, Map<String, Object?> row) {
  final scores = (row['engine_token_scores'] as List).cast<List>();
  scorer.optionScores = {
    for (var j = 0; j < _emotionTargets.length; j++)
      _emotionTargets[j]: scores[j]
          .cast<num>()
          .map((s) => s.toDouble())
          .toList(),
  };
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
      expect(section.listed.map((o) => o.id), _emotionIds);
      expect(section.temperature, payload['temperature']);
      expect(section.abstainBelow, payload['abstain_below']);
      expect(section.abstainRule, 'error_budget');
      expect(section.scoredLengths, [1, 1, 1, 1, 1, 1]);
    });

    Map<String, Object?> changed(void Function(Map<String, Object?> p) edit) {
      final p = jsonDecode(jsonEncode(payload)) as Map<String, Object?>;
      edit(p);
      return p;
    }

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
      'options scored with an Engine each': (
        (p) => p['method'] = 'fresh_engine',
        'an Engine per option (method fresh_engine',
      ),
      'a method litetune does not write': (
        (p) => p['method'] = 'batch',
        'method "batch"',
      ),
      'a method that is null': ((p) => p['method'] = null, 'method null'),
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

    test('litetune 0.6.0\'s section, with method rewind, reads as '
        'written', () {
      final section = DecisionSection.parse(
        jsonEncode(changed((p) => p['method'] = 'rewind')),
      );
      expect(section.listed.map((o) => o.id), _emotionIds);
      expect(section.temperature, payload['temperature']);
    });

    test('a decider is created on litetune 0.6.0\'s section', () async {
      final decider =
          await _Model(
            jsonEncode(changed((p) => p['method'] = 'rewind')),
            _emotionScorer(),
          ).createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
          );
      expect(decider.options.map((o) => o.id), _emotionIds);
      await decider.close();
    });

    test('a fresh_engine section is refused by name', () async {
      await expectLater(
        _Model(
          jsonEncode(changed((p) => p['method'] = 'fresh_engine')),
          _emotionScorer(),
        ).createDecider(
          question: payload['question'] as String,
          options: _optionsOf(payload),
          calibration: const InferenceDeciderCalibration.fromModel(),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('an Engine per option (method fresh_engine'),
          ),
        ),
      );
    });

    test('a model without one is refused by name', () async {
      await expectLater(
        _Model(null, _emotionScorer()).createDecider(
          question: payload['question'] as String,
          options: _optionsOf(payload),
          calibration: const InferenceDeciderCalibration.fromModel(),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('carries no decision'),
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
            calibration: const InferenceDeciderCalibration.fromModel(),
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

    List<DeciderOption> check({
      DecisionSection? s,
      String? q,
      List<DeciderOption>? o,
      InferenceDeciderCalibration? c,
    }) => checkAgainstDecisionSection(
      s ?? section,
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
      expect(
        check(o: options.reversed.toList()).map((o) => o.id),
        _emotionIds.reversed,
      );
      check(
        o: [for (final o in options) DeciderOption(o.id, description: o.id)],
      );
    });

    test('fromModel takes the file\'s calibration', () {
      check(c: const InferenceDeciderCalibration.fromModel());
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

    test('another explicit temperature or threshold is refused, pointing at '
        'fromModel', () {
      expect(
        () => check(c: const InferenceDeciderCalibration(temperature: 1.0)),
        refusing('calibration.temperature', 'fromModel()'),
      );
      expect(
        () => check(
          c: InferenceDeciderCalibration(temperature: calibration.temperature),
        ),
        refusing('calibration.abstainBelow', '${payload['abstain_below']}'),
      );
    });

    test('a threshold of 0 is passed as none: it never abstains', () {
      final zero = DecisionSection.parse(
        jsonEncode({...payload, 'abstain_below': 0}),
      );
      expect(zero.calibrationAbstainBelow, isNull);
      check(
        s: zero,
        c: InferenceDeciderCalibration(temperature: calibration.temperature),
      );
    });

    group('a model with a none option', () {
      final clinc = DecisionSection.parse(
        jsonEncode(
          _section(
            _contractCase('clinc151 out of scope')['decision']
                as Map<String, Object?>,
          ),
        ),
      );
      final trained = [for (final o in clinc.options) DeciderOption(o.id)];

      test(
        'fromModel lets the call leave it out; the decider lists it last',
        () {
          final decided = checkAgainstDecisionSection(
            clinc,
            question: clinc.question,
            options: trained,
            calibration: const InferenceDeciderCalibration.fromModel(),
          );
          expect(decided.last.id, 'none_of_these');
          expect(decided, hasLength(trained.length + 1));
        },
      );

      test('explicit values need it listed and named', () {
        expect(
          () => checkAgainstDecisionSection(
            clinc,
            question: clinc.question,
            options: trained,
            calibration: const InferenceDeciderCalibration(
              temperature: 1.0,
              abstainBelow: 0.5,
            ),
          ),
          refusing('options', 'leaves out'),
        );
        expect(
          () => checkAgainstDecisionSection(
            clinc,
            question: clinc.question,
            options: [...trained, DeciderOption('none_of_these')],
            calibration: const InferenceDeciderCalibration(
              temperature: 1.0,
              abstainBelow: 0.5,
            ),
          ),
          refusing('calibration.noneOption', 'none_of_these'),
        );
        checkAgainstDecisionSection(
          clinc,
          question: clinc.question,
          options: [...trained, DeciderOption('none_of_these')],
          calibration: const InferenceDeciderCalibration(
            temperature: 1.0,
            abstainBelow: 0.5,
            noneOption: 'none_of_these',
          ),
        );
      });
    });
  });

  group('the golden pack\'s arithmetic', () {
    final golden = _golden();
    final payload = golden['payload'] as Map<String, Object?>;

    Future<void> everyRow(List<DeciderOption> options) async {
      final (decider, scorer) = await _emotionDecider(options: options);
      var abstained = 0;
      for (final row in (golden['rows'] as List).cast<Map<String, Object?>>()) {
        _setEmotionRow(scorer, row);
        final answer = await decider.choose(
          DeciderInput(EmbeddingInput.text('state ${row['index']}')),
          topK: _emotionIds.length,
        );
        final want = (row['probabilities'] as List).cast<num>();
        for (var j = 0; j < _emotionIds.length; j++) {
          expect(
            answer.probabilities![_emotionIds[j]],
            closeTo(want[j], 1e-12),
          );
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
        // The prompt lists the trained order, whatever the app's is; the
        // targets are its unique prefixes, in that order.
        expect(scorer.lastTargets, _emotionTargets);
        expect(scorer.lastPrompt, contains('Options:\n- sadness\n- joy\n'));
      }
      expect(abstained, 2);
      await decider.close();
      expect(scorer.closed, isTrue);
    }

    test('every row: litetune\'s probabilities and answer from its engine '
        'scores, abstentions included', () async {
      await everyRow(_optionsOf(payload));
    });

    test('the app\'s option order changes nothing but its own order', () async {
      await everyRow(_optionsOf(payload).reversed.toList());
    });
  });

  group('the targets', () {
    /// Options `refund_status` and `refund_policy` share their first two
    /// tokens; `cancel` is one token.
    _Scorer scorer() =>
        _Scorer({
            1: 'refund',
            2: '_',
            3: 'status',
            4: 'policy',
            5: 'cancel',
            106: '<end_of_turn>',
          })
          ..spell('refund_status<end_of_turn>', [1, 2, 3, 106])
          ..spell('refund_policy<end_of_turn>', [1, 2, 4, 106])
          ..spell('cancel<end_of_turn>', [5, 106])
          ..spell('refund_status', [1, 2, 3])
          ..spell('refund_policy', [1, 2, 4])
          ..spell('cancel', [5])
          ..spell('refund', [1]);

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
      expect(t.wholeTargetIds.first, [1, 2, 3, 106]);
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

  group('creation', () {
    test('the engine is prepared with the decision\'s targets once', () async {
      final (_, scorer) = await _emotionDecider();
      expect(scorer.prepareCalls, 1);
      expect(scorer.prepared, _emotionTargets);
    });

    test('an engine that refuses in prepare closes the scorer and the '
        'refusal arrives unchanged', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer()
        ..prepareError = const DeciderUnsupportedException('mixed');
      await expectLater(
        _Model(golden['payload_text'] as String, scorer).createDecider(
          question: payload['question'] as String,
          options: _optionsOf(payload),
          calibration: const InferenceDeciderCalibration.fromModel(),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            'mixed',
          ),
        ),
      );
      expect(scorer.closed, isTrue);
    });

    test(
      'a decision that cannot fit the model\'s context is refused',
      () async {
        await expectLater(
          _emotionDecider(context: 10),
          throwsA(
            isA<DeciderUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('maxTokens 10'),
            ),
          ),
        );
      },
    );

    test('capabilities name the question type', () async {
      final (decider, _) = await _emotionDecider();
      expect(decider.capabilities.questionType, DeciderQuestionType.choice);
      expect(decider.capabilities.supportsAmong, isFalse);
      expect(decider.capabilities.calibratedProbabilities, isTrue);
    });
  });

  group('Noul and Score', () {
    Future<(DeciderAnswer, Decider)> answer(
      Map<String, Object?> decision,
      Map<String, double> scores, {
      double temperature = 1.0,
    }) async {
      final payload = _section(decision, temperature: temperature);
      final s = _Scorer({106: '<end_of_turn>'});
      var id = 1000;
      for (final optionId in [
        for (final o in (payload['options'] as List).cast<Map>())
          o['id'] as String,
        if (payload['none_option'] case final String none) none,
      ]) {
        final i = id++;
        s.pieces[i] = optionId;
        s.spell('$optionId<end_of_turn>', [i, 106]);
        s.spell(optionId, [i]);
      }
      s.optionScores = {
        for (final e in scores.entries) e.key: [e.value],
      };
      final decider = await _Model(jsonEncode(payload), s).createDecider(
        question: payload['question'] as String,
        options: _optionsOf(payload),
        calibration: const InferenceDeciderCalibration.fromModel(),
      );
      return (
        await decider.choose(DeciderInput(EmbeddingInput.text('a state'))),
        decider,
      );
    }

    test('a noul answer is P(yes), never an abstention', () async {
      final (a, decider) = await answer(
        _contractCase('noul')['decision'] as Map<String, Object?>,
        {'no': -2.0, 'yes': -0.5},
        temperature: 1.5,
      );
      expect(a.questionType, DeciderQuestionType.noul);
      expect(decider.capabilities.questionType, DeciderQuestionType.noul);
      expect(a.choice, 'yes');
      expect(a.abstainReason, isNull);
      expect(a.noul, a.probabilities!['yes']);
      // softmax over (-2.0, -0.5) at T 1.5: 1 / (1 + e^(-1.5 / 1.5)).
      expect(a.noul, closeTo(1 / (1 + math.exp(-1.5 / 1.5)), 1e-12));
      expect(a.expectedLevel, isNull);
      expect(a.toJevJson(), {'type': 'noul', 'noul': a.noul});
      expect(a.provenance.threshold, isNull);
    });

    test('a score answer carries its expected level and legend', () async {
      final (a, _) = await answer(
        _contractCase('score')['decision'] as Map<String, Object?>,
        {'0': -3.0, '1': -1.5, '2': -0.4},
      );
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
      final decision =
          _contractCase('clinc151 out of scope')['decision']
              as Map<String, Object?>;
      final (a, _) = await answer(decision, {
        for (final o in (decision['options'] as List).cast<Map>())
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
    test('refuses a state with control text, or none', () async {
      final (d, scorer) = await _emotionDecider();
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

    test('refuses an input whose prompt does not fit the context, never '
        'truncating it', () async {
      final (d, scorer) = await _emotionDecider();
      scorer.promptLength = 1023;
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('a very long state'))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('maxTokens 1024'),
          ),
        ),
      );
      expect(scorer.scoreCalls, 0);
    });

    test('passes the cancel token to the engine', () async {
      final (d, scorer) = await _emotionDecider();
      final token = CancelToken();
      await d.choose(
        DeciderInput(EmbeddingInput.text('hello')),
        cancelToken: token,
      );
      expect(scorer.lastToken, same(token));
    });

    final notLogProbabilities = <String, void Function(_Scorer)>{
      'a token scored above 0': (s) => s.optionScores['joy'] = [0.5],
      'scores whose probabilities sum above 1': (s) {
        for (final t in _emotionTargets) {
          s.optionScores[t] = [-0.1];
        }
      },
      'scores of the wrong length': (s) => s.optionScores['joy'] = [-1.0, -2.0],
      'a score that is not finite': (s) => s.optionScores['joy'] = [double.nan],
    };
    for (final MapEntry(key: name, value: corrupt)
        in notLogProbabilities.entries) {
      test('refuses $name', () async {
        final (d, scorer) = await _emotionDecider();
        corrupt(scorer);
        await expectLater(
          d.choose(DeciderInput(EmbeddingInput.text('hello'))),
          throwsA(isA<DeciderUnsupportedException>()),
        );
      });
    }

    test('refuses a positive token inside a target whose sum is a fine '
        'log-probability', () async {
      // Three-token targets: a token at +0.3 hides in a sum of -4.7.
      final s =
          _Scorer({
              1: 'refund',
              2: '_',
              3: 'status',
              4: 'policy',
              5: 'cancel',
              106: '<end_of_turn>',
            })
            ..spell('refund_status<end_of_turn>', [1, 2, 3, 106])
            ..spell('refund_policy<end_of_turn>', [1, 2, 4, 106])
            ..spell('cancel<end_of_turn>', [5, 106])
            ..spell('refund_status', [1, 2, 3])
            ..spell('refund_policy', [1, 2, 4])
            ..spell('cancel', [5]);
      s.optionScores = {
        'refund_status': [0.3, -2.0, -3.0],
        'refund_policy': [-0.1, -2.0, -4.0],
        'cancel': [-3.0],
      };
      final d =
          await _Model(
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
              'scored_lengths': [3, 3, 1],
              'temperature': 1.0,
              'abstain_rule': 'error_budget',
              'abstain_below': 0.4,
            }),
            s,
          ).createDecider(
            question: 'What does the customer want?',
            options: [
              DeciderOption('refund_status'),
              DeciderOption('refund_policy'),
              DeciderOption('cancel'),
            ],
            calibration: const InferenceDeciderCalibration.fromModel(),
          );
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('not a log-probability'),
          ),
        ),
      );
    });

    test('a close while it waits on the engine fails it as cancelled, not '
        'with the closed scorer\'s StateError', () async {
      final (d, scorer) = await _emotionDecider();
      scorer.tokenizeGate = Completer<void>();
      final pending = d.choose(DeciderInput(EmbeddingInput.text('hello')));
      await pumpEventQueue();
      await d.close();
      scorer.tokenizeGate!.complete();
      await expectLater(pending, throwsA(isA<DeciderCancelledException>()));
    });

    test(
      'closed, it answers nothing; a second close waits for the first',
      () async {
        final (d, _) = await _emotionDecider();
        final first = d.close();
        final second = d.close();
        expect(identical(first, second), isTrue);
        await first;
        expect(d.isClosed, isTrue);
        await expectLater(
          d.choose(DeciderInput(EmbeddingInput.text('hello'))),
          throwsStateError,
        );
      },
    );

    test('on a closed model it answers nothing', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final model = _Model(golden['payload_text'] as String, _emotionScorer());
      final d = await model.createDecider(
        question: payload['question'] as String,
        options: _optionsOf(payload),
        calibration: const InferenceDeciderCalibration.fromModel(),
      );
      model.closedModel = true;
      expect(d.isClosed, isTrue);
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsStateError,
      );
    });
  });

  group('the answer, computed by hand', () {
    // refund_status and refund_policy are three tokens each, cancel and the
    // none option one: the multi-token sums, a temperature other than 1, a
    // none option and a threshold, which the golden pack (one token per
    // option, no none option) does not reach.
    const t = 1.7;
    const below = 0.6;
    Future<(Decider, _Scorer)> decider({int context = 1024}) async {
      final s =
          _Scorer({
              1: 'refund',
              2: '_',
              3: 'status',
              4: 'policy',
              5: 'cancel',
              6: 'none_of_these',
              106: '<end_of_turn>',
            })
            ..spell('refund_status<end_of_turn>', [1, 2, 3, 106])
            ..spell('refund_policy<end_of_turn>', [1, 2, 4, 106])
            ..spell('cancel<end_of_turn>', [5, 106])
            ..spell('none_of_these<end_of_turn>', [6, 106])
            ..spell('refund_status', [1, 2, 3])
            ..spell('refund_policy', [1, 2, 4])
            ..spell('cancel', [5])
            ..spell('none_of_these', [6])
            ..spell('refund', [1]);
      final payload = {
        'contract_version': 1,
        'type': 'choice',
        'question': 'What does the customer want?',
        'options': [
          {'id': 'refund_status', 'description': null},
          {'id': 'refund_policy', 'description': null},
          {'id': 'cancel', 'description': null},
        ],
        'none_option': 'none_of_these',
        'scoring': 'unique_prefix',
        'terminator': '<end_of_turn>',
        'scored_lengths': [3, 3, 1, 1],
        'temperature': t,
        'abstain_rule': 'error_budget',
        'abstain_below': below,
      };
      final d = await _Model(jsonEncode(payload), s, context: context)
          .createDecider(
            question: 'What does the customer want?',
            options: [
              DeciderOption('cancel'),
              DeciderOption('refund_status'),
              DeciderOption('refund_policy'),
            ],
            calibration: const InferenceDeciderCalibration.fromModel(),
          );
      return (d, s);
    }

    Future<DeciderAnswer> choose(
      Decider d,
      _Scorer s,
      Map<String, List<double>> scores, {
      int? topK,
    }) {
      s.optionScores = scores;
      return d.choose(
        DeciderInput(EmbeddingInput.text('a state')),
        topK: topK ?? d.options.length,
      );
    }

    test(
      'probabilities, scores, margin and confidence from the token sums',
      () async {
        final (d, s) = await decider();
        final a = await choose(d, s, {
          'refund_status': [-0.2, -0.1, -0.3],
          'refund_policy': [-0.2, -0.1, -1.5],
          'cancel': [-2.5],
          'none_of_these': [-3.0],
        });
        final sums = {
          'refund_status': -0.6,
          'refund_policy': -1.8,
          'cancel': -2.5,
          'none_of_these': -3.0,
        };
        final zT = sums.values.fold(0.0, (z, x) => z + math.exp(x / t));
        final z1 = sums.values.fold(0.0, (z, x) => z + math.exp(x));
        for (final e in sums.entries) {
          expect(
            a.probabilities![e.key],
            closeTo(math.exp(e.value / t) / zT, 1e-12),
          );
        }
        expect(a.ranked.map((r) => r.id), [
          'refund_status',
          'refund_policy',
          'cancel',
          'none_of_these',
        ]);
        for (final r in a.ranked) {
          expect(r.score, closeTo(sums[r.id]! - math.log(z1), 1e-12));
        }
        expect(a.margin, closeTo(-0.6 - -1.8, 1e-12));
        final top = a.probabilities!['refund_status']!;
        expect(top, lessThan(below));
        expect(a.abstainReason, AbstainReason.belowThreshold);
        expect(a.confidence, closeTo(deciderConfidence(top, 4), 1e-12));
      },
    );

    test('topK keeps the best options only', () async {
      final (d, s) = await decider();
      final a = await choose(d, s, {
        'refund_status': [-0.2, -0.1, -0.3],
        'refund_policy': [-0.2, -0.1, -1.5],
        'cancel': [-2.5],
        'none_of_these': [-3.0],
      }, topK: 2);
      expect(a.ranked.map((r) => r.id), ['refund_status', 'refund_policy']);
    });

    test('a winning none option abstains noneOption even below the '
        'threshold', () async {
      final (d, s) = await decider();
      final a = await choose(d, s, {
        'refund_status': [-1.0, -1.0, -1.0],
        'refund_policy': [-1.5, -1.5, -1.5],
        'cancel': [-2.0],
        'none_of_these': [-0.6],
      });
      expect(a.ranked.first.id, 'none_of_these');
      expect(a.probabilities!['none_of_these'], lessThan(below));
      expect(a.abstainReason, AbstainReason.noneOption);
    });

    test('a tie goes to the option the app listed first', () async {
      final (d, s) = await decider();
      final a = await choose(d, s, {
        'refund_status': [-0.5, -0.5, -0.5],
        'refund_policy': [-1.0, -1.0, -1.0],
        'cancel': [-1.5],
        'none_of_these': [-3.0],
      });
      // The app listed cancel before refund_status.
      expect(a.ranked.take(2).map((r) => r.id), ['cancel', 'refund_status']);
    });

    test(
      'the context check counts BOS and one token prefilled again',
      () async {
        // A 10-token prompt, its BOS, the longest target (3), one more: 15.
        await expectLater(
          decider(context: 14),
          throwsA(isA<DeciderUnsupportedException>()),
        );
        final (d, s) = await decider(context: 15);
        final scores = {
          'refund_status': [-0.2, -0.1, -0.3],
          'refund_policy': [-0.2, -0.1, -1.5],
          'cancel': [-2.5],
          'none_of_these': [-3.0],
        };
        await choose(d, s, scores);
        s.promptLength = 11;
        await expectLater(choose(d, s, scores), throwsArgumentError);
      },
    );
  });

  group('creation, cancelled and refused', () {
    test(
      'a decision that cannot be read is refused, not a FormatException',
      () async {
        final golden = _golden();
        final payload = golden['payload'] as Map<String, Object?>;
        await expectLater(
          _Model(
            null,
            _emotionScorer(),
            readError: const FormatException('a decision stored twice'),
          ).createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
          ),
          throwsA(
            isA<DeciderUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('a decision stored twice'),
            ),
          ),
        );
      },
    );

    test('a cancel while the engine prepares closes its scorer at once and '
        'fails as cancelled', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer()..prepareGate = Completer<void>();
      final token = CancelToken();
      final created = _Model(golden['payload_text'] as String, scorer)
          .createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
            cancelToken: token,
          );
      await pumpEventQueue();
      expect(scorer.prepareCalls, 1);
      token.cancel();
      await pumpEventQueue();
      expect(scorer.closed, isTrue, reason: 'the engine is told to stop');
      scorer.prepareGate!.complete();
      await expectLater(created, throwsA(isA<DeciderCancelledException>()));
    });

    test('a cancel right after prepare fails as cancelled and closes the '
        'scorer', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer()..prepareGate = Completer<void>();
      final token = CancelToken();
      final created = _Model(golden['payload_text'] as String, scorer)
          .createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
            cancelToken: token,
          );
      await pumpEventQueue();
      // Prepare finishes, then the token is cancelled before the next step.
      scorer.prepareGate!.complete();
      token.cancel();
      await expectLater(created, throwsA(isA<DeciderCancelledException>()));
      expect(scorer.closed, isTrue);
    });

    test('a failure that came before the cancel stays the failure', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer()
        ..prepareError = StateError('native boom')
        ..closeGate = Completer<void>();
      final token = CancelToken();
      final created = _Model(golden['payload_text'] as String, scorer)
          .createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
            cancelToken: token,
          );
      await pumpEventQueue();
      // prepare failed; the scorer is closing when the app cancels.
      token.cancel();
      scorer.closeGate!.complete();
      await expectLater(
        created,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'native boom'),
        ),
      );
    });

    test('a StateError with no token is never a cancel', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer()
        ..prepareError = StateError('The model is closed.');
      await expectLater(
        _Model(golden['payload_text'] as String, scorer).createDecider(
          question: payload['question'] as String,
          options: _optionsOf(payload),
          calibration: const InferenceDeciderCalibration.fromModel(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(scorer.closed, isTrue);
    });

    test('a token cancelled after a successful creation leaves the decider '
        'open', () async {
      final golden = _golden();
      final payload = golden['payload'] as Map<String, Object?>;
      final scorer = _emotionScorer();
      final token = CancelToken();
      final decider = await _Model(golden['payload_text'] as String, scorer)
          .createDecider(
            question: payload['question'] as String,
            options: _optionsOf(payload),
            calibration: const InferenceDeciderCalibration.fromModel(),
            cancelToken: token,
          );
      token.cancel();
      await pumpEventQueue();
      expect(scorer.closed, isFalse);
      expect(decider.isClosed, isFalse);
      await decider.choose(DeciderInput(EmbeddingInput.text('still here')));
      expect(scorer.scoreCalls, 1);
    });

    test('a refused input does not block the decisions after it', () async {
      final (decider, scorer) = await _emotionDecider();
      await expectLater(
        decider.choose(DeciderInput(EmbeddingInput.text('a <end_of_turn> b'))),
        throwsArgumentError,
      );
      await decider.choose(DeciderInput(EmbeddingInput.text('hello')));
      expect(scorer.scoreCalls, 1);
    });

    test(
      'a decision cancelled while it waits its turn fails at once',
      () async {
        final (decider, scorer) = await _emotionDecider();
        final gate = Completer<void>();
        scorer.tokenizeGate = gate;
        final first = decider.choose(DeciderInput(EmbeddingInput.text('one')));
        final token = CancelToken();
        final second = decider.choose(
          DeciderInput(EmbeddingInput.text('two')),
          cancelToken: token,
        );
        await pumpEventQueue();
        token.cancel();
        var secondDone = false;
        final secondExpect = expectLater(
          second,
          throwsA(isA<DeciderCancelledException>()),
        ).then((_) => secondDone = true);
        await pumpEventQueue();
        expect(secondDone, isTrue, reason: 'not after the first decision');
        gate.complete();
        await first;
        await secondExpect;
        expect(scorer.scoreCalls, 1);
      },
    );

    test('a close fails the running and the waiting decision alike, as '
        'cancelled', () async {
      final (decider, scorer) = await _emotionDecider();
      final gate = Completer<void>();
      scorer.tokenizeGate = gate;
      final first = decider.choose(DeciderInput(EmbeddingInput.text('one')));
      final second = decider.choose(DeciderInput(EmbeddingInput.text('two')));
      final firstFails = expectLater(
        first,
        throwsA(isA<DeciderCancelledException>()),
      );
      final secondFails = expectLater(
        second,
        throwsA(isA<DeciderCancelledException>()),
      );
      await pumpEventQueue();
      final closing = decider.close();
      gate.complete();
      await closing;
      await firstFails;
      await secondFails;
      // A choose after the close is not a cancel.
      await expectLater(
        decider.choose(DeciderInput(EmbeddingInput.text('three'))),
        throwsStateError,
      );
    });

    test('two choose calls left unawaited run one after the other', () async {
      final (decider, scorer) = await _emotionDecider();
      final gate = Completer<void>();
      scorer.tokenizeGate = gate;
      final rendersBefore = scorer.renderCalls;
      final first = decider.choose(DeciderInput(EmbeddingInput.text('one')));
      final second = decider.choose(DeciderInput(EmbeddingInput.text('two')));
      await pumpEventQueue();
      expect(
        scorer.renderCalls - rendersBefore,
        1,
        reason: 'the second waits for the first',
      );
      gate.complete();
      await Future.wait([first, second]);
      expect(scorer.renderCalls - rendersBefore, 2);
      expect(scorer.scoreCalls, 2);
    });
  });

  group('DeciderAnswer for Noul and Score', () {
    /// An answer whose ranked list follows [p], highest first, unless
    /// [choice] is given: then it is ranked first.
    DeciderAnswer make({
      DeciderQuestionType type = DeciderQuestionType.noul,
      Map<String, double> p = const {'no': 0.25, 'yes': 0.75},
      Map<String, String>? legend,
      AbstainReason? reason,
      String? choice,
      double? threshold,
    }) {
      final byP = p.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final ids = [
        if (choice != null) choice,
        for (final e in byP)
          if (e.key != choice) e.key,
      ];
      return DeciderAnswer(
        choice: reason == null ? ids.first : null,
        ranked: [
          for (var i = 0; i < ids.length; i++)
            RankedOption(
              id: ids[i],
              score: -i.toDouble(),
              probability: p[ids[i]],
            ),
        ],
        scoreKind: ScoreKind.logprob,
        margin: 1,
        probabilities: p,
        abstainReason: reason,
        provenance: DeciderProvenance(
          method: DeciderMethod.optionScoring,
          calibration: 'supplied',
          encodeTime: Duration.zero,
          scoreTime: Duration.zero,
          threshold: threshold,
          abstainSignal: threshold == null ? null : p[ids.first],
          abstainSignalKind: threshold == null
              ? null
              : AbstainSignalKind.topProbability,
        ),
        questionType: type,
        legend: legend,
      );
    }

    test('noul and expectedLevel are read from the probabilities', () {
      expect(make().noul, 0.75);
      expect(make().expectedLevel, isNull);
      final score = make(
        type: DeciderQuestionType.score,
        p: const {'0': 0.2, '1': 0.3, '2': 0.5},
        legend: const {'0': 'low', '1': 'mid', '2': 'high'},
      );
      expect(score.expectedLevel, closeTo(1.3, 1e-12));
      expect(score.noul, isNull);
    });

    test('contradictions are refused', () {
      expect(
        () => make(p: const {'a': 0.25, 'b': 0.75}),
        throwsArgumentError,
        reason: 'noul options are no and yes',
      );
      expect(
        () => make(reason: AbstainReason.noneOption),
        throwsArgumentError,
        reason: 'a noul never abstains',
      );
      expect(
        () => make(choice: 'no'),
        throwsArgumentError,
        reason: 'a noul chooses its most probable option',
      );
      expect(
        () => make(threshold: 0.5),
        throwsArgumentError,
        reason: 'a noul has no threshold',
      );
      expect(
        () => make(legend: const {'0': 'x'}),
        throwsArgumentError,
        reason: 'a noul has no legend',
      );
      expect(
        () => make(
          type: DeciderQuestionType.score,
          p: const {'0': 0.2, '1': 0.3, '2': 0.5},
          legend: const {'0': 'low', '1': 'mid'},
        ),
        throwsArgumentError,
        reason: 'a legend for each level',
      );
      expect(
        () => make(
          type: DeciderQuestionType.score,
          p: const {'0': 0.2, '1': 0.3, '2': 0.5},
          legend: const {'0': 'low', '1': '', '2': 'high'},
        ),
        throwsArgumentError,
        reason: 'no empty level text',
      );
      expect(
        () =>
            make(type: DeciderQuestionType.choice, legend: const {'0': 'low'}),
        throwsArgumentError,
        reason: 'a choice answer has no legend',
      );
    });
  });

  test(
    'choose refuses an answer of another type than the decider says',
    () async {
      await expectLater(
        _NoulSayingChoice().choose(DeciderInput(EmbeddingInput.text('hello'))),
        throwsStateError,
      );
    },
  );
}

/// A decider that claims Choice and answers Noul.
final class _NoulSayingChoice extends Decider {
  @override
  DeciderCapabilities get capabilities => const DeciderCapabilities(
    modalities: {EmbeddingModality.text},
    calibratedProbabilities: true,
    supportsContext: false,
    supportsAmong: false,
    storable: false,
  );

  @override
  List<DeciderOption> get options => [
    DeciderOption('no'),
    DeciderOption('yes'),
  ];

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Future<DeciderAnswer> decide(DeciderRequest request) async => DeciderAnswer(
    choice: 'yes',
    ranked: const [
      RankedOption(id: 'yes', score: -0.1, probability: 0.9),
      RankedOption(id: 'no', score: -2.3, probability: 0.1),
    ],
    scoreKind: ScoreKind.logprob,
    margin: 2.2,
    probabilities: const {'no': 0.1, 'yes': 0.9},
    provenance: const DeciderProvenance(
      method: DeciderMethod.optionScoring,
      calibration: 'supplied',
      encodeTime: Duration.zero,
      scoreTime: Duration.zero,
    ),
    questionType: DeciderQuestionType.noul,
  );
}
