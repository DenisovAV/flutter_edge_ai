// finalizeEmbedding: the one function that turns a graph's ForwardResult into
// the final vector (was the embedding worker's private _finalize).

import 'package:flutter_edge_ai/src/embedding/forward_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('finalizeEmbedding', () {
    test('pooledFinal copies a [1, dim] result verbatim, into a new list', () {
      final values = [3.0, 4.0];
      final result = ForwardResult(values: values, shape: const [1, 2]);

      final vector = finalizeEmbedding(
        EmbeddingOutputContract.pooledFinal,
        result,
      );

      // Not normalised: [3, 4] would become [0.6, 0.8] (Invariant I0).
      expect(vector, [3.0, 4.0]);
      expect(identical(vector, values), isFalse);
    });

    test(
      'pooledFinal refuses a token-level shape instead of flattening it',
      () {
        const result = ForwardResult(values: [1, 0, 0, 1], shape: [1, 2, 2]);

        expect(
          () => finalizeEmbedding(EmbeddingOutputContract.pooledFinal, result),
          throwsStateError,
        );
      },
    );

    test('pooledFinal refuses values that disagree with the shape', () {
      const result = ForwardResult(values: [1, 2, 3], shape: [1, 2]);

      expect(
        () => finalizeEmbedding(EmbeddingOutputContract.pooledFinal, result),
        throwsStateError,
      );
    });

    test('tokenLevel mean-pools over the mask it is given and normalises', () {
      // Two real tokens [1,0] and [0,1], one padded [999,0] — lopsided, so
      // pooling the padding in would change the direction, not just the norm.
      const result = ForwardResult(
        values: [1, 0, 0, 1, 999, 0],
        shape: [1, 3, 2],
      );

      final vector = finalizeEmbedding(
        EmbeddingOutputContract.tokenLevel,
        result,
        attentionMask: const [1, 1, 0],
      );

      // mean([1,0],[0,1]) = [0.5, 0.5] → normalised [0.7071, 0.7071].
      expect(vector[0], closeTo(0.70710678, 1e-6));
      expect(vector[1], closeTo(0.70710678, 1e-6));
    });

    test('tokenLevel without a mask averages every position', () {
      const result = ForwardResult(
        values: [1, 0, 0, 1, 2, 2],
        shape: [1, 3, 2],
      );

      final vector = finalizeEmbedding(
        EmbeddingOutputContract.tokenLevel,
        result,
      );

      // mean = [1, 1] → [0.7071, 0.7071]; a dropped mask would change nothing
      // here, the masked case above is the one that pins the mask.
      expect(vector[0], closeTo(0.70710678, 1e-6));
      expect(vector[1], closeTo(0.70710678, 1e-6));
    });
  });
}
