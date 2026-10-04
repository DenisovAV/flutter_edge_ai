// `EmbeddingModel` facade over a background isolate driving a
// runtime-agnostic [EmbeddingForwardPass] (embedder decoupling plan Task 3).
//
// Rename-move of what used to be `litert/litert_embedding_model.dart`. That
// file was already engine-agnostic in shape (issue #299's isolate facade);
// this version is generalized to take a [ForwardPassDescriptor] instead of
// LiteRT-specific model/tokenizer/backend params, so any engine package
// (flutter_edge_ai_litertlm today, flutter_edge_ai_onnx later) can plug into the
// same facade by building a descriptor + calling [CommonEmbeddingModel.create].
//
// Public method signatures (`generateEmbedding`/`generateEmbeddings`/
// `getDimension`/`close`) are unchanged from `LitertEmbeddingModel`.

import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show EmbeddingModel, TaskType;

import 'embedding_worker.dart';
import 'forward_pass.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;

/// Signature for the `onClose` callback. Same name Flutter uses.
typedef VoidCallback = void Function();

class CommonEmbeddingModel extends EmbeddingModel with CloseNotifier {
  CommonEmbeddingModel._(this._worker, this.onClose, this.activeBackend);

  final EmbeddingWorker _worker;
  final VoidCallback onClose;

  /// Carried from the engine's [ForwardPassDescriptor], never decided here.
  /// This facade is runtime-agnostic by design, so it is not entitled to an
  /// opinion about which backend ran — asserting CPU here would report the
  /// next GPU-capable engine as CPU with nothing to catch it.
  @override
  final PreferredBackend? activeBackend;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  /// Sequence length the forward pass reported at load, if any (see
  /// [EmbeddingForwardPass.inputSequenceLength]).
  int? get inputSequenceLength =>
      _worker.inputSequenceLength < 0 ? null : _worker.inputSequenceLength;

  /// Output embedding dimension.
  int get outputDimension => _worker.outputDimension;

  /// Build an [EmbeddingForwardPass] from [descriptor] on a background
  /// isolate and prepare it for inference.
  ///
  /// [tokenizerPath] points at the matching SentencePiece `.model` or
  /// exported `.json` for [descriptor]'s model.
  ///
  /// Caller owns the returned instance and must call [close] when done.
  static Future<CommonEmbeddingModel> create({
    required ForwardPassDescriptor descriptor,
    required String tokenizerPath,
    VoidCallback? onClose,
  }) async {
    final worker = await EmbeddingWorker.spawn(
      descriptor: descriptor,
      tokenizerPath: tokenizerPath,
    );
    return CommonEmbeddingModel._(
      worker,
      onClose ?? () {},
      descriptor.activeBackend,
    );
  }

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'CommonEmbeddingModel is closed; create a new instance to use it',
      );
    }
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) {
    _assertNotClosed();
    return _worker.embed(text, prefix: taskType.prefix);
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) {
    _assertNotClosed();
    // Each embed() is a separate request the worker serves in order; the UI
    // isolate stays free between them.
    return Future.wait(
      texts.map((text) => _worker.embed(text, prefix: taskType.prefix)),
    );
  }

  @override
  Future<int> getDimension() async {
    _assertNotClosed();
    return outputDimension;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _worker.close();
    } finally {
      onClose();
      // Deliberately AFTER the teardown, not before it. A listener is app code
      // (`addCloseListener` is public) and `CloseNotifier` calls each one bare,
      // so firing them first would let one throw exit here before
      // `_worker.close()` was ever sent — a leaked isolate that `_isClosed`
      // then makes unrecoverable. It happened once, in this branch.
      //
      // The window that ordering left — the cache still matching this model on
      // params while the teardown ran — is closed by [isClosed] instead, which
      // is already true above and which `EmbedderCache` checks on every read.
      // That covers every implementation in one place, not just this one.
      fireCloseListeners();
    }
  }
}
