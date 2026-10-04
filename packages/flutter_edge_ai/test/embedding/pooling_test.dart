// Host unit tests for `pooling.dart`'s mean-pool + L2-normalize helper.
//
// Pure Dart, no dlopen, no isolate — exercises the pooling math via a fake
// [EmbeddingForwardPass] that returns a fixed [ForwardResult].

import 'dart:math' as math;

import 'package:flutter_edge_ai/core/embedding/forward_pass.dart';
import 'package:flutter_edge_ai/core/embedding/pooling.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake forward-pass returning a pre-baked [ForwardResult], for pipeline
/// tests that don't need a real (native) engine.
class _FakeForwardPass implements EmbeddingForwardPass {
  _FakeForwardPass(this._result);

  final ForwardResult _result;
  bool loaded = false;
  bool closed = false;
  List<int>? lastTokenIds;
  List<int>? lastAttentionMask;

  @override
  Future<void> load() async {
    loaded = true;
  }

  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async {
    lastTokenIds = tokenIds;
    lastAttentionMask = attentionMask;
    return _result;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  int get outputDimension => 0;

  @override
  int? get inputSequenceLength => null;

  @override
  EmbeddingOutputContract? get outputContract => null;
}

double _l2Norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (acc, x) => acc + x * x));

void main() {
  group('meanPoolAndNormalize', () {
    test(
      '[1, seq, dim] mean-pools over the seq axis and L2-normalizes',
      () async {
        // seq=3, dim=2:
        //   token0 = [1, 0]
        //   token1 = [0, 1]
        //   token2 = [2, 2]
        // mean = [1, 1] -> L2 norm sqrt(2) -> [1/sqrt2, 1/sqrt2]
        final fake = _FakeForwardPass(
          const ForwardResult(values: [1, 0, 0, 1, 2, 2], shape: [1, 3, 2]),
        );
        await fake.load();
        final result = await fake.run(tokenIds: [10, 11, 12]);

        final pooled = meanPoolAndNormalize(result);

        expect(pooled.length, 2);
        expect(_l2Norm(pooled), closeTo(1.0, 1e-9));
        expect(pooled[0], closeTo(1 / math.sqrt(2), 1e-9));
        expect(pooled[1], closeTo(1 / math.sqrt(2), 1e-9));
        expect(fake.loaded, isTrue);
      },
    );

    test(
      'attentionMask excludes masked-out (padding) tokens from the mean',
      () async {
        // seq=3, dim=2; token2 is padding (mask=0) with an extreme value that
        // must NOT influence the pooled result.
        final fake = _FakeForwardPass(
          const ForwardResult(values: [1, 0, 0, 1, 999, 999], shape: [1, 3, 2]),
        );
        final result = await fake.run(
          tokenIds: [10, 11, 0],
          attentionMask: [1, 1, 0],
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
      () async {
        // A rank-2 result is the final embedding (e.g. LiteRT). Routing it
        // through meanPoolAndNormalize would re-apply L2 (the D5 double-
        // normalize regression), so it must throw, forcing callers onto the
        // EmbeddingOutputContract.pooledFinal verbatim-copy path.
        final fake = _FakeForwardPass(
          const ForwardResult(values: [3, 4], shape: [1, 2]),
        );
        final result = await fake.run(tokenIds: [10, 11, 12]);

        expect(() => meanPoolAndNormalize(result), throwsArgumentError);
      },
    );

    test('rejects an unsupported rank', () async {
      final fake = _FakeForwardPass(
        const ForwardResult(values: [1, 2, 3], shape: [3]),
      );
      final result = await fake.run(tokenIds: [1]);

      expect(() => meanPoolAndNormalize(result), throwsArgumentError);
    });
  });
}
