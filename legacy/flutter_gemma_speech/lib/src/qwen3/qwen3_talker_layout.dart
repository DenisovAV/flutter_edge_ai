// Frozen layout constants for the Qwen3-TTS talker graph
// (`talker_int4.tflite` / `talker_fp32.tflite`), pinned by a spike ("C1",
// 2026-08-03) that introspected the REAL graph out-of-band (independent of
// this package's Dart FFI bindings) before any Dart code existed to load
// it. This file's job is narrow: (1) name the frozen numbers so the rest of
// the Qwen3 port (`Qwen3TtsCore.runPrefill`/`runDecode`) references
// `TalkerLayout.xxx` instead of magic numbers, and (2) a load-time
// `TalkerLayout.assertLayout` that re-verifies as much of the C1 spike's
// findings as the EXISTING bound LiteRT C API surface allows, so a future
// model revision that reorders the graph fails loud at load time instead
// of silently corrupting the decode loop weeks later.
//
// Talker signatures, in index order (there is no signature-NAME binding —
// signatures are told apart purely by the `embeddings` input's time-dim: 1
// for decode, 32 for prefill_32, 128 for prefill_128):
//   [0] prefill_32   — bulk-encodes a 32-token prompt chunk
//   [1] prefill_128  — bulk-encodes a 128-token prompt chunk
//   [2] decode       — one autoregressive step
//
// `decode` (59 inputs -> 57 outputs):
//   in[0]      embeddings   f32 [1, 1, 1024]
//   in[1]      input_pos    i32 [1]
//   in[2]      mask         f32 [1, 1, 1, cacheLen]
//   in[3..58]               kv_cache_{k,v}_{0..27}  f32 (56 tensors,
//                           positional)
//   out[0..55]              kv_cache_{k,v}_{0..27}  f32 — SAME order as the
//                           KV inputs above (verified by the spike) —
//                           thread by copying out[i] -> next step's
//                           in[3+i], no name lookup needed.
//   out[56]                 logits  f32 [1, 1, 4096] = [:3072] codebook-0
//                           logits (logitsCodec) concat [3072:] a
//                           1024-wide hidden tail (logitsHidden), consumed
//                           by the MTP graph.
//
// `prefill_32` / `prefill_128` (59 inputs -> 56 outputs): identical input
// layout except `embeddings`/`input_pos`/`mask`'s time-dim is 32/128
// instead of 1; outputs are the 56 KV tensors only (no `logits` — the
// talker only emits next-token logits at `decode` time).
//
// What [TalkerLayout.assertLayout] CAN check, using the existing, already-
// bound `LiteRtGetCompiledModelInputTensorLayout` (`getInputTensorLayout`)
// — an index-based accessor, safe to call at any index this file already
// knows (from the spike) to be valid: the `embeddings` shape (which IS the
// signature-identifying dimension) and the `input_pos`/`mask` shapes
// (including `mask`'s `cacheLen` last dim), for all 3 signatures; plus
// that the 59th positional input (index 58, the last KV tensor) is
// reachable for every signature — the closest re-verification of
// `numTalkerInputs == 59` this per-index accessor allows.
//
// What it CANNOT check with the CURRENTLY bound API, and therefore treats
// as trusted, frozen constants instead (deliberately: do NOT add a new
// native binding, and do NOT probe an out-of-range index to "discover" a
// count, to work around this): [numLayers], [numKvTensors],
// the exact output COUNTS (57 for decode / 56 for prefill_32/prefill_128),
// the individual per-tensor shape of each of the 56 KV tensors, and the KV
// input-order == KV output-order identity. `LiteRtGetCompiledModelOutput
// TensorLayouts` (`getOutputTensorLayouts`) is a BULK accessor (fills
// `num_layouts` entries starting at output 0 — there is no per-index
// accessor that can target e.g. output 56 alone without already knowing
// the count), and there is no dedicated get-input-count / get-output-count
// / get-signature-count binding at all. If a future model revision changes
// any of these, the run path fails loud — a tensor-buffer
// create/run call against a mismatched shape returns a non-OK LiteRT
// status, which the `.check()` extension turns into a thrown
// [StateError] — rather than silently misbehaving.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

