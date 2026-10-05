import 'dart:convert';
import 'dart:io';

import 'package:qdrant_edge/qdrant_edge.dart' as qe;

/// Distance metric used by a qdrant-edge shard. Set at open time and fixed
/// for the shard's lifetime.
enum Distance {
  /// 1 - cosine angle between vectors. Most common for text embeddings;
  /// expects (but does not require) unit-norm inputs.
  cosine('cosine'),

  /// Dot product. For unit-norm vectors equivalent to cosine.
  dot('dot'),

  /// Euclidean (L2) distance.
  euclid('euclid'),

  /// Manhattan (L1) distance.
  manhattan('manhattan');

  final String wireName;
  const Distance(this.wireName);

  qe.Distance get _native => switch (this) {
    Distance.cosine => qe.Distance.cosine,
    Distance.dot => qe.Distance.dot,
    Distance.euclid => qe.Distance.euclid,
    Distance.manhattan => qe.Distance.manhattan,
  };
}

/// One search hit returned by [QdrantEdgeClient.search].
class SearchHit {
  /// Point ID as stored — typically a UUIDv5 string for points written via
  /// flutter_gemma's high-level repository.
  final String id;

  /// Similarity score per the shard's [Distance] metric. Cosine returns
  /// in [-1, 1] (close to 1 = similar); for L2/Manhattan, lower = more
  /// similar (semantics inverted from cosine — be careful when threshold-
  /// filtering downstream).
  final double score;

  /// Decoded payload object if the point had one, otherwise null.
  final Map<String, dynamic>? payload;

  const SearchHit({required this.id, required this.score, this.payload});
}

/// Typed wrapper around any failure surfaced by the qdrant-edge engine. The
/// UniFFI layer raises typed [qe.EdgeException]s; we flatten them into a single
/// [message] so the rest of the package keeps catching one exception type.
class QdrantException implements Exception {
  final String message;
  const QdrantException(this.message);

  @override
  String toString() => 'QdrantException: $message';
}

/// The shard is open somewhere else — another isolate, another store instance,
/// a handle the app did not close.
///
/// Recoverable and ordinary, which is exactly why it needs its own type: it
/// used to arrive as the same generic runtime error as "this data is corrupt",
/// distinguishable only by grepping `WouldBlock` out of an English message.
/// Treating the two as one is how a documented recovery step, written for the
/// corrupt case, once deleted an intact corpus.
class QdrantShardLockedException extends QdrantException {
  const QdrantShardLockedException(super.message);
}

/// High-level Dart wrapper over the official Qdrant Edge SDK ([qe.EdgeShard]).
///
/// This backs [QdrantVectorStore]; it is not meant for direct use by
/// application code. It owns exactly one [qe.EdgeShard] (the on-disk shard) and
/// adapts the typed SDK API to the JSON-payload / JSON-filter surface the rest
/// of flutter_gemma's RAG layer expects.
///
/// The native engine is delivered by the `qdrant_edge` package's Native Assets
/// build hook — there is no manual `DynamicLibrary.open`; the SDK's generated
/// binding resolves its symbols through the registered code asset, and
/// [qe.EdgeShard] carries its own finalizer, so a dropped client is still
/// released even without an explicit [close].
class QdrantEdgeClient {
  final qe.EdgeShard _shard;
  bool _closed = false;

  QdrantEdgeClient._(this._shard);

