import 'dart:async';
import 'dart:collection';

import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show EmbeddingInput, EmbeddingModality;

import 'embedding.dart';
import 'filter.dart';
import 'vector_store.dart';

/// Package-internal construction seam used by `FlutterEdgeAiRag.open` and
/// `openVectors`.
///
/// Not exported from the package barrel; applications receive indexes only
/// through the factory so configuration, binding and ownership cannot be
/// bypassed.
RagIndex createRagIndex({
  required VectorStoreRepository store,
  required RagEmbedder? embedder,
  required VectorStoreBinding binding,
}) => RagIndex._(store, embedder, binding);

/// An independently-owned RAG index over one bound vector-store location.
///
/// The index owns its vector store and closes it on [dispose]. Its
/// [RagEmbedder] is always borrowed: dispose the index before the embedder.
/// The location is bound to one [EmbeddingProfile] and one document modality
/// ([documents]) for its lifetime; use a separate index and location for
/// every embedding space and every modality.
final class RagIndex {
  RagIndex._(this._store, this._embedder, this._binding);

  final VectorStoreRepository _store;
  final RagEmbedder? _embedder;
  final VectorStoreBinding _binding;
  final _OperationGate _gate = _OperationGate();

  bool _disposeRequested = false;
  Future<void>? _disposeFuture;
  int _acceptedOperations = 0;
  Completer<void>? _operationsDrained;

  /// The embedding space this index is bound to; resolved at open.
  EmbeddingProfile get embeddingProfile => _binding.profile;

  /// The one modality of this index's documents.
  EmbeddingModality get documents => _binding.documents;

  bool get isDisposed => _disposeRequested;

  /// Embeds [document] with the embedder's document role and stores it.
  ///
  /// Text index: [document] is text only, and [content] defaults to its
  /// text. Image or audio index: [document] carries that medium (optionally
  /// with text), and [content] is required — a reference to the medium (a
  /// URI, file path or asset id), never its bytes; search results return it.
  /// Fails with [ArgumentError] otherwise.
  ///
  /// Like every method of this class that returns a future, it reports every
  /// error — argument errors included — as a failed future, never as a
  /// synchronous throw.
  Future<void> add({
    required String id,
    required EmbeddingInput document,
    String? content,
    String? metadata,
  }) => Future.sync(() {
    _ensureUsable();
    _validateId(id);
    final embedder = _requireEmbedder('add');
    final storedContent = _contentFor(document, content);
    return _accept(
      () => _gate.runShared(() async {
        final embedding = await embedder.embedDocument(document);
        _validateEmbedding(
          embedding,
          expectedDimension: embeddingProfile.dimension,
        );
        await _store.addDocument(
          id: id,
          content: storedContent,
          embedding: embedding,
          metadata: metadata,
        );
      }),
    );
  });

  /// Stores a precomputed vector, which must be in this index's embedding
  /// space and of its dimension.
  Future<void> addVector({
    required String id,
    required List<double> embedding,
    required String content,
    String? metadata,
  }) => Future.sync(() {
    _ensureUsable();
    _validateId(id);
    final embeddingSnapshot = List<double>.unmodifiable(embedding);
    _validateEmbedding(
      embeddingSnapshot,
      expectedDimension: embeddingProfile.dimension,
    );
    return _accept(
      () => _gate.runShared(
        () => _store.addDocument(
          id: id,
          content: content,
          embedding: embeddingSnapshot,
          metadata: metadata,
        ),
      ),
    );
  });