/// Frozen graph layout for the Qwen3-TTS talker (see file header). Every
/// field is `static const` — nothing here is discovered at runtime;
/// [assertLayout] re-verifies what it can against a loaded talker graph and
/// throws [StateError] on any mismatch.
class TalkerLayout {
  TalkerLayout._(); // Not instantiable — a namespace for static members.

  /// Signature index for the 32-token bulk-prefill chunk.
  static const int prefill32Sig = 0;

  /// Signature index for the 128-token bulk-prefill chunk.
  static const int prefill128Sig = 1;

  /// Signature index for one autoregressive decode step.
  static const int decodeSig = 2;

  /// KV cache capacity — the last dim of every `mask` input, across all 3
  /// signatures. Re-verified by [assertLayout] for every signature.
  static const int cacheLen = 1024;

  /// Transformer depth. NOT independently re-verified by [assertLayout]
  /// (see file header) — a frozen constant from the C1 spike.
  static const int numLayers = 28;

  /// `numLayers * 2` (one k + one v tensor per layer) — the number of KV
  /// tensors threaded positionally between decode steps. NOT independently
  /// re-verified by [assertLayout] — a frozen constant from the C1 spike.
  static const int numKvTensors = 56;

  /// Talker hidden size — width of `embeddings`/the logits hidden tail (and
  /// each KV tensor's last dim, per the spike; the KV tensor shape itself
  /// is not independently re-verified). Re-verified by [assertLayout] via
  /// the `embeddings` input's shape.
  static const int embeddingDim = 1024;

  /// Width of the `decode` signature's `logits` output's leading slice —
  /// codebook-0 logits. NOT independently re-verified (see file header:
  /// output shapes are unreachable via a per-index accessor).
  static const int logitsCodec = 3072;

  /// Width of `logits`' trailing slice — the hidden-state tail consumed by
  /// the MTP graph. NOT independently re-verified.
  static const int logitsHidden = 1024;

  /// `logitsCodec + logitsHidden` — the `decode` signature's `logits`
  /// output's full last dim. NOT independently re-verified.
  static const int logitsWidth = logitsCodec + logitsHidden;

  /// Every talker signature's input count: `embeddings, input_pos, mask`
  /// (3) + [numKvTensors]. [assertLayout] confirms input index
  /// `numTalkerInputs - 1` (the last KV tensor) is reachable for every
  /// signature — the closest re-verification the bound API allows — but
  /// does not rule out MORE inputs existing beyond it.
  static const int numTalkerInputs = 3 + numKvTensors;

  /// `decode`'s output count: [numKvTensors] + 1 (`logits`). NOT
  /// independently re-verified (see file header) — a frozen constant.
  static const int numDecodeOutputs = numKvTensors + 1;

  /// `prefill_32`/`prefill_128`'s output count: [numKvTensors] only (no
  /// `logits`). NOT independently re-verified — a frozen constant.
  static const int numPrefillOutputs = numKvTensors;

