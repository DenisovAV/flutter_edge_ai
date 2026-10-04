// Web arm of the ONNX embedding model (ONNX web PR, `feat/onnx-web`, Task
// 2.3). A direct `EmbeddingModel` — NOT routed through
// `CommonEmbeddingModel`/`EmbeddingWorker` (those are `Isolate.spawn`-based,
// which has no web equivalent; `dart:isolate`'s `Isolate.spawn` is
// unsupported on web). Mirrors the LiteRT web embedding arm's precedent
// (`flutter_edge_ai_litertlm`'s `WebEmbeddingModel`): everything runs on the
// main thread. `ort.env.wasm.proxy` (pushing ORT itself into a Web Worker)
// is a possible follow-on if main-thread WASM execution proves too janky for
// the UI thread — not wired in v1.
//
// The public constructor param names (`modelPath`/`tokenizerPath`) read
// better at call sites than the private field names they initialize
// (`_modelPath`/`_tokenizerPath`), so initializing formals don't apply here —
// same convention as `WordPieceEmbeddingTokenizer._`'s constructor.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart' show edgeAiLog;
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show EmbeddingModel, TaskType;
import 'package:flutter_edge_ai/core/embedding/forward_pass.dart'
    show EmbeddingOutputContract, ForwardResult;
import 'package:flutter_edge_ai/core/embedding/pooling.dart'
    show meanPoolAndNormalize;
import 'package:flutter_edge_ai/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizer, EmbeddingTokenizerFactory;

import 'onnx_web_embedding_forward_pass.dart';
import 'opfs_web_resolver.dart';
import 'ort_web_client.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;

/// ONNX Runtime Web embedding model — `onnxruntime-web` over a WordPiece
/// (MiniLM-family) `.onnx`/`.ort` export. The tokenizer arrives as a
/// registered factory (see `EmbeddingTokenizerProvider`)
/// for the v1 WordPiece-only scope (SentencePiece/EmbeddingGemma-ONNX is a
/// known web gap, not silently mishandled).
class OnnxWebEmbeddingModel extends EmbeddingModel with CloseNotifier {
  OnnxWebEmbeddingModel({
    required String modelPath,
    required String tokenizerPath,
    required this.tokenizerFactory,
    required this.onClose,
  }) : _modelPath = modelPath,
       _tokenizerPath = tokenizerPath;

  final String _modelPath;
  final String _tokenizerPath;

  /// Resolved from core's tokenizer registry by the backend, not chosen here:
  /// the tokenizer family is a property of the model, and its implementations
  /// live in a package this one does not depend on.
  final EmbeddingTokenizerFactory tokenizerFactory;

  final VoidCallback onClose;

  OnnxWebEmbeddingForwardPass? _pass;
  EmbeddingTokenizer? _tokenizer;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;
  Future<void>? _initFuture;

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'EmbeddingModel is closed. Create a new instance to use it again',
      );
    }
  }

  Future<void> _ensureInitialized() {
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    // `opfs://` paths (WebStorageMode.streaming) aren't readable by fetch()
    // or ort.InferenceSession.create() directly — resolve to a blob: URL
    // first. No-op for the cacheApi/none paths (already blob:/https:).
    final resolvedTokenizerPath = await resolveOnnxWebPath(_tokenizerPath);
    _tokenizer = await tokenizerFactory(resolvedTokenizerPath);

    final resolvedModelPath = await resolveOnnxWebPath(_modelPath);
    final pass = OnnxWebEmbeddingForwardPass(resolvedModelPath, OrtWebClient());
    // Retain the pass BEFORE awaiting load() so close() can release its ORT
    // session even if load() throws after the session is already created
    // (e.g. I/O-name discovery fails post-creation) — otherwise `_pass`
    // stays null and close() silently no-ops, leaking the session.
    _pass = pass;
    try {
      await pass.load();
    } catch (_) {
      _pass = null;
      await pass.close();
      rethrow;
    }
    edgeAiLog('[OnnxWebEmbeddingModel] loaded: dim=${pass.outputDimension}');
  }

  Future<List<double>> _embedOne(String text, TaskType taskType) async {
    _assertNotClosed();
    await _ensureInitialized();
    final tokenizer = _tokenizer!;
    final pass = _pass!;

    final tokenized = tokenizer.encode(taskType.prefix, text);
    final result = await pass.run(
      tokenIds: tokenized.ids,
      attentionMask: tokenized.attentionMask,
      tokenTypeIds: tokenized.tokenTypeIds,
    );
    final contract = pass.outputContract ?? EmbeddingOutputContract.tokenLevel;
    final effectiveMask = result.attentionMask ?? tokenized.attentionMask;
    return _finalize(contract, result, effectiveMask);
  }

  static List<double> _finalize(
    EmbeddingOutputContract contract,
    ForwardResult result,
    List<int>? attentionMask,
  ) {
    switch (contract) {
      case EmbeddingOutputContract.pooledFinal:
        return List<double>.of(result.values);
      case EmbeddingOutputContract.tokenLevel:
        return meanPoolAndNormalize(result, attentionMask: attentionMask);
    }
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) => _embedOne(text, taskType);

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    final results = <List<double>>[];
    for (final text in texts) {
      results.add(await _embedOne(text, taskType));
    }
    return results;
  }

  /// Null, and stated rather than inherited: onnxruntime-web resolves
  /// `['webgpu', 'wasm']` in order and keeps the first that initialises, so the
  /// accelerator is the runtime's choice and is not reported back to Dart.
  @override
  PreferredBackend? get activeBackend => null;

  @override
  Future<int> getDimension() async {
    _assertNotClosed();
    await _ensureInitialized();
    return _pass!.outputDimension;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    // Wait out any in-flight initialization first so a session created
    // mid-init (`_pass` assigned, `load()` still running) isn't missed —
    // `_doInitialize()` releases `_pass` itself on failure, so swallowing
    // the error here just lets that cleanup finish before we proceed.
    final initFuture = _initFuture;
    if (initFuture != null) {
      try {
        await initFuture;
      } catch (_) {
        // Already cleaned up inside `_doInitialize()`'s own catch.
      }
    }
    await _pass?.close();
    onClose();
    fireCloseListeners();
  }
}
