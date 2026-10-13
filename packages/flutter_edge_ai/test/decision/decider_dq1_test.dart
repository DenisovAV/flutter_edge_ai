// The embedding decider held to its reference: the decision measurements'
// dq1.py, run by fixtures/make_dq1_fixture.py on real EmbeddingGemma 2
// vectors (CLINC150, LiteRT-LM 0.18.0, classification prompt). The fixture
// stores the vectors as the float16 they were saved as and what dq1's own
// functions computed from them; here the decider computes the same from the
// same vectors.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_edge_ai/src/decision/softmax_regression.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

final _json =
    jsonDecode(
          File('test/decision/fixtures/dq1_fixture.json').readAsStringSync(),
        )
        as Map<String, Object?>;
final _bin = File('test/decision/fixtures/dq1_fixture.bin').readAsBytesSync();
final int _d = _json['dimension']! as int;
final _expected = _json['expected']! as Map<String, Object?>;

/// IEEE half → double.
double _half(int h) {
  final sign = (h & 0x8000) != 0 ? -1.0 : 1.0;
  final exp = (h >> 10) & 0x1F;
  final frac = h & 0x3FF;
  if (exp == 0) return sign * frac * math.pow(2, -24);
  if (exp == 31) return frac == 0 ? sign * double.infinity : double.nan;
  return sign * (1 + frac / 1024) * math.pow(2, exp - 15);
}

/// Row [row] of the fixture as stored (float16 → double, not normalised).
List<double> _row(int row) {
  final data = ByteData.sublistView(_bin);
  return [
    for (var j = 0; j < _d; j++)
      _half(data.getUint16((row * _d + j) * 2, Endian.little)),
  ];
}

Map<String, Object?> _section(String name) =>
    _json[name]! as Map<String, Object?>;
List<int> _ints(Object? list) => (list! as List).cast<int>();
List<double> _doubles(Object? list) => [
  for (final v in list! as List) (v as num).toDouble(),
];
List<List<double>> _matrix(Object? list) => [
  for (final row in list! as List) _doubles(row),
];

final _exLabels = _ints(_section('examples')['labels']);
final _exRanks = _ints(_section('examples')['ranks']);
final int _probeRows = _section('probe')['rows']! as int;
final _calLabels = _ints(_section('calibration')['labels']);
int get _exRows => _exLabels.length;
int get _optionCount => _exLabels.reduce(math.max) + 1;

/// Text keys the fake embedder maps to fixture rows.
String _exKey(int i) => 'ex:$i';
String _probeKey(int i) => 'probe:$i';
String _calKey(int i) => 'cal:$i';

FakeEmbedder _embedder() {
  final table = <String, List<double>>{};
  for (var i = 0; i < _exRows; i++) {
    table[_exKey(i)] = _row(i);
  }
  for (var i = 0; i < _probeRows; i++) {
    table[_probeKey(i)] = _row(_exRows + i);
  }
  for (var i = 0; i < _calLabels.length; i++) {
    table[_calKey(i)] = _row(_exRows + _probeRows + i);
  }
  return FakeEmbedder(dimension: _d, table: table);
}

List<DeciderOption> _options() => [
  for (var o = 0; o < _optionCount; o++)
    DeciderOption(
      'o$o',
      examples: [
        for (var i = 0; i < _exRows; i++)
          if (_exLabels[i] == o) EmbeddingInput.text(_exKey(i)),
      ],
    ),
];

Float64List _unitRows(int from, int count) {
  final out = Float64List(count * _d);
  for (var i = 0; i < count; i++) {
    final v = _row(from + i);
    final norm = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
    for (var j = 0; j < _d; j++) {
      out[i * _d + j] = v[j] / norm;
    }
  }
  return out;
}

List<double> _logSoftmax(List<double> z) {
  final m = z.reduce(math.max);
  final lse = m + math.log(z.fold(0.0, (s, v) => s + math.exp(v - m)));
  return [for (final v in z) v - lse];
}

int _argmax(List<double> v) {
  var best = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[best]) best = i;
  }
  return best;
}

Future<List<DeciderAnswer>> _probe(Decider decider) => Future.wait([
  for (var i = 0; i < _probeRows; i++)
    decider.choose(
      DeciderInput(EmbeddingInput.text(_probeKey(i))),
      topK: _optionCount,
    ),
]);

double _scoreOf(DeciderAnswer answer, String id) =>
    answer.ranked.firstWhere((r) => r.id == id).score;

