// ONNX Runtime `EmbeddingForwardPass` implementation (Phase 2 — plain-ORT
// embedding forward pass, hardened plan Task 3).
//
// Thin adapter over [OrtClient]: owns padding/truncation for a static-shape
// graph (design D-T3), reports the effective post-padding attentionMask on
// [ForwardResult], and reports the discovered output layout via the
// [EmbeddingOutputContract] override (design D-T2) — the contract is only
// knowable once the session opens and the output names are visible in the
// graph, which is after the descriptor was built.

import 'package:flutter_gemma/core/embedding/forward_pass.dart'
    show EmbeddingForwardPass, EmbeddingOutputContract, ForwardResult;

import 'ort_client.dart';
import 'ort_ffi_client.dart';

/// ONNX Runtime implementation of the [EmbeddingForwardPass] seam. NOT safe
/// to share across isolates — the [OrtClient] it wraps owns FFI handles
/// affine to whichever isolate called [load]; see
/// `createOnnxEmbeddingForwardPass` for how the *ability to build one*
/// crosses the isolate boundary instead of the instance itself.
class OnnxEmbeddingForwardPass implements EmbeddingForwardPass {
  OnnxEmbeddingForwardPass(
    this._modelPath, {
    OrtClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? OrtFfiClient.new;

  final String _modelPath;
  final OrtClient Function() _clientFactory;

  OrtClient? _client;
  OrtIoSpec? _spec;
  int? _outputDimension;
  bool _disposed = false;

  @override
  Future<void> load() async {
    final client = _clientFactory();
    final spec = await client.load(_modelPath);
    _client = client;
    _spec = spec;
    _outputDimension = spec.staticDim ?? await _probeDimension();
  }

  /// Discovers the output dimension via a one-token forward pass when the
  /// graph's declared output shape has a dynamic last axis (the branch's
  /// proven cross-platform-reliable fallback — ORT's static shape info is
  /// not always populated for exported ONNX graphs).
  ///
  /// Routed through this pass's own [run] — never a raw `client.run(ids:
  /// ...)` call — so the probe gets the same mask-defaulting and static-seq
  /// padding every other call gets. Without this, a graph that declares
  /// `attention_mask`/`token_type_ids` (every BERT/MiniLM/EmbeddingGemma
  /// export does) would hard-fail ORT's "Missing Input: attention_mask"
  /// during the probe, and a static-seq graph would receive a seqLen=1
  /// tensor against a fixed-width input — the exact failures [run]'s
  /// defaulting/padding exist to prevent.
  Future<int> _probeDimension() async {
    final result = await run(tokenIds: const [0]);
    if (result.shape.isEmpty) {
      throw StateError(
        'ONNX model at "$_modelPath" produced a rank-0 output during the '
        'dimension probe — cannot determine outputDimension.',
      );
    }
    final dim = result.shape.last;
    if (dim <= 0) {
      throw StateError(
        'ONNX model at "$_modelPath" probed embedding dimension is $dim — '
        'cannot be used as outputDimension.',
      );
    }
    return dim;
  }

  @override
  int get outputDimension {
    final dim = _outputDimension;
    if (dim == null) {
      throw StateError('OnnxEmbeddingForwardPass.load() has not completed');
    }
    return dim;
  }

  @override
  int? get inputSequenceLength => _spec?.staticSeqLen;

  /// Reports `tokenLevel` for a `last_hidden_state` output, `pooledFinal`
  /// otherwise (`sentence_embedding`, or an unrecognized first-output
  /// fallback assumed already pooled) — see [OrtIoSpec.hasLastHiddenStateOutput]'s
  /// doc for why dispatch stays on this flag, set once at `load()`, never on
  /// [ForwardResult.shape] (design D-T2's hard rule).
  @override
  EmbeddingOutputContract? get outputContract {
    final spec = _spec;
    if (spec == null) return null;
    return spec.hasLastHiddenStateOutput
        ? EmbeddingOutputContract.tokenLevel
        : EmbeddingOutputContract.pooledFinal;
  }

  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async {
    if (_disposed) {
      throw StateError('OnnxEmbeddingForwardPass is disposed');
    }
    final client = _client;
    final spec = _spec;
    if (client == null || spec == null) {
      throw StateError(
        'OnnxEmbeddingForwardPass.run() called before load() completed',
      );
    }

    final staticSeqLen = spec.staticSeqLen;
    final List<int> ids;
    final List<int>? mask;
    final List<int>? typeIds;
    final List<int>? effectiveMask;
    if (staticSeqLen == null) {
      // Dynamic-shape graph: pass ids/mask/typeIds straight through, echo
      // the input mask unchanged (design D-T3).
      ids = tokenIds;
      mask = attentionMask;
      typeIds = tokenTypeIds;
      effectiveMask = attentionMask;
    } else {
      // Static-shape graph: pad/truncate ids, mask, and typeIds TOGETHER to
      // staticSeqLen, and echo the PADDED mask — never the caller's
      // unpadded one (the D-T3 silent-regression fix: padding a static
      // graph must never leak into a masked mean-pool downstream).
      ids = _padOrTruncate(tokenIds, staticSeqLen, padValue: 0);
      final baseMask = attentionMask ?? List<int>.filled(tokenIds.length, 1);
      mask = _padOrTruncate(baseMask, staticSeqLen, padValue: 0);
      typeIds = tokenTypeIds == null
          ? null
          : _padOrTruncate(tokenTypeIds, staticSeqLen, padValue: 0);
      effectiveMask = mask;
    }

    // Only send mask/typeIds tensors the graph actually declares as inputs
    // (a WordPiece MiniLM export has both; a Gemma SentencePiece export
    // often has attention_mask but not token_type_ids — verified against a
    // real EmbeddingGemma-300M-ONNX export) — gating here, not inside the
    // client, is what makes this routing fake-testable with zero dlopen
    // (`OrtClient.run`'s fake records exactly what it received).
    //
    // When the graph DECLARES an input the tokenizer never produces (Gemma
    // SentencePiece has no mask/typeIds concept at all — see
    // `embedding_tokenizer.dart`), default it here rather than send nothing:
    // an all-ones mask / all-zeros typeIds over the actual (unpadded) token
    // length is the correct "no padding, every token real" value — verified
    // against a real EmbeddingGemma-300M-ONNX session, which hard-fails
    // ("Missing Input: attention_mask") when the declared input is omitted.
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
      attentionMask: result.shape.length == 3 ? effectiveMask : null,
    );
  }

  static List<int> _padOrTruncate(
    List<int> values,
    int length, {
    required int padValue,
  }) {
    if (values.length == length) return values;
    if (values.length > length) return values.sublist(0, length);
    return [...values, ...List<int>.filled(length - values.length, padValue)];
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await _client?.close();
  }
}

/// Top-level factory tear-off — the seam's hard requirement (see
/// `ForwardPassDescriptor.factory`'s doc: it must be a genuine top-level/
/// static tear-off to survive `Isolate.spawn`). Production path; fakes are
/// injected only in direct-construction unit tests, never across the
/// isolate.
EmbeddingForwardPass createOnnxEmbeddingForwardPass(String modelPath) =>
    OnnxEmbeddingForwardPass(modelPath);
