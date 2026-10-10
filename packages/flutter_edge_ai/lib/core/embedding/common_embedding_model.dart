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

import 'dart:async';

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
  CommonEmbeddingModel._(
    this._worker,
    this.onClose,
    this.activeBackend,
    this._modelPath,
  ) {
    // A worker that dies on its own turns this model closed and tells its
    // listeners, so `EmbedderCache` evicts it and the next caller gets a fresh
    // embedder — instead of this one, whose every call would fail.
    unawaited(_worker.unexpectedExit.then(_onWorkerDied));
  }

  final EmbeddingWorker _worker;
  final VoidCallback onClose;

  /// The model file, named in the warnings this facade prints itself.
  final String _modelPath;

  /// What every [close] after the first one waits for: the end of the same
  /// teardown, without its outcome. Only the first caller is told that a
  /// listener threw; the model is closed either way, so later callers are not
  /// handed that error again and again.
  Future<void>? _closeFuture;

  /// Whether [onClose] and the close listeners have run; they run once,
  /// whether the model was closed or its worker died.
  bool _closeNotified = false;

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
      descriptor.modelPath,
    );
  }

  void _assertNotClosed() {
    if (_isClosed) {
      final deathReason = _worker.deathReason;
      throw StateError(
        deathReason == null
            ? 'CommonEmbeddingModel is closed; create a new instance to use it'
            : 'CommonEmbeddingModel is closed because its worker exited '
                  'unexpectedly: $deathReason',
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

  /// Closes the worker. Every caller — the app, the cache joining a close the
  /// app started — gets the same teardown and returns only once it is done,
  /// which is what lets `EmbedderCache` hold a rebuild until the old native
  /// model is gone.
  @override
  Future<void> close() {
    final teardownDone = _closeFuture;
    if (teardownDone != null) return teardownDone;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // `whenComplete` hands the first caller the teardown's own outcome — a
    // listener's throw included, unhandled if they never look — while
    // `settled` only ever completes normally.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    try {
      await _worker.close();
    } finally {
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
      _notifyClosed();
    }
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    try {
      onClose();
    } finally {
      // Even when `onClose` throws: the cache evicts on a listener, and a
      // closed model it never hears about is handed to every later caller.
      fireCloseListeners();
    }
  }

  void _onWorkerDied(String reason) {
    _isClosed = true;
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context. `print` for the release-visibility
      // reason `EmbedderCache` gives.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai] WARNING: a close listener threw while the embedder '
        'for $_modelPath, whose worker had died ($reason), was being closed: '
        '$e\n$st',
      );
    }
  }
}
