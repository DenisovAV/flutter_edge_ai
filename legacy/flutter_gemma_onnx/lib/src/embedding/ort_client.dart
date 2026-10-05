// Injectable ONNX Runtime session seam (Phase 2 — plain-ORT embedding
// forward pass, hardened plan Task 2). Mirrors the shape of
// `flutter_gemma_litertlm`'s `LiteRtBindings` / forward-pass split: an
// abstract interface unit tests fake with ZERO dlopen, and a concrete
// `dart:ffi` implementation (`OrtFfiClient`) built only inside the
// background worker isolate — never on the isolate that constructs the
// [ForwardPassDescriptor].
//
// HARD RULE (design D1, Phase 2 plan D-T4): `dart:ffi` only. No
// `flutter_onnxruntime` anywhere in this package.

import 'dart:typed_data';

/// One input tensor's shape + values, already right-shaped for the model
/// (batch=1). [OrtClient.run] takes one of these per declared input.
class OrtInputTensor {
  const OrtInputTensor({required this.values, required this.shape});

  /// Row-major Int64 values.
  final List<int> values;

  /// Tensor shape, e.g. `[1, seqLen]`.
  final List<int> shape;
}

/// What [OrtClient.load] learns about a session's IO once it opens — the
/// output layout (a pre-pooled `sentence_embedding`/`pooler_output` vs
/// per-token `last_hidden_state` vs a first-output fallback) is only knowable
/// after the graph is parsed, which is why
/// `OnnxEmbeddingForwardPass.outputContract` reports it via an override
/// (design D-T2) rather than the descriptor declaring it upfront.
class OrtIoSpec {
  const OrtIoSpec({
    required this.inputNames,
    required this.outputName,
    required this.hasLastHiddenStateOutput,
    this.staticSeqLen,
    this.staticDim,
  });

  /// Declared input names, e.g. `[input_ids, attention_mask, token_type_ids]`.
  /// [OrtFfiClient.run] only feeds tensors for names present here.
  final List<String> inputNames;

  /// The output tensor name [OrtClient.run] reads. Preference order:
  /// `sentence_embedding` > `pooler_output` > `last_hidden_state` > the first
  /// declared output. See [pickOnnxOutputIndex] for why `pooler_output` ranks
  /// above the hidden states, and what that costs a BertModel export.
  final String outputName;

  /// True when [outputName] is `last_hidden_state` (rank-3 per-token hidden
  /// states) rather than a pre-pooled `sentence_embedding` (rank-2) or an
  /// unrecognized first-output fallback (whose rank [OrtFfiClient] discovers
  /// at run time). `OnnxEmbeddingForwardPass.outputContract` uses this to
  /// decide `tokenLevel` vs `pooledFinal` without ever branching on the
  /// numeric shape of a specific [ForwardResult] (design D-T2's rule).
  final bool hasLastHiddenStateOutput;

  /// The input's fixed sequence-length dimension, if the graph declares one
  /// (not `-1`/dynamic). `null` for a dynamic-shape graph — the pass echoes
  /// the caller's ids/mask through unpadded in that case.
  final int? staticSeqLen;

  /// The output's fixed hidden-size dimension, if statically known from the
  /// graph. `null` triggers a one-token probe run to discover it (the
  /// cross-platform-reliable fallback — ORT's static shape info is not
  /// always populated for exported ONNX graphs).
  final int? staticDim;
}

/// One forward-pass output: a flat Float32 buffer plus its tensor shape.
class OrtRunResult {
  const OrtRunResult({required this.values, required this.shape});

  final Float32List values;
  final List<int> shape;
}

/// Picks which declared output `OrtFfiClient.load` should read, given the
/// session's [outputNames] in declaration order. Preference order:
/// `sentence_embedding` (pre-pooled) > `pooler_output` (pre-pooled) >
/// `last_hidden_state` (per-token) > the first declared output (unrecognized
/// layout, assumed already pooled).
///
/// `pooler_output` is the SigLIP2 / BERT-style projected pooled output — a
/// rank-2 `[1, dim]` sentence embedding, NOT per-token hidden states — so it
/// ranks with `sentence_embedding` (both `pooledFinal`, copied verbatim),
/// ABOVE `last_hidden_state`. Without this, a graph exposing BOTH
/// `pooler_output` and `last_hidden_state` (SigLIP does) would fall through to
/// `last_hidden_state` and get wrongly mean-pooled. Optimum's
/// `feature-extraction` exports (sentence-transformers / Xenova MiniLM,
/// EmbeddingGemma) declare no `pooler_output`, so they are unaffected — but a
/// graph exported straight from `BertModel` does declare one (the tanh NSP
/// pooler, not a sentence embedding and not L2-normalized) and would now be
/// read instead of the hidden states. Which output to read belongs to the model
/// profile; this name-based order is a stand-in until that exists.
///
/// A pure function — no FFI, no session — so it's unit-testable directly
/// (design D-T4's "zero dlopen" bar) without a fake [OrtClient] at all;
/// `OrtFfiClient.load` is the only production caller.
int pickOnnxOutputIndex(List<String> outputNames) {
  final sentenceIdx = outputNames.indexOf('sentence_embedding');
  if (sentenceIdx != -1) return sentenceIdx;
  final poolerIdx = outputNames.indexOf('pooler_output');
  if (poolerIdx != -1) return poolerIdx;
  final hiddenIdx = outputNames.indexOf('last_hidden_state');
  if (hiddenIdx != -1) return hiddenIdx;
  return 0;
}

/// Injectable wrapper around a single ONNX Runtime session. The separation
/// lets `OnnxEmbeddingForwardPass` unit tests substitute a fake — zero
/// `dlopen`, zero native session — while `OrtFfiClient` is the real
/// `dart:ffi` implementation used in production (built inside the embedding
/// worker isolate by `createOnnxEmbeddingForwardPass`'s `load()`).
abstract class OrtClient {
  /// Opens the session at [modelPath] and reports its IO layout.
  Future<OrtIoSpec> load(String modelPath);

  /// Runs one forward pass. [ids] is required; [mask]/[typeIds] are passed
  /// as `attention_mask`/`token_type_ids` tensors ONLY when
  /// [OrtIoSpec.inputNames] (from [load]) declares them — mirrors the ONNX
  /// spike's "only create the tensor when the model declares that input"
  /// rule, since not every graph (Gemma SentencePiece ONNX) has them.
  Future<OrtRunResult> run({
    required List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  });

  /// Releases the session and any associated resources. Must be safe to
  /// call multiple times (idempotent).
  Future<void> close();
}
