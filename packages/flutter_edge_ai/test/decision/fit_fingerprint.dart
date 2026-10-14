// A model-free fit fixture that every platform builds bit for bit the same:
// unit rows from a 32-bit xorshift (integer arithmetic that the VM, dart2js
// and dart2wasm agree on), and a fingerprint of the fit. The VM test
// (fit_fingerprint_test.dart) and the browser test (test/web/
// decider_web_test.dart) hold the same fingerprints, so the web fit equals
// the VM's.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/decision/decider_fit.dart';

/// Rows per option.
const fingerprintRowsPerOption = 10;

/// The embedding dimension (EmbeddingGemma's).
const fingerprintDimension = 768;

int _next(int x) {
  x ^= (x << 13) & 0xFFFFFFFF;
  x ^= x >> 17;
  x ^= (x << 5) & 0xFFFFFFFF;
  return x & 0xFFFFFFFF;
}

/// [c] options × [fingerprintRowsPerOption] unit rows near [c] directions.
DeciderFitRequest fingerprintRequest(int c, {required bool linear}) {
  const d = fingerprintDimension;
  const k = fingerprintRowsPerOption;
  final n = c * k;
  final x = Float64List(n * d);
  final labels = Int32List(n);
  final ranks = Int32List(n);
  var state = 0x9E3779B9 ^ c;
  for (var i = 0; i < n; i++) {
    labels[i] = i ~/ k;
    ranks[i] = i % k;
    var norm = 0.0;
    for (var j = 0; j < d; j++) {
      state = _next(state);
      final v = (j % c == labels[i] ? 1.0 : 0.0) + state / 4294967296.0 - 0.5;
      x[i * d + j] = v;
      norm += v * v;
    }
    norm = math.sqrt(norm);
    for (var j = 0; j < d; j++) {
      x[i * d + j] /= norm;
    }
  }
  return DeciderFitRequest(
    dimension: d,
    optionCount: c,
    optionIds: [for (var o = 0; o < c; o++) 'o$o'],
    inputs: x,
    labels: labels,
    ranks: ranks,
    linear: linear,
    calibration: 'crossFit',
    keep: 0.95,
  );
}

/// What two fits must agree on.
typedef FitFingerprint = ({
  double threshold,
  double centroids,
  double? weights,
  double? bias,
  double? loss,
  int? iterations,
});

double _weighted(List<double> values) {
  var sum = 0.0;
  for (var i = 0; i < values.length; i++) {
    sum += values[i] * (i % 13 + 1);
  }
  return sum;
}

FitFingerprint fingerprintOf(DeciderFit fit) => (
  threshold: fit.threshold!,
  centroids: _weighted(fit.centroids),
  weights: fit.weights == null ? null : _weighted(fit.weights!),
  bias: fit.bias == null ? null : _weighted(fit.bias!),
  loss: fit.linearLoss,
  iterations: fit.linearIterations,
);

// The VM's fingerprints, held by fit_fingerprint_test.dart and compared in
// the browser by test/web/decider_web_test.dart.

const FitFingerprint vmFingerprint10 = (
  threshold: 0.6846369634230898,
  centroids: 592.4032719262668,
  weights: null,
  bias: null,
  loss: null,
  iterations: null,
);
const FitFingerprint vmFingerprint10Linear = (
  threshold: 0.6846369634230898,
  centroids: 592.4032719262668,
  weights: 4.237198254742907,
  bias: 0.3715923661366105,
  loss: 0.012782657169983128,
  iterations: 23,
);
const FitFingerprint vmFingerprint50 = (
  threshold: 0.3113206219835883,
  centroids: 1126.5608935011073,
  weights: null,
  bias: null,
  loss: null,
  iterations: null,
);
const FitFingerprint vmFingerprint50Linear = (
  threshold: 0.3113206219835883,
  centroids: 1126.5608935011073,
  weights: 147.02073446354916,
  bias: 0.180892811215017,
  loss: 0.1302050277237472,
  iterations: 31,
);
const FitFingerprint vmFingerprint150 = (
  threshold: 0.11369102885900292,
  centroids: 1578.3369116302788,
  weights: null,
  bias: null,
  loss: null,
  iterations: null,
);
const FitFingerprint vmFingerprint150Linear = (
  threshold: 0.11369102885900292,
  centroids: 1578.3369116302788,
  weights: 366.869357645779,
  bias: 1.5209351135999896,
  loss: 0.5943936784237907,
  iterations: 37,
);
