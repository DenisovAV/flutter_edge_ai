import 'dart:async';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart';

import 'web_runtime.dart';
import 'litert_web_embeddings.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;

class WebEmbeddingModel extends EmbeddingModel with CloseNotifier {
  WebEmbeddingModel({
    required this.onClose,
    this._modelPath,
    this._tokenizerPath,
  });

  /// Where the page's LiteRT.js runtime was actually loaded from, if at all.
  /// Static because the runtime is one per page, not one per model.
  static String? _loadedWasmPath;

  /// Every load and every dispose of the page's LiteRT.js embedding state, in
  /// the order they were CALLED, across all instances.
  ///
  /// That state is one per page (`tfliteModel`, `tokenizer` and
  /// `isInitialized` in litert_embeddings.js); `_isInitialized` is one per
  /// instance. Without a page-wide order, a model closed during its first load
  /// and a replacement built straight after raced: the old close waited for its
  /// load, then disposed the state the NEW model had just loaded, and the new
  /// model — still `_isInitialized` — never loaded again. `EmbedderCache`
  /// builds that replacement as soon as the old model reports `isClosed`, and
  /// cannot know the two share a page; only the owner of the state can.
  static Future<void> _pageLane = Future<void>.value();

  /// Same shape as `EmbedderCache.serialize`: the lane advances on a gate of
  /// its own, so [op]'s failure still reaches whoever awaits it.
  static Future<void> _onPage(Future<void> Function() op) {
    final previous = _pageLane;
    final gate = Completer<void>();
    _pageLane = gate.future;
    return previous.then((_) => op()).whenComplete(gate.complete);
  }

  final VoidCallback onClose;
  final String? _modelPath;
  final String? _tokenizerPath;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;
  bool _isInitialized = false;

  /// The one in-flight initialisation, shared by every caller.
  ///
  /// A bare `if (_isInitialized) return;` followed by awaits let two concurrent
  /// FIRST `generateEmbedding` calls both pass the guard — and `loadLiteRt`
  /// throws synchronously when a load is already in flight, so one of the two
  /// failed outright with "LiteRT is already loading / loaded". A `Future.wait`
  /// over two `rag.addDocument` calls is enough to reach it, which is usually
  /// the first embedding an app ever makes.
  Future<void>? _initFuture;

  // Public getters for parameter comparison
  String? get modelPath => _modelPath;
  String? get tokenizerPath => _tokenizerPath;

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'EmbeddingModel is closed. Create a new instance to use it again',
      );
    }
  }

  /// Initialize the LiteRT model if not already initialized.
  ///
  /// Cleared on failure rather than a plain `??=`, so a failed init does not
  /// poison every later call — the previous code retried, and that is worth
  /// keeping.
  Future<void> _ensureInitialized() {
    if (_isInitialized) return Future<void>.value();
    return _initFuture ??= _onPage(_doInitialize).onError<Object>((e, st) {
      _initFuture = null;
      Error.throwWithStackTrace(e, st);
    });
  }

  Future<void> _doInitialize() async {
    // Closed while queued behind another model's load or dispose: loading now
    // would only be disposed by the close already queued behind this.
    if (_isClosed) return;
    if (_modelPath == null || _tokenizerPath == null) {
      throw StateError(
        'Model and tokenizer paths must be provided. Use createEmbeddingModel with modelPath and tokenizerPath parameters.',
      );
    }

    try {
      // Configurable since 2.2.0; the old hardcoded '/wasm/' was served by
      // nothing, so this call always failed. See [LiteRtWebRuntime].
      final wasmPath = LiteRtWebRuntime.wasmPath;
      // The runtime is a page-level singleton behind a flag in
      // litert_embeddings.js: once it has loaded, a different prefix is
      // discarded there without a word. Say so here instead.
      if (_loadedWasmPath != null && _loadedWasmPath != wasmPath) {
        gemmaLog(
          'LiteRtWebRuntime.wasmPath changed to $wasmPath after the runtime '
          'was loaded from $_loadedWasmPath — the new value is ignored. Set it '
          'before the first embedding.',
        );
      }
      await LiteRTWebEmbeddings.initialize(
        _modelPath,
        _tokenizerPath,
        wasmPath: wasmPath,
      );
      _loadedWasmPath ??= wasmPath;
      _isInitialized = true;
      if (kDebugMode) {
        gemmaLog('✅ LiteRT embeddings initialized successfully');
      }
    } catch (e) {
      throw Exception('Failed to initialize LiteRT embeddings: $e');
    }
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    _assertNotClosed();
    await _ensureInitialized();
    // Re-checked: a close that landed during the load has queued a dispose, and
    // a JS call made now would run on state that is about to be deleted.
    _assertNotClosed();

    try {
      if (taskType == TaskType.retrievalDocument) {
        return await LiteRTWebEmbeddings.generateDocumentEmbedding(text);
      }
      return await LiteRTWebEmbeddings.generateEmbedding(text);
    } catch (e) {
      if (kDebugMode) {
        gemmaLog('❌ Failed to generate embedding: $e');
      }
      rethrow;
    }
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    _assertNotClosed();
    await _ensureInitialized();
    // Re-checked: a close that landed during the load has queued a dispose, and
    // a JS call made now would run on state that is about to be deleted.
    _assertNotClosed();

    try {
      if (taskType == TaskType.retrievalDocument) {
        final results = <List<double>>[];
        for (final text in texts) {
          results.add(
            await LiteRTWebEmbeddings.generateDocumentEmbedding(text),
          );
        }
        return results;
      }
      final embeddings = await LiteRTWebEmbeddings.generateEmbeddings(texts);
      if (kDebugMode) {
        gemmaLog('✅ Generated ${embeddings.length} embeddings');
      }
      return embeddings;
    } catch (e) {
      if (kDebugMode) {
        gemmaLog('❌ Failed to generate embeddings: $e');
      }
      rethrow;
    }
  }

  /// Null, and stated rather than inherited: on web the runtime picks the
  /// accelerator itself and the answer does not exist until the first
  /// embedding, so a synchronous getter cannot carry it. The JS side reports it
  /// — `window.getLiteRtEmbeddingAccelerator()` and
  /// `getLiteRtEmbeddingFullyAccelerated()`. Saying so here keeps "we cannot
  /// know" distinguishable from "nobody thought about it", which a default
  /// alone cannot.
  @override
  PreferredBackend? get activeBackend => null;

  @override
  Future<int> getDimension() async {
    _assertNotClosed();
    // Don't need to initialize just to get dimension (it's a constant)
    return LiteRTWebEmbeddings.getDimension();
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _isClosed = true;

    // Queued NOW, not after awaiting this model's own load: behind any load
    // already in flight — its own included, so that one is never leaked — and
    // ahead of any load a replacement starts after this call.
    await _onPage(() async {
      if (!_isInitialized) return;
      try {
        await LiteRTWebEmbeddings.dispose();
        if (kDebugMode) {
          gemmaLog('✅ LiteRT embeddings disposed');
        }
      } catch (e) {
        if (kDebugMode) {
          gemmaLog('⚠️  Warning: Failed to dispose LiteRT embeddings: $e');
        }
      }
    });

    onClose();
    fireCloseListeners();
  }
}
