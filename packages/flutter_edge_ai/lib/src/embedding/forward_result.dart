// What a token-level embedding graph hands back, and the one function that
// turns it into the final vector. Pure Dart, web-safe.
//
// `TokenEmbeddingPass` (token_embedding_pass.dart) runs `finalizeEmbedding`
// over the `ForwardResult` its graph's `runTokens` returns; an engine with a
// pass of its own may call it too.

import 'pooling.dart';

/// How to turn a [ForwardResult] into the final embedding vector.
///
/// The dispatch MUST be on this enum, never on [ForwardResult.shape] — a
/// rank-2 `[1, dim]` result from an engine that already pools+normalizes
/// internally (LiteRT) must NOT be routed through `meanPoolAndNormalize` a
/// second time (that would silently add an L2-normalize the LiteRT path
/// never had — the embedder decoupling plan's Invariant I0).
enum EmbeddingOutputContract {
  /// [ForwardResult] IS the final embedding already — copy `values` verbatim
  /// (`List<double>.of(result.values)`). No pooling, no normalization.
  /// Used by LiteRT: whatever pooling/normalization exists is baked into the
  /// compiled `.tflite` graph and is opaque to Dart.
  pooledFinal,

  /// [ForwardResult] is `[1, seq, dim]` per-token hidden states. Apply
  /// `meanPoolAndNormalize` (mean-pool over `seq`, then L2-normalize) to get
  /// the final embedding. Used by engines (e.g. ONNX) that expose raw
  /// hidden states rather than a pooled output.
  tokenLevel,
}

/// A graph's raw output for one input: a flat, row-major buffer plus its
/// tensor shape.
///
/// [shape] is one of two layouts a graph can hand back — see
/// `pooling.dart`'s `meanPoolAndNormalize` for how each is turned into a
/// single embedding vector:
///  - `[1, dim]` — already pooled by the engine (e.g. a LiteRT compiled
///    model whose graph itself produces one vector per input). Treated as a
///    pass-through.
///  - `[1, seq, dim]` — per-token hidden states. Mean-pooled over the `seq`
///    axis (optionally respecting an attention mask) before normalizing.
class ForwardResult {
  const ForwardResult({
    required this.values,
    required this.shape,
    this.attentionMask,
  });

  /// Flat, row-major buffer. `values.length == shape.reduce((a, b) => a * b)`.
  final List<double> values;

  /// Tensor shape, e.g. `[1, dim]` or `[1, seq, dim]`.
  final List<int> shape;

  /// The *effective* attention mask over this result's `seq` axis, when the
  /// graph knows one (design D-T3's silent-regression fix). A `runTokens`
  /// that pads a fixed-shape graph MUST pad ids/mask/type-ids together and
  /// echo the padded mask here, so the masked mean-pool excludes exactly the
  /// padding it added — never the tokenizer's mask, which describes the
  /// UNPADDED input. One over a dynamic-shape graph (no padding) may pass the
  /// input mask through unchanged or omit it — [finalizeEmbedding]'s caller
  /// then falls back to the tokenizer's mask.
  final List<int>? attentionMask;
}

/// Turns a raw [ForwardResult] into the final vector per [contract].
///
/// `pooledFinal` is copied verbatim after a `[1, dim]` shape check — see
/// [EmbeddingOutputContract.pooledFinal] for why it must never fall through to
/// `meanPoolAndNormalize`. `tokenLevel` is mean-pooled over [attentionMask]
/// (the EFFECTIVE mask: the one the pass echoed in
/// [ForwardResult.attentionMask], else the tokenizer's) and L2-normalised, so
/// padding a pass added never leaks into the mean.
///
/// Throws [StateError] for a `pooledFinal` result that is not `[1, dim]`, and
/// whatever `meanPoolAndNormalize` throws for a malformed token-level one.
List<double> finalizeEmbedding(
  EmbeddingOutputContract contract,
  ForwardResult result, {
  List<int>? attentionMask,
}) => switch (contract) {
  EmbeddingOutputContract.pooledFinal => _copyPooledFinal(result),
  EmbeddingOutputContract.tokenLevel => meanPoolAndNormalize(
    result,
    attentionMask: attentionMask,
  ),
};

/// Copies a `pooledFinal` [ForwardResult] verbatim — but only after
/// confirming it actually IS an already-pooled `[1, dim]` vector. Symmetric
/// to [meanPoolAndNormalize]'s rank guard in `pooling.dart`: without this,
/// a token-level `[1, seq, dim]` result misrouted here (e.g. an ONNX output
/// name the engine's dispatch didn't recognize, silently falling back to
/// "assume pooled") would be flattened and returned as a corrupt vector —
/// unpooled, unnormalized, and the wrong length — with no error anywhere.
List<double> _copyPooledFinal(ForwardResult result) {
  final shape = result.shape;
  final isPooledShape =
      shape.length == 2 && shape[0] == 1 && result.values.length == shape[1];
  if (!isPooledShape) {
    throw StateError(
      'EmbeddingOutputContract.pooledFinal requires a rank-2 `[1, dim]` '
      'already-pooled result; got shape $shape with ${result.values.length} '
      'values. This usually means a token-level output was misclassified as '
      'pooled (e.g. an unrecognized ONNX output name falling back to '
      '"assume pooled") — copying it verbatim would silently return a '
      'corrupt, unpooled embedding.',
    );
  }
  return List<double>.of(result.values);
}