  /// Embeds [query] with the embedder's query role for this index's
  /// [documents] and searches. The query may be any modality the embedder
  /// has: a text query over an image index is text → image search; any other
  /// modality fails with [ArgumentError].
  ///
  /// Every [filter] field must be declared in the spec's `filterSchema`
  /// ([ArgumentError] otherwise).
  Future<List<RetrievalResult>> search({
    required EmbeddingInput query,
    int topK = 5,
    double threshold = 0.0,
    Filter? filter,
  }) => Future.sync(() {
    _ensureUsable();
    _validateSearch(topK: topK, threshold: threshold);
    _validateFilter(filter);
    final embedder = _requireEmbedder('search');
    final unsupported = query.modalities.difference(embedder.modalities);
    if (unsupported.isNotEmpty) {
      throw ArgumentError.value(
        query,
        'query',
        'carries ${_names(unsupported)}, which this index\'s embedder does '
            'not embed (it embeds ${_names(embedder.modalities)})',
      );
    }
    return _accept(
      () => _gate.runShared(() async {
        final embedding = await embedder.embedQuery(
          query,
          documentModality: documents,
        );
        _validateEmbedding(
          embedding,
          expectedDimension: embeddingProfile.dimension,
        );
        return _store.searchSimilar(
          queryEmbedding: embedding,
          topK: topK,
          threshold: threshold,
          filter: filter,
        );
      }),
    );
  });

  /// Searches with a precomputed query vector. Every [filter] field must be
  /// declared in the spec's `filterSchema` ([ArgumentError] otherwise).
  Future<List<RetrievalResult>> searchVector({
    required List<double> embedding,
    int topK = 5,
    double threshold = 0.0,
    Filter? filter,
  }) => Future.sync(() {
    _ensureUsable();
    _validateSearch(topK: topK, threshold: threshold);
    _validateFilter(filter);
    final embeddingSnapshot = List<double>.unmodifiable(embedding);
    _validateEmbedding(
      embeddingSnapshot,
      expectedDimension: embeddingProfile.dimension,
    );
    return _accept(
      () => _gate.runShared(
        () => _store.searchSimilar(
          queryEmbedding: embeddingSnapshot,
          topK: topK,
          threshold: threshold,
          filter: filter,
        ),
      ),
    );
  });

  Future<void> remove({required String id}) => Future.sync(() {
    _ensureUsable();
    _validateId(id);
    return _accept(() => _gate.runShared(() => _store.removeDocument(id: id)));
  });

  Future<VectorStoreStats> stats() =>
      _accept(() => _gate.runShared(_store.getStats));

  Future<void> flush() => _accept(() => _gate.runExclusive(_store.flush));

  /// Clears documents but deliberately preserves the binding.
  Future<void> clear() => _accept(() => _gate.runExclusive(_store.clear));

  /// Rejects new work immediately, waits for accepted work, then closes once.
  /// Repeated calls return the same completion future.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposeRequested = true;
    final future = _disposeAfterAcceptedOperations();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeAfterAcceptedOperations() async {
    if (_acceptedOperations != 0) {
      _operationsDrained ??= Completer<void>();
      await _operationsDrained!.future;
    }
    await _gate.runExclusive(_store.close);
  }

  RagEmbedder _requireEmbedder(String operation) {
    final embedder = _embedder;
    if (embedder == null) {
      throw StateError(
        'This RagIndex was opened with openVectors() and has no embedder, so '
        '$operation() cannot embed. Use addVector() / searchVector(), or open '
        'the location with FlutterEdgeAiRag.open(embedder: ...).',
      );
    }
    return embedder;
  }

  String _contentFor(EmbeddingInput document, String? content) {
    final modalities = document.modalities;
    switch (documents) {
      case EmbeddingModality.text:
        if (modalities.length != 1 ||
            !modalities.contains(EmbeddingModality.text)) {
          throw ArgumentError.value(
            document,
            'document',
            'this index holds text documents; the document carries '
                '${_names(modalities)}',
          );
        }
        return content ?? document.text!;
      case EmbeddingModality.image || EmbeddingModality.audio:
        final allowed = {documents, EmbeddingModality.text};
        if (!modalities.contains(documents) ||
            !allowed.containsAll(modalities)) {
          throw ArgumentError.value(
            document,
            'document',
            'this index holds ${documents.name} documents; the document '
                'carries ${_names(modalities)}',
          );
        }
        if (content == null || content.trim().isEmpty) {
          throw ArgumentError.value(
            content,
            'content',
            'is required for ${documents.name} documents: a reference to the '
                'medium (a URI, file path or asset id), never its bytes',
          );
        }
        return content;
    }
  }

