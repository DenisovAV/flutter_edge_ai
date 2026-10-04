library;

import 'dart:typed_data';

/// Model-agnostic carrier for a text-encoder input. Sealed — each pipeline
/// kind has its own variant (avoids nullable-per-model fields).
sealed class TtsFrontendInput {
  const TtsFrontendInput();
}

/// Matcha's text-encoder input: host-gathered symbol embeddings + mask.
class MatchaFrontendInput extends TtsFrontendInput {
  const MatchaFrontendInput(this.symbolEmbeddings, this.textMask, this.realLen);

  /// Row-major [MAX_TEXT * n_channels] symbol embeddings (host-gathered from emb.bin).
  final Float32List symbolEmbeddings;

  /// [MAX_TEXT] text mask (1.0 for t < realLen else 0.0).
  final Float32List textMask;

  /// 2 * (#phoneme symbols) + 1 — the real blank-interspersed length.
  final int realLen;
}
