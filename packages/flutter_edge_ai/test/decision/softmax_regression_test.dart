// The fitting arithmetic: the SIMD and the scalar kernel agree bit for bit
// (web uses the scalar one), the objective's gradient is its derivative, and
// L-BFGS minimises.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_edge_ai/src/decision/softmax_regression.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic unit rows around [classes] directions.
(Float64List, Int32List, Int32List) _data(int classes, int perClass, int d) {
  final random = math.Random(7);
  final x = Float64List(classes * perClass * d);
  final labels = Int32List(classes * perClass);
  final ranks = Int32List(classes * perClass);
  for (var c = 0; c < classes; c++) {
    for (var k = 0; k < perClass; k++) {
      final row = c * perClass + k;
      labels[row] = c;
      ranks[row] = k;
      var norm = 0.0;
      for (var j = 0; j < d; j++) {
        final v = (j % classes == c ? 1.0 : 0.0) + random.nextDouble() - 0.5;
        x[row * d + j] = v;
        norm += v * v;
      }
      norm = math.sqrt(norm);
      for (var j = 0; j < d; j++) {
        x[row * d + j] /= norm;
      }
    }
  }
  return (x, labels, ranks);
}

void main() {
  test('SIMD and scalar fits are identical (odd class count, padded)', () {
    final (x, labels, ranks) = _data(5, 7, 24);
    final simd = fitSoftmaxRegression(
      x: x,
      labels: labels,
      dimension: 24,
      classes: 5,
      simd: true,
    );
    final scalar = fitSoftmaxRegression(
      x: x,
      labels: labels,
      dimension: 24,
      classes: 5,
      simd: false,
    );
    expect(simd.weights, scalar.weights);
    expect(simd.bias, scalar.bias);
    expect(simd.loss, scalar.loss);
    expect(simd.iterations, scalar.iterations);
    expect(
      crossFitSignal(x, labels, ranks, 24, 5, true),
      crossFitSignal(x, labels, ranks, 24, 5, false),
    );
  });

  test('the gradient is the objective\'s derivative', () {
    final (x, labels, _) = _data(3, 4, 6);
    final objective = SoftmaxObjective(
      x: x,
      labels: labels,
      dimension: 6,
      classes: 3,
      decay: 0.01,
    );
    final random = math.Random(3);
    final theta = Float64List.fromList([
      for (var i = 0; i < objective.parameterCount; i++)
        random.nextDouble() - 0.5,
    ]);
    final grad = Float64List(objective.parameterCount);
    objective.evaluate(theta, grad);
    const h = 1e-6;
    final scratch = Float64List(objective.parameterCount);
    for (var i = 0; i < theta.length; i++) {
      final plus = Float64List.fromList(theta)..[i] += h;
      final minus = Float64List.fromList(theta)..[i] -= h;
      final numeric =
          (objective.evaluate(plus, scratch) -
              objective.evaluate(minus, scratch)) /
          (2 * h);
      expect(grad[i], closeTo(numeric, 1e-7), reason: 'parameter $i');
    }
  });

  test('L-BFGS finds the minimum of a quadratic', () {
    // f(x) = Σ (i + 1) (x_i − i)²
    double f(Float64List x, Float64List g) {
      var value = 0.0;
      for (var i = 0; i < x.length; i++) {
        final r = x[i] - i;
        value += (i + 1) * r * r;
        g[i] = 2 * (i + 1) * r;
      }
      return value;
    }

    final x = Float64List(6);
    final result = minimizeLbfgs(f, x);
    // torch's stopping rules end it once the loss moves by < 1e-9.
    for (var i = 0; i < x.length; i++) {
      expect(x[i], closeTo(i, 1e-4));
    }
    expect(result.loss, closeTo(0, 1e-8));
  });

  test('fitted on separable data, the layer classifies its inputs', () {
    final (x, labels, _) = _data(4, 6, 16);
    final fit = fitSoftmaxRegression(
      x: x,
      labels: labels,
      dimension: 16,
      classes: 4,
    );
    for (var i = 0; i < labels.length; i++) {
      var best = 0;
      var bestZ = double.negativeInfinity;
      for (var c = 0; c < 4; c++) {
        var z = fit.bias[c];
        for (var j = 0; j < 16; j++) {
          z += x[i * 16 + j] * fit.weights[j * 4 + c];
        }
        if (z > bestZ) {
          bestZ = z;
          best = c;
        }
      }
      expect(best, labels[i]);
    }
  });

  test('error-budget threshold: dq1 threshold_conf on a hand example', () {
    // Sorted by signal: 0.9 ok, 0.8 wrong, 0.7 ok, 0.6 ok, 0.5 wrong.
    final signal = Float64List.fromList([0.6, 0.9, 0.5, 0.8, 0.7]);
    final ok = [true, true, false, false, true];
    // Error rates of the prefixes: 0, 1/2, 1/3, 1/4, 2/5.
    expect(errorBudgetThreshold(signal, ok, 0.25), 0.6);
    expect(errorBudgetThreshold(signal, ok, 0.4), 0.5);
    expect(errorBudgetThreshold(signal, ok, 0.0), 0.9);
    expect(
      errorBudgetThreshold(signal, [false, false, false, false, false], 0.1),
      greaterThan(1),
    );
  });

  test('keepThreshold: the floor((1 − keep)·n)-th smallest', () {
    final signal = Float64List.fromList([for (var i = 20; i > 0; i--) i / 20]);
    expect(keepThreshold(signal, 0.95), 2 / 20);
    expect(keepThreshold(signal, 1), 1 / 20);
    expect(keepThreshold(signal, 0.5), 11 / 20);
    expect(keepThreshold(signal, 1e-9), 20 / 20);
  });

  test('fitTemperature: the grid value with the lowest NLL', () {
    // One row: the right class wins by 1 → the lowest temperature is best.
    expect(
      fitTemperature(Float64List.fromList([1, 0]), Int32List.fromList([0]), 2),
      closeTo(1e-3, 1e-15),
    );
    // Wrong by 1 → the highest temperature is best.
    expect(
      fitTemperature(Float64List.fromList([0, 1]), Int32List.fromList([0]), 2),
      closeTo(10, 1e-12),
    );
  });
}
