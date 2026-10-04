import 'dart:async';
import 'dart:collection';

import 'embedding.dart';
import 'filter.dart';
import 'vector_store.dart';

/// Package-internal construction seam used by `FlutterEdgeAiRag.open`.
///
/// Not exported from the package barrel; applications receive indexes only
/// through the factory so configuration and ownership cannot be bypassed.
RagIndex createRagIndex({
  required VectorStoreRepository store,
  required RagEmbedder embedder,
  required EmbeddingProfile? initialProfile,
  required bool allowLegacyProfileAdoption,
}) => RagIndex._(store, embedder, initialProfile, allowLegacyProfileAdoption);

/// An independently-owned RAG index.
///
/// The index owns its vector store and closes it on [dispose]. Its [RagEmbedder]
/// is always borrowed. Each index pins at most one [EmbeddingProfile]; use a
/// separate index and persistent location for every embedding space.
class RagIndex {
  RagIndex._(
    this._store,
    this._embedder,
    this._boundProfile,
    this._allowLegacyProfileAdoption,
  );

  final VectorStoreRepository _store;
  final RagEmbedder _embedder;
  final bool _allowLegacyProfileAdoption;
  final _OperationGate _gate = _OperationGate();

  _TextProfileClaim? _textProfileClaim;
  EmbeddingProfile? _boundProfile;
  bool _disposeRequested = false;
  Future<void>? _disposeFuture;
  int _acceptedOperations = 0;
  Completer<void>? _operationsDrained;

  EmbeddingProfile? get embeddingProfile => _boundProfile;

  bool get isDisposed => _disposeRequested;

  Future<void> addText({
    required String id,
    required String content,
    String? metadata,
  }) {
    _ensureUsable();
    _validateId(id);
    return _runTextOperation((profile) async {
      final embedding = await _embedder.embedDocument(content);
      _validateEmbedding(embedding, expectedDimension: profile.dimension);
      await _store.addDocument(
        id: id,
        content: content,
        embedding: embedding,
        metadata: metadata,
      );
    });
  }

