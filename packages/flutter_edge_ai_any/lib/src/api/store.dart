part of 'any_sync.dart';

/// The store behind one `RagIndex` on an any-sync location. Not exported:
/// apps reach it only through `FlutterEdgeAiRag.open`.
final class _AnyVectorStore extends VectorStoreRepository {
  _AnyVectorStore(this._account, this._location, {required this._enableText});

  final AnySyncAccount _account;
  final AnySyncLocation _location;
  final bool _enableText;
  _LocationCore? _core;
  FilterSchema _schema = FilterSchema.empty;
  bool _closed = false;
  Future<void>? _closing;

  @override
  bool get isInitialized => _core != null && !_closed;

  @override
  FilterSchema get filterSchema => _schema;

  @override
  void configure(FilterSchema schema) {
    // Any name works: fields are stored under sha256(name)-type.
    FilterField.validateSchema(schema);
    _schema = schema;
  }

  _LocationCore _requireCore() {
    final c = _core;
    if (c == null || _closed) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }
    return c;
  }

  @override
  Future<void> initialize(String location) async {
    if (_closed) throw StateError('This store is closed.');
    if (_core != null) throw StateError('Already initialized.');
    final parsed = AnySyncLocation.parse(location);
    if (parsed != _location) {
      throw ArgumentError.value(
        location,
        'location',
        'this store was created for ${_location.value}',
      );
    }
    final core = await _account._acquire(_location, owner: true);
    try {
      await core.prepare(_schema, enableText: _enableText);
    } catch (_) {
      await _account._release(core, owner: true);
      rethrow;
    }
    _core = core;
  }

  @override
  Future<VectorStoreBinding?> readBinding() async => _requireCore().binding;

  @override
  Future<void> bind(VectorStoreBinding binding) =>
      _requireCore().bindLocation(binding, _schema, enableText: _enableText);

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    final core = _requireCore();
    final b = core.requireBinding();
    if (embedding.length != b.profile.dimension) {
      throw ArgumentError(
        'Embedding dimension mismatch: profile ${b.profile.dimension}, '
        'got ${embedding.length}',
      );
    }
    final vector = finiteFloat32(embedding);
    if (vector == null) {
      throw ArgumentError.value(
        embedding,
        'embedding',
        'must contain only finite float32 values',
      );
    }
    await core.add(key: id, content: content, vector: vector, meta: metadata);
  }

  @override
  Future<void> removeDocument({required String id}) =>
      _requireCore().remove(id);

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    final core = _requireCore();
    final b = core.requireBinding();
    if (queryEmbedding.length != b.profile.dimension) {
      throw ArgumentError(
        'Query dimension mismatch: profile ${b.profile.dimension}, '
        'got ${queryEmbedding.length}',
      );
    }
    _checkTopK(topK);
    final query = finiteFloat32(queryEmbedding);
    if (query == null) {
      throw ArgumentError.value(queryEmbedding, 'queryEmbedding', 'not finite');
    }
    final f = translateFilter(filter, _schema);
    if (f.matchesNothing) return const [];
    final r = await core._read(knnJob(core.handle, query, topK, f.query));
    final out = <RetrievalResult>[];
    for (final hit in (r['results'] as List? ?? const [])) {
      final m = (hit as Map).cast<String, Object?>();
      final similarity = 1.0 - (m['distance']! as num).toDouble();
      if (similarity < threshold) continue;
      out.add(
        RetrievalResult(
          id: m['id']! as String,
          content: (m['text'] as String?) ?? '',
          similarity: similarity,
          metadata: m['meta'] as String?,
        ),
      );
    }
    return out;
  }

  static void _checkTopK(int topK) {
    if (topK <= 0) throw ArgumentError.value(topK, 'topK', 'must be > 0');
    if (topK > _maxTopK) {
      throw ArgumentError.value(
        topK,
        'topK',
        'must be at most $_maxTopK (exact search; hybrid search asks each '
            'leg for 4 x topK, so topK > 2500 there)',
      );
    }
  }

  @override
  bool get supportsTextSearch => true;

  @override
  Future<List<TextSearchResult>> searchText({
    required String text,
    required int topK,
    Filter? filter,
  }) async {
    final core = _requireCore();
    if (!core.textSearch) {
      throw StateError(
        'This location has no text index. Open it once with '
        'VectorStoreSpec(enableTextSearch: true) to create one.',
      );
    }
    _checkTopK(topK);
    final query = _textQuery(text);
    if (query == null) return const [];
    final f = translateFilter(filter, _schema);
    if (f.matchesNothing) return const [];
    final r = await core._read(textJob(core.handle, query, topK, f.query));
    final seen = <String>{};
    return [
      for (final hit in (r['results'] as List? ?? const []))
        if (seen.add((hit as Map)['id']! as String))
          TextSearchResult(
            id: hit['id']! as String,
            content: (hit['text'] as String?) ?? '',
            relevanceScore: (hit['score']! as num).toDouble(),
            metadata: hit['meta'] as String?,
          ),
    ];
  }

  /// Vector rows only: text-only rows are in locationStatus and
  /// missingVectors.
  @override
  Future<VectorStoreStats> getStats() async {
    final core = _requireCore();
    final (_, vectors) = await core._read(countsJob(core.handle));
    return VectorStoreStats(
      documentCount: vectors,
      vectorDimension: core.binding?.profile.dimension ?? 0,
    );
  }

  @override
  Future<void> clear() => _requireCore().clear();

  @override
  Future<void> flush() async {
    final core = _requireCore();
    await core._idx(flushJob(core.handle));
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final core = _core;
    _core = null;
    if (core != null) await _account._release(core, owner: true);
  }
}