  void _validateFilter(Filter? filter) {
    if (filter == null) return;
    final schema = _store.filterSchema;
    final conditions = [...?filter.must, ...?filter.should, ...?filter.mustNot];
    for (final condition in conditions) {
      if (schema.fieldFor(condition.key) != null) continue;
      final declared = [for (final field in schema.fields) field.name];
      throw ArgumentError.value(
        condition.key,
        'filter',
        'filters on a field that is not declared in this index\'s '
            'VectorStoreSpec.filterSchema (declared: '
            '${declared.isEmpty ? 'none' : declared.join(', ')}), so it could '
            'never match',
      );
    }
  }

  /// Registers [operation] synchronously, so [dispose] waits for it; a
  /// disposing index fails it as a future, like every other error here.
  Future<T> _accept<T>(Future<T> Function() operation) {
    if (_disposeRequested) return Future.error(_disposedError());
    _acceptedOperations++;
    return Future<T>.sync(operation).whenComplete(() {
      _acceptedOperations--;
      if (_acceptedOperations == 0) {
        _operationsDrained?.complete();
        _operationsDrained = null;
      }
    });
  }

  void _ensureUsable() {
    if (_disposeRequested) throw _disposedError();
  }

  static StateError _disposedError() =>
      StateError('This RagIndex is disposing or already disposed.');

  static String _names(Set<EmbeddingModality> modalities) =>
      '{${[for (final modality in modalities) modality.name].join(', ')}}';

  static void _validateId(String id) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
  }

  static void _validateSearch({required int topK, required double threshold}) {
    if (topK <= 0) {
      throw ArgumentError.value(topK, 'topK', 'must be greater than 0');
    }
    if (!threshold.isFinite) {
      throw ArgumentError.value(threshold, 'threshold', 'must be finite');
    }
  }

  static void _validateEmbedding(
    List<double> embedding, {
    required int expectedDimension,
  }) {
    if (embedding.isEmpty) {
      throw ArgumentError.value(embedding, 'embedding', 'must not be empty');
    }
    for (final value in embedding) {
      if (!value.isFinite) {
        throw ArgumentError.value(
          embedding,
          'embedding',
          'must contain only finite values',
        );
      }
    }
    if (embedding.length != expectedDimension) {
      throw ArgumentError.value(
        embedding.length,
        'embedding.length',
        'must match the bound profile dimension $expectedDimension',
      );
    }
  }
}

class _OperationGate {
  final Queue<_GateWaiter> _waiters = Queue<_GateWaiter>();
  int _activeShared = 0;
  bool _exclusiveActive = false;

  Future<T> runShared<T>(Future<T> Function() operation) async {
    await _acquire(exclusive: false);
    try {
      return await operation();
    } finally {
      _release(exclusive: false);
    }
  }

  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    await _acquire(exclusive: true);
    try {
      return await operation();
    } finally {
      _release(exclusive: true);
    }
  }

  Future<void> _acquire({required bool exclusive}) {
    if (_waiters.isEmpty && !_exclusiveActive) {
      if (exclusive) {
        if (_activeShared == 0) {
          _exclusiveActive = true;
          return Future.value();
        }
      } else {
        _activeShared++;
        return Future.value();
      }
    }

    final completer = Completer<void>();
    _waiters.add(_GateWaiter(exclusive: exclusive, completer: completer));
    return completer.future;
  }

  void _release({required bool exclusive}) {
    if (exclusive) {
      _exclusiveActive = false;
    } else {
      _activeShared--;
    }
    _drain();
  }

  void _drain() {
    if (_exclusiveActive || _activeShared != 0 || _waiters.isEmpty) return;

    if (_waiters.first.exclusive) {
      _exclusiveActive = true;
      _waiters.removeFirst().completer.complete();
      return;
    }

    while (_waiters.isNotEmpty && !_waiters.first.exclusive) {
      _activeShared++;
      _waiters.removeFirst().completer.complete();
    }
  }
}

class _GateWaiter {
  const _GateWaiter({required this.exclusive, required this.completer});

  final bool exclusive;
  final Completer<void> completer;
}