void main() {
  test('the fixture is what make_dq1_fixture.py wrote', () {
    expect(_bin.length, (_exRows + _probeRows + _calLabels.length) * _d * 2);
    expect(_optionCount, 4);
    expect(_exRows, 28);
  });

  test('cross-fit signal and threshold equal dq1 C3ii (keep 0.95)', () {
    final x = _unitRows(0, _exRows);
    final signal = crossFitSignal(
      x,
      Int32List.fromList(_exLabels),
      Int32List.fromList(_exRanks),
      _d,
      _optionCount,
      null,
    );
    final expected = _doubles(_expected['crossfit_oof_signal']);
    for (var i = 0; i < _exRows; i++) {
      expect(signal[i], closeTo(expected[i], 1e-12), reason: 'row $i');
    }
    expect(
      keepThreshold(signal, 0.95),
      closeTo(_expected['crossfit_threshold_keep95']! as double, 1e-12),
    );
  });

  test('a centroid decider: dq1 cosines, ranking and C3ii abstain', () async {
    final decider = await _embedder().createDecider(
      options: _options(),
      embedderId: 'dq1-fixture',
    );
    final threshold = _expected['crossfit_threshold_keep95']! as double;
    final cosines = _matrix(_expected['centroid_cosines']);
    final answers = await _probe(decider);
    var abstained = 0;
    for (var i = 0; i < _probeRows; i++) {
      final answer = answers[i];
      expect(answer.scoreKind, ScoreKind.cosine);
      for (var o = 0; o < _optionCount; o++) {
        // Centroids are kept (and stored) as float32.
        expect(_scoreOf(answer, 'o$o'), closeTo(cosines[i][o], 1e-6));
      }
      final best = _argmax(cosines[i]);
      expect(answer.ranked.first.id, 'o$best');
      final signal = cosines[i][best];
      expect(answer.provenance.similarity, closeTo(signal, 1e-6));
      expect(answer.provenance.threshold, closeTo(threshold, 1e-12));
      expect(answer.choice, signal >= threshold ? 'o$best' : isNull);
      if (answer.choice == null) {
        abstained++;
        expect(answer.abstainReason, AbstainReason.belowThreshold);
      }
      final sorted = [...cosines[i]]..sort();
      expect(
        answer.margin,
        closeTo(sorted.last - sorted[sorted.length - 2], 2e-6),
      );
      expect(answer.probabilities, isNull);
      expect(answer.confidence, isNull);
    }
    // The 12 out-of-subset rows are the ones that should be refused.
    expect(abstained, greaterThan(0));
  });

  test('softmax regression reaches dq1 fit_linear\'s optimum', () {
    final fit = fitSoftmaxRegression(
      x: _unitRows(0, _exRows),
      labels: Int32List.fromList(_exLabels),
      dimension: _d,
      classes: _optionCount,
    );
    expect(
      fit.loss,
      closeTo(_expected['linear_loss']! as double, 1e-6),
      reason: '${fit.iterations} iterations, ${fit.evaluations} evaluations',
    );
    final probes = _unitRows(_exRows, _probeRows);
    final logits = _matrix(_expected['linear_logits']);
    for (var i = 0; i < _probeRows; i++) {
      for (var o = 0; o < _optionCount; o++) {
        var z = fit.bias[o];
        for (var j = 0; j < _d; j++) {
          z += probes[i * _d + j] * fit.weights[j * _optionCount + o];
        }
        expect(z, closeTo(logits[i][o], 1e-8));
      }
    }
  });

  test('a linear decider ranks by dq1\'s log-softmax', () async {
    final decider = await _embedder().createDecider(
      options: _options(),
      method: DeciderMethod.linear,
      calibration: const DeciderCalibration.none(),
      embedderId: 'dq1-fixture',
    );
    final logits = _matrix(_expected['linear_logits']);
    final answers = await _probe(decider);
    for (var i = 0; i < _probeRows; i++) {
      final expected = _logSoftmax(logits[i]);
      expect(answers[i].scoreKind, ScoreKind.logprob);
      expect(answers[i].choice, 'o${_argmax(logits[i])}');
      for (var o = 0; o < _optionCount; o++) {
        expect(_scoreOf(answers[i], 'o$o'), closeTo(expected[o], 1e-5));
      }
    }
  });

  for (final method in [DeciderMethod.centroid, DeciderMethod.linear]) {
    test('fromLabelled on ${method.name}: dq1 C1 temperature, threshold and '
        'probabilities', () async {
      final expected =
          (_expected['labelled']! as Map<String, Object?>)[method.name]!
              as Map<String, Object?>;
      final decider = await _embedder().createDecider(
        options: _options(),
        method: method,
        calibration: DeciderCalibration.fromLabelled([
          for (var i = 0; i < _calLabels.length; i++)
            (
              input: EmbeddingInput.text(_calKey(i)),
              optionId: 'o${_calLabels[i]}',
            ),
        ]),
        embedderId: 'dq1-fixture',
      );
      expect(decider.capabilities.calibratedProbabilities, isTrue);
      final artifact = decider.toArtifact();
      final calibration = artifact['calibration']! as Map<String, Object?>;
      expect(
        calibration['temperature']! as double,
        closeTo(expected['temperature']! as double, 1e-9),
      );
      expect(
        calibration['threshold']! as double,
        closeTo(expected['threshold']! as double, 1e-9),
      );
      final probabilities = _matrix(expected['probe_probabilities']);
      final answers = await _probe(decider);
      // Probabilities at choose time come from the float32 centroids/weights.
      const tolerance = 1e-5;
      for (var i = 0; i < _probeRows; i++) {
        final p = answers[i].probabilities!;
        expect(p.values.fold(0.0, (s, v) => s + v), closeTo(1, 1e-12));
        for (var o = 0; o < _optionCount; o++) {
          expect(p['o$o'], closeTo(probabilities[i][o], tolerance));
        }
        final pmax = p.values.reduce(math.max);
        expect(
          answers[i].confidence,
          closeTo((_optionCount * pmax - 1) / (_optionCount - 1), 1e-12),
        );
      }
    });
  }
}
