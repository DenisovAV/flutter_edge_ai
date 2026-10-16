// DeciderAnswer refuses a contradiction in its own fields, and the value sets
// an app switches on are class constants (a value added later does not break
// an exhaustive switch).

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/embedding_decider.dart'
    show deciderConfidence;
import 'package:flutter_test/flutter_test.dart';

const _provenance = DeciderProvenance(
  method: DeciderMethod.centroid,
  calibration: 'none',
  spaceId: 'test',
  encodeTime: Duration.zero,
  scoreTime: Duration.zero,
);

/// A provenance with an abstain signal compared with a threshold.
DeciderProvenance _signal(
  double? signal,
  double? threshold, {
  AbstainSignalKind? kind = AbstainSignalKind.topCosine,
  DeciderMethod method = DeciderMethod.centroid,
}) => DeciderProvenance(
  method: method,
  calibration: 'crossFit',
  encodeTime: Duration.zero,
  scoreTime: Duration.zero,
  threshold: threshold,
  abstainSignal: signal,
  abstainSignalKind: kind,
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
  DeciderProvenance provenance = _provenance,
}) => DeciderAnswer(
  choice: choice,
  ranked: ranked,
  scoreKind: ScoreKind.cosine,
  margin: 0.4,
  provenance: provenance,
  confidence: confidence,
  abstainReason: abstainReason,
  probabilities: probabilities,
);

void main() {
  group('DeciderAnswer refuses', () {
    final cases = <String, DeciderAnswer Function()>{
      'a choice and an abstain reason': () => _answer(
        abstainReason: AbstainReason.belowThreshold,
        provenance: _signal(0.3, 0.5),
      ),
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
      'an abstain signal without its kind': () =>
          _answer(provenance: _signal(0.7, 0.5, kind: null)),
      'an abstain signal kind without a signal': () =>
          _answer(provenance: _signal(null, 0.5)),
      'belowThreshold without a signal': () => _answer(
        choice: null,
        abstainReason: AbstainReason.belowThreshold,
        provenance: _signal(null, 0.5, kind: null),
      ),
      'belowThreshold without a threshold': () => _answer(
        choice: null,
        abstainReason: AbstainReason.belowThreshold,
        provenance: _signal(0.3, null),
      ),
      'belowThreshold with the signal at the threshold': () => _answer(
        choice: null,
        abstainReason: AbstainReason.belowThreshold,
        provenance: _signal(0.5, 0.5),
      ),
      'a choice with the signal below the threshold': () =>
          _answer(provenance: _signal(0.49, 0.5)),
      'noneOption with nothing ranked': () => _answer(
        choice: null,
        ranked: const [],
        confidence: null,
        probabilities: null,
        abstainReason: AbstainReason.noneOption,
      ),
      'noCandidates with candidates ranked': () =>
          _answer(choice: null, abstainReason: AbstainReason.noCandidates),
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
      provenance: _signal(0.3, 0.5),
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
    expect(
      _answer(provenance: _signal(0.5, 0.5)).choice,
      'a',
      reason: 'a signal at the threshold chooses',
    );
    expect(
      _answer(provenance: _signal(0.2, null)).choice,
      'a',
      reason: 'a signal is reported without a threshold',
    );
  });

  test('an inference decider\'s answer fits the same contract', () {
    // Option scoring: logprob scores, probabilities from a temperature, a
    // probability signal, and a trained "none of these" option.
    const probabilities = {'joy': 0.55, 'sadness': 0.3, 'none': 0.15};
    const ranked = [
      RankedOption(id: 'joy', score: -0.6, probability: 0.55),
      RankedOption(id: 'sadness', score: -1.2, probability: 0.3),
      RankedOption(id: 'none', score: -1.9, probability: 0.15),
    ];
    final chose = DeciderAnswer(
      choice: 'joy',
      ranked: ranked,
      scoreKind: ScoreKind.logprob,
      margin: 0.6,
      confidence: 0.325,
      probabilities: probabilities,
      provenance: _signal(
        0.55,
        0.5,
        kind: AbstainSignalKind.topProbability,
        method: DeciderMethod.optionScoring,
      ),
    );
    expect(chose.toJevJson(), {
      'type': 'choice',
      'choice': 'joy',
      'probabilities': probabilities,
      'confidence': 0.325,
    });
    final noneWon = DeciderAnswer(
      choice: null,
      ranked: const [
        RankedOption(id: 'none', score: -0.3, probability: 0.74),
        RankedOption(id: 'joy', score: -1.6, probability: 0.2),
      ],
      scoreKind: ScoreKind.logprob,
      margin: 1.3,
      abstainReason: AbstainReason.noneOption,
      probabilities: const {'none': 0.74, 'joy': 0.2, 'sadness': 0.06},
      provenance: _signal(
        0.74,
        0.5,
        kind: AbstainSignalKind.topProbability,
        method: DeciderMethod.optionScoring,
      ),
    );
    expect(noneWon.toJevJson()['choice'], isNull);
  });

  test('confidence of a uniform distribution is 0, never below', () {
    // 49 · (1/49) is 0.9999999999999999 in doubles.
    for (final n in [2, 3, 7, 49, 98, 150]) {
      final c = deciderConfidence(1 / n, n);
      expect(c, inInclusiveRange(0, 1), reason: 'n $n: $c');
    }
    expect(deciderConfidence(1, 4), 1);
  });

  test('ScoreKind, AbstainReason and AbstainSignalKind are class constants '
      'with names', () {
    expect(ScoreKind.values, [ScoreKind.cosine, ScoreKind.logprob]);
    expect(ScoreKind.values.map((k) => k.name), ['cosine', 'logprob']);
    expect(AbstainReason.values, [
      AbstainReason.belowThreshold,
      AbstainReason.noCandidates,
      AbstainReason.noneOption,
    ]);
    expect(AbstainReason.values.map((r) => r.name), [
      'belowThreshold',
      'noCandidates',
      'noneOption',
    ]);
    expect(AbstainSignalKind.values.map((k) => k.name), [
      'topCosine',
      'topProbability',
    ]);
    expect(DeciderMethod.optionScoring.name, 'optionScoring');
    expect('${ScoreKind.cosine}', 'ScoreKind.cosine');
    expect('${AbstainReason.noCandidates}', 'AbstainReason.noCandidates');
    expect(
      '${AbstainSignalKind.topProbability}',
      'AbstainSignalKind.topProbability',
    );
    expect(ScoreKind.cosine, isNot(isA<Enum>()));
    expect(AbstainReason.noCandidates, isNot(isA<Enum>()));
    expect(AbstainSignalKind.topCosine, isNot(isA<Enum>()));
  });
}
