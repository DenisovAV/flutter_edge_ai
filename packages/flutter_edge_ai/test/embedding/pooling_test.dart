// Host unit tests for `pooling.dart`'s mean-pool + L2-normalize helper.
//
// Pure Dart, no dlopen, no isolate — exercises the pooling math on fixed
// [ForwardResult]s, the shape a graph hands back.

import 'dart:math' as math;

import 'package:flutter_edge_ai/src/embedding/forward_result.dart';
import 'package:flutter_edge_ai/src/embedding/pooling.dart';
import 'package:flutter_test/flutter_test.dart';

double _l2Norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (acc, x) => acc + x * x));

void main() {
  group('meanPoolAndNormalize', () {
    test('[1, seq, dim] mean-pools over the seq axis and L2-normalizes', () {
      // seq=3, dim=2:
      //   token0 = [1, 0]
      //   token1 = [0, 1]
      //   token2 = [2, 2]
      // mean = [1, 1] -> L2 norm sqrt(2) -> [1/sqrt2, 1/sqrt2]
      const result = ForwardResult(
        values: [1, 0, 0, 1, 2, 2],
        shape: [1, 3, 2],
      );

      final pooled = meanPoolAndNormalize(result);

      expect(pooled.length, 2);
      expect(_l2Norm(pooled), closeTo(1.0, 1e-9));
      expect(pooled[0], closeTo(1 / math.sqrt(2), 1e-9));
      expect(pooled[1], closeTo(1 / math.sqrt(2), 1e-9));
    });

    test(
      'attentionMask excludes masked-out (padding) tokens from the mean',
      () {
        // seq=3, dim=2; token2 is padding (mask=0) with an extreme value that
        // must NOT influence the pooled result.
        const result = ForwardResult(
          values: [1, 0, 0, 1, 999, 999],
          shape: [1, 3, 2],
        );

        final pooled = meanPoolAndNormalize(result, attentionMask: [1, 1, 0]);

        // mean over unmasked tokens only = mean([1,0],[0,1]) = [0.5, 0.5]
        // normalized -> [1/sqrt2, 1/sqrt2]
        expect(_l2Norm(pooled), closeTo(1.0, 1e-9));
        expect(pooled[0], closeTo(1 / math.sqrt(2), 1e-6));
        expect(pooled[1], closeTo(1 / math.sqrt(2), 1e-6));
      },
    );

    test(
      '[1, dim] (already-final) is REJECTED — must not be re-normalized (D5 trap)',
      () {
        // A rank-2 result is the final embedding (e.g. LiteRT). Routing it
        // through meanPoolAndNormalize would re-apply L2 (the D5 double-
        // normalize regression), so it must throw, forcing callers onto the
        // EmbeddingOutputContract.pooledFinal verbatim-copy path.
        const result = ForwardResult(values: [3, 4], shape: [1, 2]);

        expect(() => meanPoolAndNormalize(result), throwsArgumentError);
      },
    );

    test('rejects an unsupported rank', () {
      const result = ForwardResult(values: [1, 2, 3], shape: [3]);

      expect(() => meanPoolAndNormalize(result), throwsArgumentError);
    });
  });
}
