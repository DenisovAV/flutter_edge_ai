// Fakes shared by the native and web ONNX embedding pass suites: an
// [OrtClient] that records what it was fed (zero dlopen, zero JS), and a
// tokenizer whose ids are countable by eye.

import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_client.dart';

typedef RunResult =
    OrtRunResult Function(List<int> ids, List<int>? mask, List<int>? typeIds);

/// Records every `load()`/`run()`/`close()` and returns a scripted result.
final class FakeOrtClient implements OrtClient {
  FakeOrtClient({
    required this.ioSpec,
    RunResult? runResult,
    this.loadError,
    this.closeError,
    this.onLoad,
  }) : runResult = runResult ?? pooled([1, 0]);

  /// Called with the path as `load()` starts, before it can fail.
  final void Function(String modelPath)? onLoad;

  final OrtIoSpec ioSpec;
  final RunResult runResult;

  /// When set, `load()` throws it instead of opening the session.
  final Object? loadError;

  /// When set, `close()` throws it after counting the call.
  final Object? closeError;

  final loadedPaths = <String>[];
  int closeCallCount = 0;
  final runs = <({List<int> ids, List<int>? mask, List<int>? typeIds})>[];

  List<int>? get lastIds => runs.lastOrNull?.ids;
  List<int>? get lastMask => runs.lastOrNull?.mask;
  List<int>? get lastTypeIds => runs.lastOrNull?.typeIds;

  @override
  Future<OrtIoSpec> load(String modelPath) async {
    loadedPaths.add(modelPath);
    onLoad?.call(modelPath);
    final error = loadError;
    if (error != null) throw error;
    return ioSpec;
  }

  @override
  Future<OrtRunResult> run({
    required List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  }) async {
    runs.add((ids: ids, mask: mask, typeIds: typeIds));
    return runResult(ids, mask, typeIds);
  }

  @override
  Future<void> close() async {
    closeCallCount++;
    final error = closeError;
    if (error != null) throw error;
  }
}

/// A pooled `[1, dim]` result of [values], whatever the input.
RunResult pooled(List<double> values) =>
    (ids, mask, typeIds) => OrtRunResult(
      values: Float32List.fromList(values),
      shape: [1, values.length],
    );

/// One id per character of prefix + text (no BOS/EOS), so token counts are
/// character counts. [withMask] / [withTypeIds] make it behave like a
/// WordPiece tokenizer (all-ones mask, all-zeros type ids); without them it
/// is Gemma SentencePiece-like and reports neither.
final class CharTokenizer implements EmbeddingTokenizer {
  CharTokenizer({this.withMask = false, this.withTypeIds = false});

  final bool withMask;
  final bool withTypeIds;
  final encoded = <String>[];

  @override
  TokenizedInput encode(String prefix, String text) {
    encoded.add('$prefix$text');
    final ids = [for (final c in '$prefix$text'.codeUnits) c];
    return TokenizedInput(
      ids: ids,
      attentionMask: withMask ? List<int>.filled(ids.length, 1) : null,
      tokenTypeIds: withTypeIds ? List<int>.filled(ids.length, 0) : null,
    );
  }
}