  /// Open (or create) a shard on disk.
  ///
  /// `path` is a directory — qdrant-edge stores its WAL + segment files under
  /// it (created if absent). `dim` is the vector dimension; once a shard is
  /// created with a given dim, subsequent opens must pass the same value or the
  /// engine rejects the reopen.
  static Future<QdrantEdgeClient> open({
    required String path,
    required int dim,
    Distance distance = Distance.cosine,
  }) async {
    try {
      // The engine creates its WAL/segment subdirs UNDER `path` but does not
      // create `path` itself (non-recursive), so ensure the shard directory
      // exists first — matching the historical shim, which mkdir-p'd it.
      Directory(path).createSync(recursive: true);
      // Single unnamed vector field, mirroring the historical shim contract
      // (one vector per point, addressed by the empty name).
      final config = qe.EdgeConfig(
        vectorData: {
          '': qe.VectorDataConfig(size: dim, distance: distance._native),
        },
      );
      return QdrantEdgeClient._(qe.EdgeShard.load(path: path, config: config));
    } on FileSystemException catch (e) {
      throw QdrantException('Failed to create shard directory at $path: $e');
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Opens a shard that ALREADY exists on disk, without being told its vector
  /// dimension, and reports the dimension it was created with.
  ///
  /// [open] has to be handed a `dim` because it may be creating the shard. A
  /// store being re-opened after an app restart has no embedding in hand yet —
  /// and without this it stayed closed, so `searchSimilar` answered "no hits"
  /// and `getStats` "0 documents" over a fully populated index until something
  /// happened to write to it.
  ///
  /// Returns `null` when [path] holds no shard.
  static Future<({QdrantEdgeClient client, int dim})?> openExisting({
    required String path,
  }) async {
    // `probeShard` (SDK 0.8.0-dev.3) answers the one question this method has
    // to ask, and it is the SDK's to answer: is there a shard here, and will it
    // load? Before it existed, `EdgeShard.load` raised the SAME error for "this
    // directory holds no shard" and "this shard will not load", so this package
    // guessed from the filesystem — looking for `edge_config.json` and parsing
    // it. That guess reported a full corpus as an empty store, because the
    // engine reads a shard whose config file is missing perfectly well. The
    // heuristic is gone; the SDK is asked instead.
    final qe.ShardProbe probe;
    try {
      probe = qe.probeShard(path: path);
    } catch (e) {
      // The probe is an FFI call like any other: a Rust panic here arrives as
      // UniffiInternalError, which is not an EdgeException, so without this it
      // crossed the package boundary as a type the caller cannot name.
      _rethrow(e);
    }
    switch (probe.presence) {
      case qe.EdgeShardPresence.none:
        return null;
      case qe.EdgeShardPresence.unreadable:
        // Positive evidence that something of ours is here and will not open.
        // Never report this as "no shard" — that is the silent-empty-index
        // defect this release exists to remove.
        throw QdrantException(
          'A qdrant shard is present at $path but cannot be read'
          '${probe.reason == null ? '' : ': ${probe.reason}'}',
        );
      case qe.EdgeShardPresence.loadable:
        break;
    }
    try {
      final shard = qe.EdgeShard.load(path: path, config: null);
      final cfg = shard.config();
      final size = cfg.vectorData['']?.size;
      if (size == null) {
        // A shard is HERE and it loaded — we simply cannot use it (no unnamed
        // vector field: written by another tool, or by a future format).
        // Returning null said "no shard", so the store came up empty over data
        // it had just proved was there. That is the strongest evidence this
        // function ever gets, and it was the one case that discarded it.
        shard.unload();
        throw const QdrantException(
          'A qdrant shard is present but was not written by this package '
          '(no unnamed vector field), so its documents cannot be read here.',
        );
      }
      return (client: QdrantEdgeClient._(shard), dim: size);
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Remove every point, leaving the shard open and usable.
  ///
  /// This is what the store's `clear()` needs, and it means the store never
  /// touches the filesystem to erase an index. It spent a release deleting the
  /// shard DIRECTORY instead, on the strength of a comment carried forward from
  /// the old Rust shim without rechecking: "qdrant-edge has no truncate
  /// primitive". The SDK has had one all along as
  /// `deletePointsByFilter(Filter())`, and 0.8.0-dev.3 gives it a name.
  Future<void> deleteAll() async {
    _checkOpen();
    try {
      _shard.clear();
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Upsert one point. `payload` may be omitted (`null`) or any JSON-encodable
  /// Map — it is stored as a JSON string in the point payload.
  Future<void> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) async {
    _checkOpen();
    try {
      _shard.update(
        operation: qe.UpdateOperation.upsertPoints(
          points: [_point(id, vector, payload)],
        ),
      );
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Bulk upsert — one shard update carrying every point.
  Future<void> upsertBatch(
    List<({String id, List<double> vector, Map<String, dynamic>? payload})>
    points,
  ) async {
    _checkOpen();
    if (points.isEmpty) return;
    try {
      _shard.update(
        operation: qe.UpdateOperation.upsertPoints(
          points: [for (final p in points) _point(p.id, p.vector, p.payload)],
        ),
      );
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Top-K nearest-neighbour search. Pass [filterJson] (the JSON envelope
  /// produced by `FilterCodec.encode`) to constrain by payload; pass null to
  /// run unfiltered.
  Future<List<SearchHit>> search({
    required List<double> queryVector,
    required int topK,
    String? filterJson,
  }) async {
    _checkOpen();
    try {
      final results = _shard.search(
        request: qe.SearchRequest(
          query: qe.NearestQuery(
            vector: qe.DenseNamedVector(queryVector),
            using: null,
          ),
          limit: topK,
          filter: _filterFromJson(filterJson),
          withPayload: qe.BoolWithPayload(true),
        ),
      );
      return [
        for (final sp in results)
          SearchHit(
            id: _idString(sp.id),
            score: sp.score,
            payload: _decodePayload(sp.payload),
          ),
      ];
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Delete points by IDs. No-op for IDs that don't exist.
  Future<void> delete(List<String> ids) async {
    _checkOpen();
    if (ids.isEmpty) return;
    try {
      _shard.update(
        operation: qe.UpdateOperation.deletePoints(
          pointIds: [for (final id in ids) qe.UuidPointId(id)],
        ),
      );
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Exact total number of points currently in the shard.
  Future<int> count() async {
    _checkOpen();
    try {
      return _shard.count(request: qe.CountRequest());
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Write the in-RAM segment out to disk, keeping the shard open.
  ///
  /// The crate declares this separately from [close]'s `unload()`, and the
  /// difference is the whole point: `unload()` also persists, but it ends the
  /// shard. This is what a caller reaches for after a bulk index when it wants
  /// to keep using the store — and it is what stands between an index and a
  /// process the OS kills without warning.
  Future<void> flush() async {
    _checkOpen();
    try {
      _shard.flush();
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Close the shard. Idempotent — safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _shard.unload();
    } catch (_) {
      // Best-effort, and deliberately broad. `_closed` is already set above, so
      // the only thing reaching here is a real unload failure — including a
      // UniffiInternalError, which is not an EdgeException and used to escape
      // close() raw. A shard that will not unload keeps its WAL lock for the
      // process lifetime; the next open reports that as a locked shard, which
      // is a better place to surface it than an exception out of a close the
      // caller usually cannot act on.
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const QdrantException('QdrantEdgeClient is closed');
    }
  }

  qe.Point _point(
    String id,
    List<double> vector,
    Map<String, dynamic>? payload,
  ) {
    return qe.Point(
      id: qe.UuidPointId(id),
      vector: qe.SingleVector(vector),
      payload: payload == null ? null : jsonEncode(payload),
    );
  }

  static String _idString(qe.PointId id) => switch (id) {
    qe.UuidPointId(:final value) => value,
    qe.NumIdPointId(:final value) => value.toString(),
    _ => id.toString(),
  };

  static Map<String, dynamic>? _decodePayload(String? payload) {
    if (payload == null) return null;
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static String _flatten(qe.EdgeException e) => e.toString();

  /// The one place SDK failures become this package's own type.
  ///
  /// `on qe.EdgeException` alone was not enough: a Rust panic or a
  /// bindings/native protocol mismatch arrives as `UniffiInternalError`, which
  /// is not an `EdgeException` — so it crossed every wrapper untouched and
  /// reached application code as a type the app could not name in a catch.
  /// 0.8.0-dev.3 exports it, so it can finally be caught here.
  static Never _rethrow(Object e) {
    // Already ours: thrown on purpose inside a wrapper's `try` (openExisting's
    // "not written by this package"). Re-wrapping it buried that message
    // under "unexpected error" and lost QdrantShardLockedException's type.
    if (e is QdrantException) throw e;
    if (e is qe.ShardLockedEdgeException) {
      throw QdrantShardLockedException(
        'The shard is already open elsewhere (its write-ahead log is held by '
        'another handle). Close the other store, or wait for it to finish.',
      );
    }
    if (e is qe.EdgeException) throw QdrantException(_flatten(e));
    if (e is qe.UniffiInternalError) {
      throw QdrantException('qdrant-edge internal failure: $e');
    }
    // Everything else is wrapped too, rather than rethrown raw. This used to
    // be a bare `throw e`, which meant any failure that is neither an
    // `EdgeException` nor a `UniffiInternalError` crossed all twelve wrapper
    // methods untouched — so `on QdrantException`, the catch every caller in
    // this package writes, missed it, and the store's own translation to
    // `VectorStoreException` never fired. The type is the contract; an escape
    // hatch that skips it is the same silent-failure shape as the bug this
    // package just fixed.
    throw QdrantException('qdrant-edge failed with an unexpected error: $e');
  }

  // ---- Filter bridge: qdrant JSON envelope → typed qe.Filter ----------------

  /// Translates the JSON filter envelope emitted by `FilterCodec.encode`
  /// (`{"must":[...],"should":[...],"must_not":[...]}`, each condition one of
  /// `{"key","match":{"value"|"any"}}`, `{"key","range":{...}}`, or itself a
  /// nested bucket `{"should":[...]}` — see [_conditionFromJson]) into the
  /// SDK's typed [qe.Filter]. Returns null for a null/empty envelope so the
  /// caller runs an unfiltered search.
  static qe.Filter? _filterFromJson(String? filterJson) {
    if (filterJson == null) return null;
    final map = jsonDecode(filterJson);
    if (map is! Map<String, dynamic>) return null;
    return _filterFromBucketMap(map);
  }

  /// Shared by the top-level envelope and by a condition that is itself a
  /// nested bucket (see [_conditionFromJson]) — both have the same
  /// `{"must"/"should"/"must_not": [...]}` shape.
  static qe.Filter? _filterFromBucketMap(Map<String, dynamic> map) {
    List<qe.Condition>? bucket(String key) {
      final raw = map[key];
      if (raw is! List || raw.isEmpty) return null;
      return [
        for (final c in raw)
          if (c is Map<String, dynamic>) _conditionFromJson(c),
      ];
    }

    final must = bucket('must');
    final should = bucket('should');
    final mustNot = bucket('must_not');
    if (must == null && should == null && mustNot == null) return null;
    return qe.Filter(must: must, should: should, mustNot: mustNot);
  }

  static qe.Condition _conditionFromJson(Map<String, dynamic> c) {
    // FilterCodec encodes some single logical conditions as a NESTED bucket
    // rather than a flat `{"key", "match"|"range"}` clause — e.g. a bool
    // FieldEquals expands to `{"should": [{"key","match"...}, {"key",
    // "range"...}]}` (both JSON spellings of the same boolean), and a
    // non-string FieldMatchAny expands the same way. The SDK's `Condition`
    // sealed class has no bare "wraps a Filter" case matching the server's
    // untagged `Condition::Filter(Filter)`; [qe.FilterCondition] is that case.
    if (c.containsKey('must') ||
        c.containsKey('should') ||
        c.containsKey('must_not')) {
      final nested = _filterFromBucketMap(c);
      if (nested != null) return qe.FilterCondition(nested);
    }

    final key = c['key'] as String;
    qe.Match? match;
    qe.RangeFloat? range;

    final m = c['match'];
    if (m is Map<String, dynamic>) {
      if (m.containsKey('value')) {
        match = qe.ValueMatch(_valueVariants(m['value']));
      } else if (m['any'] is List) {
        match = qe.AnyMatch(_anyVariants(m['any'] as List));
      }
    }

    final r = c['range'];
    if (r is Map<String, dynamic>) {
      double? n(Object? v) => (v as num?)?.toDouble();
      range = qe.RangeFloat(
        gte: n(r['gte']),
        gt: n(r['gt']),
        lte: n(r['lte']),
        lt: n(r['lt']),
      );
    }

    return qe.FieldConditionVariant(
      qe.FieldCondition(key: key, match: match, range: range),
    );
  }

  static qe.ValueVariants _valueVariants(Object? v) {
    if (v is bool) return qe.BoolValueVariants(v);
    if (v is int) return qe.IntegerValueVariants(v);
    return qe.StringValueVariants(v.toString());
  }

  static qe.AnyVariants _anyVariants(List values) {
    if (values.isNotEmpty && values.every((e) => e is int)) {
      return qe.IntegersAnyVariants(values.cast<int>());
    }
    return qe.StringsAnyVariants([for (final e in values) e.toString()]);
  }
}
