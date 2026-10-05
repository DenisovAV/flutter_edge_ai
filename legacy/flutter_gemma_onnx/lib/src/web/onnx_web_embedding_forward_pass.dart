// Web arm of the ONNX Runtime `EmbeddingForwardPass` (ONNX web PR,
// `feat/onnx-web`, Task 2.3). Deliberately does NOT import
// `ort_web_client.dart` (the `dart:js_interop` client) — this file takes an
// already-built [OrtClient] through its constructor, so it stays pure Dart
// and unit-testable under plain `flutter test` (VM) with a fake [OrtClient],
// exactly like the native `OnnxEmbeddingForwardPass`'s own test suite (see
// `test/embedding/onnx_embedding_forward_pass_test.dart`). `dart:js_interop`
// only exists for web compile targets — a file that imports it can never be
// imported into a VM-run test, so keeping this class ignorant of WHICH
// [OrtClient] implementation it's given is what makes it testable at all.
//
// The core logic here (padding/mask-defaulting/contract-discovery) is a
// deliberate near-duplicate of `../embedding/onnx_embedding_forward_pass.dart`
// rather than a shared base class — see this PR's design notes: sharing
// would require either touching the native file (risking its own test suite)
// or a bigger extraction than this PR's scope. ONE simplification versus the
// native arm: onnxruntime-web's `InferenceSession` does not expose static
// shape metadata the way the native ORT C API does, so this pass always
// treats the graph as dynamic-shape (no padding/truncation) — true for every
// HF-exported MiniLM/BERT ONNX graph this backend targets in v1 (dynamic
// `sequence_length` axis).
import 'package:flutter_gemma/core/embedding/forward_pass.dart'
    show EmbeddingForwardPass, EmbeddingOutputContract, ForwardResult;

import '../embedding/ort_client.dart';

/// ONNX Runtime Web implementation of the [EmbeddingForwardPass] seam. Built
/// directly on the main thread (no isolate worker — see
/// `onnx_web_embedding_model.dart`'s module doc for why: `Isolate.spawn` has
/// no web equivalent, matching the LiteRT web embedding arm's precedent).
class OnnxWebEmbeddingForwardPass implements EmbeddingForwardPass {
  OnnxWebEmbeddingForwardPass(this._modelPath, this._client);

  final String _modelPath;
  final OrtClient _client;

  OrtIoSpec? _spec;
  int? _outputDimension;
  bool _disposed = false;

  @override
  Future<void> load() async {
    final spec = await _client.load(_modelPath);
    _spec = spec;
    _outputDimension = spec.staticDim ?? await _probeDimension();
  }

  /// One-token forward pass to discover the output dimension when the
  /// session doesn't report it statically — same rationale as the native
  /// arm's probe (`onnx_embedding_forward_pass.dart`'s doc).
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
      throw StateError('OnnxWebEmbeddingForwardPass.load() has not completed');
    }
    return dim;
  }

  /// Always `null` on web — see this file's module doc: onnxruntime-web
  /// sessions don't report a static input sequence length, so this pass
  /// never pads and has no fixed length to report.
  @override
  int? get inputSequenceLength => null;

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
      throw StateError('OnnxWebEmbeddingForwardPass is disposed');
    }
    final spec = _spec;
    if (spec == null) {
      throw StateError(
        'OnnxWebEmbeddingForwardPass.run() called before load() completed',
      );
    }

    // Only send mask/typeIds tensors the graph actually declares as inputs —
    // same rule as the native arm (design D-T3), and defaulted to
    // all-ones/all-zeros when the graph declares an input the tokenizer
    // itself never produces.
    final maskToSend = spec.inputNames.contains('attention_mask')
        ? (attentionMask ?? List<int>.filled(tokenIds.length, 1))
        : null;
    final typeIdsToSend = spec.inputNames.contains('token_type_ids')
        ? (tokenTypeIds ?? List<int>.filled(tokenIds.length, 0))
        : null;

    final result = await _client.run(
      ids: tokenIds,
      mask: maskToSend,
      typeIds: typeIdsToSend,
    );
    return ForwardResult(
      values: [for (final v in result.values) v.toDouble()],
      shape: result.shape,
      attentionMask: result.shape.length == 3 ? maskToSend : null,
    );
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await _client.close();
  }
}