  Future<void> addVector({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) {
    _ensureUsable();
    _validateId(id);
    _validateEmbedding(embedding);
    final profile = _boundProfile;
    if (profile == null && _textProfileClaim == null) {
      _requireBoundProfile();
    }
    if (profile != null) {
      _validateEmbedding(embedding, expectedDimension: profile.dimension);
    }
    return _accept(
      () => _gate.runShared(() async {
        final boundProfile = _requireBoundProfile();
        _validateEmbedding(
          embedding,
          expectedDimension: boundProfile.dimension,
        );
        await _store.addDocument(
          id: id,
          content: content,
          embedding: embedding,
          metadata: metadata,
        );
      }),
    );
  }

  Future<List<RetrievalResult>> searchText({
    required String query,
    int topK = 5,
    double threshold = 0.0,
    Filter? filter,
  }) {
    _ensureUsable();
    _validateSearch(topK: topK, threshold: threshold);
    return _runTextOperation((profile) async {
      final embedding = await _embedder.embedQuery(query);
      _validateEmbedding(embedding, expectedDimension: profile.dimension);
      return _store.searchSimilar(
        queryEmbedding: embedding,
        topK: topK,
        threshold: threshold,
        filter: filter,
      );
    });
  }

  Future<List<RetrievalResult>> searchVector({
    required List<double> embedding,
    int topK = 5,
    double threshold = 0.0,
    Filter? filter,
  }) {
    _ensureUsable();
    _validateSearch(topK: topK, threshold: threshold);
    _validateEmbedding(embedding);
    final profile = _boundProfile;
    if (profile == null && _textProfileClaim == null) {
      _requireBoundProfile();
    }
    if (profile != null) {
      _validateEmbedding(embedding, expectedDimension: profile.dimension);
    }
    return _accept(
      () => _gate.runShared(() {
        final boundProfile = _requireBoundProfile();
        _validateEmbedding(
          embedding,
          expectedDimension: boundProfile.dimension,
        );
        return _store.searchSimilar(
          queryEmbedding: embedding,
          topK: topK,
          threshold: threshold,
          filter: filter,
        );
      }),
    );
  }

  Future<void> remove({required String id}) {
    _ensureUsable();
    _validateId(id);
    return _accept(() => _gate.runShared(() => _store.removeDocument(id: id)));
  }

  Future<VectorStoreStats> stats() =>
      _accept(() => _gate.runShared(_store.getStats));

  Future<void> flush() => _accept(() => _gate.runExclusive(_store.flush));

  /// Clears documents but deliberately preserves [embeddingProfile].
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

  /// Claims the first unresolved text profile synchronously, before any await.
  ///
  /// The claimant owns an exclusive gate slot for its whole operation: profile
  /// resolution/binding, embedding, and storage. Followers capture the same
  /// claim and queue as shared work behind it. This avoids a shared-to-exclusive
  /// gate upgrade while keeping every operation accepted after the first bind
  /// behind that bind.
  Future<T> _runTextOperation<T>(
    Future<T> Function(EmbeddingProfile profile) operation,
  ) {
    final existing = _textProfileClaim;
    if (existing != null) {
      return _accept(
        () => _gate.runShared(() async {
          final profile = await existing.future;
          return operation(profile);
        }),
      );
    }

    final claim = _TextProfileClaim();
    _textProfileClaim = claim;
    return _accept(
      () => _gate.runExclusive(() async {
        final profile = await _resolveFirstTextProfile(claim);
        return operation(profile);
      }),
    );
  }

  Future<EmbeddingProfile> _resolveFirstTextProfile(
    _TextProfileClaim claim,
  ) async {
    try {
      final profile = await _resolveAndBindTextProfile();
      claim.complete(profile);
      return profile;
    } catch (error, stackTrace) {
      if (identical(_textProfileClaim, claim)) {
        _textProfileClaim = null;
      }
      claim.completeError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<EmbeddingProfile> _resolveAndBindTextProfile() async {
    final profile = await _embedder.profile;
    final bound = _boundProfile ?? await _store.readEmbeddingProfile();
    if (bound != null) {
      if (bound != profile) {
        throw StateError(
          'This index is bound to $bound, but its text embedder reports '
          '$profile. Use a separate location for each embedding profile.',
        );
      }
      _boundProfile = bound;
      return bound;
    }

    final stats = await _store.getStats();
    if (stats.documentCount > 0) {
      if (!_allowLegacyProfileAdoption) {
        throw StateError(
          'This store contains legacy vectors without an embedding profile. '
          'Reopen with allowLegacyProfileAdoption: true only after verifying '
          'which embedding model created them.',
        );
      }
      if (stats.vectorDimension != profile.dimension) {
        throw StateError(
          'Cannot adopt ${stats.vectorDimension}D legacy vectors as $profile.',
        );
      }
    }
    await _store.bindEmbeddingProfile(profile);
    final persisted = await _store.readEmbeddingProfile();
    if (persisted != profile) {
      throw StateError(
        'Vector-store provider did not persist the requested $profile.',
      );
    }
    _boundProfile = profile;
    return profile;
  }

  EmbeddingProfile _requireBoundProfile() {
    final profile = _boundProfile;
    if (profile == null) {
      throw StateError(
        'This RagIndex has no bound embedding profile. Pass embeddingProfile '
        'to FlutterEdgeAiRag.open(), or complete a text operation first.',
      );
    }
    return profile;
  }

  Future<T> _accept<T>(Future<T> Function() operation) {
    _ensureUsable();
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
    if (_disposeRequested) {
      throw StateError('This RagIndex is disposing or already disposed.');
    }
  }

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
    int? expectedDimension,
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
    if (expectedDimension != null && embedding.length != expectedDimension) {
      throw ArgumentError.value(
        embedding.length,
        'embedding.length',
        'must match the pinned profile dimension $expectedDimension',
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

class _TextProfileClaim {
  _TextProfileClaim() {
    // The claimant reports resolution failures through its operation future.
    // This handler only prevents a claim with no followers from becoming an
    // unhandled asynchronous error; followers still receive the same error.
    future.ignore();
  }

  final Completer<EmbeddingProfile> _completer = Completer<EmbeddingProfile>();

  Future<EmbeddingProfile> get future => _completer.future;

  void complete(EmbeddingProfile profile) => _completer.complete(profile);

  void completeError(Object error, StackTrace stackTrace) =>
      _completer.completeError(error, stackTrace);
}