  /// Validates [talker] against the frozen layout above, as far as the
  /// bound LiteRT C API allows (see file header for exactly what is and
  /// isn't checked). Throws [StateError] naming the mismatch on any
  /// deviation. Call once, right after compiling the talker graph, so a
  /// layout drift fails loud at load time instead of corrupting the decode
  /// loop.
  static void assertLayout(
    LiteRtBindings bindings,
    LiteRtCompiledModel talker,
  ) {
    // `embeddings` (input 0) is the signature-identifying tensor — its
    // time-dim (dim 1) is 32 for prefill_32, 128 for prefill_128, 1 for
    // decode. A successful call into all 3 signature indices below is also
    // the closest re-verification of "3 signatures exist" the bound API
    // allows (there is no signature-count binding).
    _assertInputShape(
      bindings,
      talker,
      prefill32Sig,
      0,
      'prefill_32.embeddings',
      [1, 32, embeddingDim],
    );
    _assertInputShape(
      bindings,
      talker,
      prefill128Sig,
      0,
      'prefill_128.embeddings',
      [1, 128, embeddingDim],
    );
    _assertInputShape(bindings, talker, decodeSig, 0, 'decode.embeddings', [
      1,
      1,
      embeddingDim,
    ]);

    // `input_pos` (input 1): rank-1, length == the signature's time-dim.
    _assertInputShape(
      bindings,
      talker,
      prefill32Sig,
      1,
      'prefill_32.input_pos',
      [32],
    );
    _assertInputShape(
      bindings,
      talker,
      prefill128Sig,
      1,
      'prefill_128.input_pos',
      [128],
    );
    _assertInputShape(bindings, talker, decodeSig, 1, 'decode.input_pos', [1]);

    // `mask` (input 2): [1, 1, T, cacheLen] — cacheLen (the KV cache's
    // fixed capacity) is the load-bearing dim here; checked for every
    // signature, not just its last dim (the minimum needed), since the
    // full shape is just as cheap to check via the same call.
    _assertInputShape(bindings, talker, prefill32Sig, 2, 'prefill_32.mask', [
      1,
      1,
      32,
      cacheLen,
    ]);
    _assertInputShape(bindings, talker, prefill128Sig, 2, 'prefill_128.mask', [
      1,
      1,
      128,
      cacheLen,
    ]);
    _assertInputShape(bindings, talker, decodeSig, 2, 'decode.mask', [
      1,
      1,
      1,
      cacheLen,
    ]);

    // Input index `numTalkerInputs - 1` (== 58, the 59th positional input,
    // 0-indexed) must be reachable — the closest re-verification of
    // `numTalkerInputs == 59` the per-index `getInputTensorLayout` accessor
    // allows WITHOUT probing an out-of-range index (deliberately not done
    // here — see file header). Only reachability is checked, not a shape:
    // the individual KV tensor's shape is a trusted constant, not
    // documented by the spike.
    final lastKvInput = numTalkerInputs - 1;
    final probe = LiteRtLayoutView.calloc();
    try {
      bindings
          .getInputTensorLayout(
            talker,
            prefill32Sig,
            lastKvInput,
            probe.pointer,
          )
          .check(
            'TalkerLayout.assertLayout: prefill_32 input[$lastKvInput] '
            '(expected the last of $numKvTensors KV tensors) unreachable — '
            'numTalkerInputs frozen constant ($numTalkerInputs) may be '
            'stale',
          );
      bindings
          .getInputTensorLayout(talker, decodeSig, lastKvInput, probe.pointer)
          .check(
            'TalkerLayout.assertLayout: decode input[$lastKvInput] '
            '(expected the last of $numKvTensors KV tensors) unreachable — '
            'numTalkerInputs frozen constant ($numTalkerInputs) may be '
            'stale',
          );
    } finally {
      probe.free();
    }
  }

  static void _assertInputShape(
    LiteRtBindings bindings,
    LiteRtCompiledModel talker,
    int signatureIndex,
    int inputIndex,
    String label,
    List<int> expectedShape,
  ) {
    final layout = LiteRtLayoutView.calloc();
    try {
      bindings
          .getInputTensorLayout(
            talker,
            signatureIndex,
            inputIndex,
            layout.pointer,
          )
          .check(
            'TalkerLayout.assertLayout: '
            'LiteRtGetCompiledModelInputTensorLayout(sig=$signatureIndex, '
            'in=$inputIndex, $label)',
          );
      if (layout.rank != expectedShape.length) {
        throw StateError(
          'TalkerLayout mismatch: $label (sig=$signatureIndex, '
          'in=$inputIndex) has rank=${layout.rank}, expected '
          'rank=${expectedShape.length} (shape=$expectedShape) — the '
          'talker graph layout has drifted from the C1-spike-frozen '
          'constants; update TalkerLayout, do not work around this.',
        );
      }
      for (var i = 0; i < expectedShape.length; i++) {
        final actual = layout.dimension(i);
        if (actual != expectedShape[i]) {
          throw StateError(
            'TalkerLayout mismatch: $label (sig=$signatureIndex, '
            'in=$inputIndex) dim[$i]=$actual, expected ${expectedShape[i]} '
            '(full expected shape=$expectedShape) — the talker graph '
            'layout has drifted from the C1-spike-frozen constants; '
            'update TalkerLayout, do not work around this.',
          );
        }
      }
    } finally {
      layout.free();
    }
  }
}
