// The fit never hands back a parameter computed from nothing: a centroid of
// inputs that cancel out, a NaN in the optimiser, a non-finite result.

import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_edge_ai/src/decision/softmax_regression.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

void main() {
  test('an option whose inputs cancel out is refused, not given a NaN '
      'centroid', () async {
    final embedder = FakeEmbedder(
      dimension: 3,
      table: {
        'up': [1, 0, 0],
        'down': [-1, 0, 0],
        'b1': [0, 1, 0],
        'b2': [0, 0.9, 0.1],
      },
    );
    final created = embedder.createDecider(
      options: [
        DeciderOption(
          'a',
          examples: [EmbeddingInput.text('up'), EmbeddingInput.text('down')],
        ),
        DeciderOption(
          'b',
          examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
        ),
      ],
      calibration: const DeciderCalibration.none(),
      embedderId: 'fake',
    );
    await expectLater(
      created,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('option "a"'),
        ),
      ),
    );
  });

  test('a NaN in the gradient is not read as convergence', () async {
    // torch's `abs().max()` keeps a NaN, so the optimiser does not stop at
    // the start claiming a minimum; ignoring it returned the zero start as a
    // fitted layer with a finite loss.
    Future<double> f(Float64List x, Float64List g) async {
      var value = 0.0;
      for (var i = 0; i < x.length; i++) {
        value += x[i] * x[i];
        g[i] = 2 * x[i];
      }
      g[0] = double.nan;
      return value;
    }

    final x = Float64List(4);
    final result = await minimizeLbfgs(f, x);
    expect(
      result.iterations,
      greaterThan(0),
      reason: 'stopped at iteration 0: the NaN gradient read as converged',
    );
  });

  test('fitDecider refuses a non-finite fit', () {
    expect(
      () => checkFittedParameters(
        centroids: Float64List.fromList([1, 0, 0, 0]),
        dimension: 2,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('zero')),
      ),
    );
    expect(
      () => checkFittedParameters(
        centroids: Float64List.fromList([1, 0, double.nan, 1]),
        dimension: 2,
      ),
      throwsStateError,
    );
    expect(
      () => checkFittedParameters(
        centroids: Float64List.fromList([1, 0, 0, 1]),
        dimension: 2,
        threshold: double.infinity,
      ),
      throwsStateError,
    );
    for (final bad in [
      (weights: Float64List.fromList([double.nan]), bias: Float64List(1)),
      (weights: Float64List(1), bias: Float64List.fromList([double.nan])),
    ]) {
      expect(
        () => checkFittedParameters(
          centroids: Float64List.fromList([1, 0, 0, 1]),
          dimension: 2,
          weights: bad.weights,
          bias: bad.bias,
          loss: 0.1,
        ),
        throwsStateError,
      );
    }
    expect(
      () => checkFittedParameters(
        centroids: Float64List.fromList([1, 0, 0, 1]),
        dimension: 2,
        loss: double.nan,
      ),
      throwsStateError,
    );
    expect(
      () => checkFittedParameters(
        centroids: Float64List.fromList([1, 0, 0, 1]),
        dimension: 2,
        temperature: double.nan,
      ),
      throwsStateError,
    );
  });
}
