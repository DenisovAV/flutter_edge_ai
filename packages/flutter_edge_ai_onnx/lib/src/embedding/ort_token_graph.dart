// What both ONNX embedding passes — native `OnnxEmbeddingPass` (dart:ffi) and
// web `OnnxWebEmbeddingPass` (onnxruntime-web) — do with an open ORT session:
// describe the graph to `TokenEmbeddingPass`, and feed it one tokenized input.
// Pure Dart over the [OrtClient] seam, so both run under `flutter test` with a
// fake client.
//
// The output layout (a pre-pooled `sentence_embedding`/`pooler_output` vs the
// per-token `last_hidden_state`) is only knowable once the session opens and
// its output names are visible (design D-T2); the input length is the graph's
// static sequence dimension, or none for a dynamic-shape graph (R5 D6).

import 'package:flutter_edge_ai/engine.dart'
    show EmbeddingOutputContract, ForwardResult, TokenPassGraph, TokenizedInput;

import 'ort_client.dart';

/// Describes the graph [client] opened from [modelPath], as [spec] reported
/// it: the output dimension (probed with a one-token run when the graph does
/// not declare it), the output contract, and the static sequence length as
/// `maxInputTokens` — null for a dynamic-shape graph, which declares no limit.
Future<TokenPassGraph> describeOrtGraph(
  OrtClient client,
  OrtIoSpec spec,
  String modelPath,
) async {
  final dimension =
      spec.staticDim ?? await _probeDimension(client, spec, modelPath);
  return TokenPassGraph(
    dimension: dimension,
    // Decided once, from the output's NAME — never from the numeric shape of
    // one result (design D-T2's rule).
    outputContract: spec.hasLastHiddenStateOutput
        ? EmbeddingOutputContract.tokenLevel
        : EmbeddingOutputContract.pooledFinal,
    maxInputTokens: spec.staticSeqLen,
  );
}

/// Discovers the output dimension with a one-token run, for a graph whose
/// declared output shape has a dynamic last axis (ORT's static shape info is
/// not always populated for exported graphs).
///
/// Routed through [runOrtTokens] — never a raw `client.run(ids: ...)` — so the
/// probe gets the same mask defaulting and static padding every other run
/// gets. Without it a graph that declares `attention_mask` fails with ORT's
/// "Missing Input: attention_mask", and a static graph gets a length-1 tensor.
Future<int> _probeDimension(
  OrtClient client,
  OrtIoSpec spec,
  String modelPath,
) async {
  final result = await runOrtTokens(
    client,
    spec,
    const TokenizedInput(ids: [0]),
  );
  if (result.shape.isEmpty) {
    throw StateError(
      'ONNX model at "$modelPath" produced a rank-0 output during the '
      'dimension probe — cannot determine its dimension.',
    );
  }
  final dim = result.shape.last;
  if (dim <= 0) {
    throw StateError(
      'ONNX model at "$modelPath" probed embedding dimension is $dim — '
      'cannot be used as the dimension.',
    );
  }
  return dim;
}

/// One forward run of [input] through [client], shaped for the graph [spec]
/// describes.
///
/// A static-shape graph gets ids, mask and type ids padded TOGETHER to its
/// sequence length, and the result echoes the PADDED mask, so a masked
/// mean-pool excludes exactly the padding added here (design D-T3). Padding
/// only: `TokenEmbeddingPass` refused a longer input before this ran. A
/// dynamic-shape graph gets the input as it is.
///
/// Mask and type-id tensors are sent only when the graph declares those
/// inputs; a declared one the tokenizer never produces (Gemma SentencePiece
/// has neither) is defaulted to all-ones / all-zeros over the ids — a real
/// EmbeddingGemma-300M-ONNX session fails with "Missing Input:
/// attention_mask" without it.
Future<ForwardResult> runOrtTokens(
  OrtClient client,
  OrtIoSpec spec,
  TokenizedInput input,
) async {
  final staticSeqLen = spec.staticSeqLen;
  final List<int> ids;
  final List<int>? mask;
  final List<int>? typeIds;
  if (staticSeqLen == null) {
    ids = input.ids;
    mask = input.attentionMask;
    typeIds = input.tokenTypeIds;
  } else {
    if (input.ids.length > staticSeqLen) {
      // Unreachable through TokenEmbeddingPass, which checks first; cutting
      // here would silently embed a prefix of the input, as 2.1 did.
      throw StateError(
        'ONNX graph takes $staticSeqLen tokens; got ${input.ids.length}',
      );
    }
    ids = _pad(input.ids, staticSeqLen);
    mask = _pad(
      input.attentionMask ?? List<int>.filled(input.ids.length, 1),
      staticSeqLen,
    );
    final inputTypeIds = input.tokenTypeIds;
    typeIds = inputTypeIds == null ? null : _pad(inputTypeIds, staticSeqLen);
  }

  final maskToSend = spec.inputNames.contains('attention_mask')
      ? (mask ?? List<int>.filled(ids.length, 1))
      : null;
  final typeIdsToSend = spec.inputNames.contains('token_type_ids')
      ? (typeIds ?? List<int>.filled(ids.length, 0))
      : null;

  final result = await client.run(
    ids: ids,
    mask: maskToSend,
    typeIds: typeIdsToSend,
  );
  return ForwardResult(
    values: [for (final v in result.values) v.toDouble()],
    shape: result.shape,
    attentionMask: result.shape.length == 3 ? mask : null,
  );
}

List<int> _pad(List<int> values, int length) => values.length == length
    ? values
    : [...values, ...List<int>.filled(length - values.length, 0)];

/// Whether [filename] is a model the ONNX embedding backend runs: `.onnx` (a
/// single-file export) or `.ort` (the ORT-optimized format), ASCII
/// case-insensitive.
bool isOnnxEmbeddingFilename(String filename) =>
    _endsWithAsciiInsensitive(filename, '.onnx') ||
    _endsWithAsciiInsensitive(filename, '.ort');

bool _endsWithAsciiInsensitive(String value, String lowerSuffix) {
  final start = value.length - lowerSuffix.length;
  if (start < 0) return false;
  for (var i = 0; i < lowerSuffix.length; i++) {
    var c = value.codeUnitAt(start + i);
    // ASCII 'A'..'Z' → 'a'..'z'; every other code unit compares as is.
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != lowerSuffix.codeUnitAt(i)) return false;
  }
  return true;
}
