// Mean-pool + L2-normalize a `ForwardResult` into a single embedding vector.
//
// Pure function, no engine/isolate/native dependency — the runtime-agnostic
// half of the embedding pipeline (design doc §2). Exercised entirely with
// fake `ForwardResult`s in `test/pooling_test.dart`.

import 'dart:math' as math;

import 'forward_pass.dart';

/// Mean-pools a **token-level** [ForwardResult] over the sequence axis and
/// L2-normalizes it into a single embedding vector of length `dim`.
///
/// Input MUST be rank-3 `[1, seq, dim]` (per-token hidden states, e.g. an ONNX
/// BERT/MiniLM output). When [attentionMask] is supplied, positions where the
/// mask is `0` are excluded from the mean (the standard BERT-style masked
/// mean-pool over real tokens only, ignoring padding).
///
/// **This function is ONLY for the [EmbeddingOutputContract.tokenLevel] path.**
/// A rank-2 `[1, dim]` result is ALREADY the final embedding (e.g. LiteRT's
/// compiled-model output, which bakes pooling — and possibly normalization —
/// into the graph); it must be copied verbatim via
/// [EmbeddingOutputContract.pooledFinal], never routed here. Passing a rank-2
/// result throws rather than silently re-normalizing it — the D5
/// double-normalize regression this seam exists to prevent.
///
/// Throws [ArgumentError] for a non-rank-3 shape, a batch size other than 1,
/// or an [attentionMask] whose length doesn't match the sequence length.
/// Throws [StateError] if every token is masked out (nothing to average).
List<double> meanPoolAndNormalize(
  ForwardResult result, {
  List<int>? attentionMask,
}) {
  final shape = result.shape;
  if (shape.length != 3) {
    throw ArgumentError(
      'meanPoolAndNormalize handles token-level `[1, seq, dim]` results only; '
      'got $shape. A rank-2 `[1, dim]` result is already the final embedding — '
      'copy it verbatim via EmbeddingOutputContract.pooledFinal, never re-pool '
      'or re-normalize it (the D5 double-normalize trap).',
    );
  }
  return _l2Normalize(_meanPoolOverSeq(result, shape, attentionMask));
}

List<double> _meanPoolOverSeq(
  ForwardResult result,
  List<int> shape,
  List<int>? attentionMask,
) {
  _requireBatchOne(shape);
  final seq = shape[1];
  final dim = shape[2];
  if (result.values.length != seq * dim) {
    throw ArgumentError(
      'ForwardResult.values.length (${result.values.length}) does not '
      'match shape $shape',
    );
  }
  if (attentionMask != null && attentionMask.length != seq) {
    throw ArgumentError(
      'attentionMask length (${attentionMask.length}) must match the '
      'sequence length ($seq)',
    );
  }

  final sums = List<double>.filled(dim, 0.0);
  var countedTokens = 0;
  for (var t = 0; t < seq; t++) {
    if (attentionMask != null && attentionMask[t] == 0) continue;
    final base = t * dim;
    for (var d = 0; d < dim; d++) {
      sums[d] += result.values[base + d];
    }
    countedTokens++;
  }
  if (countedTokens == 0) {
    throw StateError(
      'attentionMask masked out every token — nothing left to pool',
    );
  }
  return [for (final s in sums) s / countedTokens];
}

void _requireBatchOne(List<int> shape) {
  if (shape[0] != 1) {
    throw ArgumentError('Expected a batch size of 1, got shape $shape');
  }
}

List<double> _l2Normalize(List<double> vector) {
  var sumSquares = 0.0;
  for (final v in vector) {
    sumSquares += v * v;
  }
  if (sumSquares == 0.0) return vector;
  final norm = math.sqrt(sumSquares);
  return [for (final v in vector) v / norm];
}
