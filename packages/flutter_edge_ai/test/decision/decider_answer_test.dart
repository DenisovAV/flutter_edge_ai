// DeciderAnswer refuses a contradiction in its own fields, and the two value
// sets an app switches on are class constants (a value added later does not
// break an exhaustive switch).

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/embedding_decider.dart'
    show deciderConfidence;
import 'package:flutter_test/flutter_test.dart';

const _provenance = DeciderProvenance(
  method: DeciderMethod.centroid,
  calibration: 'none',
  spaceId: 'test',
  embedTime: Duration.zero,
  scoreTime: Duration.zero,
);

DeciderAnswer _answer({
  String? choice = 'a',
  List<RankedOption> ranked = const [
    RankedOption(id: 'a', score: 0.9, probability: 0.7),
    RankedOption(id: 'b', score: 0.5, probability: 0.3),
  ],
  double? confidence = 0.4,
  AbstainReason? abstainReason,
  Map<String, double>? probabilities = const {'a': 0.7, 'b': 0.3},
}) => DeciderAnswer(
  choice: choice,
  ranked: ranked,
  scoreKind: ScoreKind.cosine,
  margin: 0.4,
  provenance: _provenance,
  confidence: confidence,
  abstainReason: abstainReason,
  probabilities: probabilities,
);

void main() {
  group('DeciderAnswer refuses', () {
    final cases = <String, DeciderAnswer Function()>{
      'a choice and an abstain reason': () =>
          _answer(abstainReason: AbstainReason.belowThreshold),
      'neither a choice nor an abstain reason': () => _answer(choice: null),
      'a choice that is not the best ranked option': () => _answer(choice: 'b'),
      'a confidence without probabilities': () => _answer(
        probabilities: null,
        ranked: const [
          RankedOption(id: 'a', score: 0.9),
          RankedOption(id: 'b', score: 0.5),
        ],
      ),
      'a confidence above 1': () => _answer(confidence: 1.01),
      'a confidence below 0': () => _answer(confidence: -0.01),
      'a NaN confidence': () => _answer(confidence: double.nan),
      'a ranked probability that is not the one in probabilities': () =>
          _answer(
            ranked: const [
              RankedOption(id: 'a', score: 0.9, probability: 0.6),
              RankedOption(id: 'b', score: 0.5, probability: 0.3),
            ],
          ),
      'ranked scores that are not descending': () => _answer(
        choice: 'b',
        ranked: const [
          RankedOption(id: 'b', score: 0.5, probability: 0.3),
          RankedOption(id: 'a', score: 0.9, probability: 0.7),
        ],
      ),
    };
    for (final MapEntry(key: name, value: build) in cases.entries) {
      test(name, () => expect(build, throwsArgumentError));
    }
  });

  test('consistent answers construct', () {
    expect(_answer().choice, 'a');
    final abstained = _answer(
      choice: null,
      abstainReason: AbstainReason.belowThreshold,
    );
    expect(abstained.choice, isNull);
    final none = DeciderAnswer(
      choice: null,
      ranked: const [],
      scoreKind: ScoreKind.logprob,
      margin: 0,
      abstainReason: AbstainReason.noCandidates,
      provenance: _provenance,
    );
    expect(none.ranked, isEmpty);
    expect(
      _answer(
        ranked: const [
          RankedOption(id: 'a', score: 0.9, probability: 0.7),
          RankedOption(id: 'b', score: 0.9, probability: 0.3),
        ],
      ).ranked,
      hasLength(2),
      reason: 'a tie is descending',
    );
  });

  test('confidence of a uniform distribution is 0, never below', () {
    // 49 · (1/49) is 0.9999999999999999 in doubles.
    for (final n in [2, 3, 7, 49, 98, 150]) {
      final c = deciderConfidence(1 / n, n);
      expect(c, inInclusiveRange(0, 1), reason: 'n $n: $c');
    }
    expect(deciderConfidence(1, 4), 1);
  });

  test('ScoreKind and AbstainReason are class constants with names', () {
    expect(ScoreKind.values, [ScoreKind.cosine, ScoreKind.logprob]);
    expect(ScoreKind.values.map((k) => k.name), ['cosine', 'logprob']);
    expect(AbstainReason.values, [
      AbstainReason.belowThreshold,
      AbstainReason.noCandidates,
    ]);
    expect(AbstainReason.values.map((r) => r.name), [
      'belowThreshold',
      'noCandidates',
    ]);
    expect('${ScoreKind.cosine}', 'ScoreKind.cosine');
    expect('${AbstainReason.noCandidates}', 'AbstainReason.noCandidates');
    expect(ScoreKind.cosine, isNot(isA<Enum>()));
    expect(AbstainReason.noCandidates, isNot(isA<Enum>()));
  });
}
