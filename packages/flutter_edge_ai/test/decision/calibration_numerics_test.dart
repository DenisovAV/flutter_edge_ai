// The calibration arithmetic at its edges: float drift in the keep index,
// ties in the error budget, and a temperature the labelled rows cannot fit.

import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

Float64List _ascending(int n) =>
    Float64List.fromList([for (var i = 0; i < n; i++) i / n]);

void main() {
  group('keepThreshold', () {
    test('keep 0.9 of 10 keeps 9, not all 10', () {
      // (1 - 0.9) * 10 is 0.9999999999999998 in doubles.
      final signal = _ascending(10);
      final threshold = keepThreshold(signal, 0.9);
      final kept = signal.where((s) => s >= threshold).length;
      expect(kept, 9, reason: 'threshold $threshold');
    });

    test('keep 0.8 of 5000 keeps 4000', () {
      final signal = _ascending(5000);
      final threshold = keepThreshold(signal, 0.8);
      expect(signal.where((s) => s >= threshold).length, 4000);
    });

    test('keep 0.95 is unchanged (dq1 parity)', () {
      for (final n in [7, 20, 28, 100, 1500]) {
        final signal = _ascending(n);
        expect(
          keepThreshold(signal, 0.95),
          signal[(0.05 * n).floor()],
          reason: 'n $n',
        );
      }
    });
  });

  group('errorBudgetThreshold', () {
    test('a wrong row tied with a right one is never admitted with it', () {
      final threshold = errorBudgetThreshold(Float64List.fromList([0.8, 0.8]), [
        true,
        false,
      ], 0);
      expect(threshold, greaterThan(0.8), reason: 'admits both rows at 0.8');
    });

    test('ties are counted as a group', () {
      // 0.9 ok; 0.8 ok + 0.8 wrong; 0.7 ok. Budget 0.25: the 0.8 group
      // brings the error to 1/3, the 0.7 row to 1/4. Row by row, the right
      // 0.8 row (given first) would be admitted alone at 0.8.
      final signal = Float64List.fromList([0.8, 0.9, 0.7, 0.8]);
      final ok = [true, true, true, false];
      expect(errorBudgetThreshold(signal, ok, 0.25), 0.7);
      expect(errorBudgetThreshold(signal, ok, 0.2), 0.9);
    });
  });

  group('fitTemperature', () {
    test('rows that are all answered right with room to spare cannot '
        'calibrate: the best temperature is the grid floor', () async {
      await expectLater(
        fitTemperature(
          Float64List.fromList([1, 0, 0.9, 0.1]),
          Int32List.fromList([0, 0]),
          2,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('grid'),
          ),
        ),
      );
    });

    test(
      'rows answered wrong everywhere cannot calibrate: the ceiling',
      () async {
        await expectLater(
          fitTemperature(
            Float64List.fromList([0, 1]),
            Int32List.fromList([0]),
            2,
          ),
          throwsArgumentError,
        );
      },
    );

    test('an interior optimum is returned', () async {
      final temperature = await fitTemperature(
        Float64List.fromList([1, 0, 0.45, 0.55]),
        Int32List.fromList([0, 0]),
        2,
      );
      expect(temperature, greaterThan(1e-3));
      expect(temperature, lessThan(10));
    });

    test(
      'scores that are not finite are an error, not temperature 1',
      () async {
        await expectLater(
          fitTemperature(
            Float64List.fromList([double.nan, 0, 0.4, 0.6]),
            Int32List.fromList([0, 0]),
            2,
          ),
          throwsStateError,
        );
      },
    );
  });

  test('fromLabelled with one labelled row is always refused', () async {
    final embedder = FakeEmbedder(
      dimension: 2,
      table: {
        'a1': [1, 0],
        'a2': [0.9, 0.1],
        'b1': [0, 1],
        'b2': [0.1, 0.9],
        'right': [1, 0.2],
        'wrong': [0.2, 1],
      },
    );
    final options = [
      DeciderOption(
        'a',
        examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
      ),
      DeciderOption(
        'b',
        examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
      ),
    ];
    for (final row in ['right', 'wrong']) {
      await expectLater(
        embedder.createDecider(
          options: options,
          calibration: EmbeddingDeciderCalibration.fromLabelled([
            (input: EmbeddingInput.text(row), optionId: 'a'),
          ]),
          embedderId: 'fake',
        ),
        throwsArgumentError,
        reason: 'one "$row" row',
      );
    }
  });
}
