import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_log.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_profile_storage.dart';
import 'package:flutter_edge_ai_sqlite/src/web_store_location_lease.dart';
import 'package:sqlite3/wasm.dart';

/// Web implementation of [VectorStoreRepository] backed by sqlite-vec (`vec0`)
/// running in a custom `sqlite3.wasm` (the vector extension is statically
/// linked in — see `tool/build_vec0_wasm.sh`).
///
/// **Architecture** (single engine, identical SQL dialect to the native arm):
/// ```
/// WebSqliteVectorStore (Dart, main isolate)
///         ↓  package:sqlite3/wasm.dart  (CommonSqlite3 API)
/// sqlite3.wasm  (sqlite-vec / vec0 statically linked)
///         ↓  VFS
/// OPFS → IndexedDB → in-memory  (first that works; persists across reload)
/// ```
///
/// KNN runs inside SQLite — there is no Dart brute-force and no in-memory HNSW.
/// `vec0` returns a `distance`; cosine **similarity = 1 - distance**, and the
/// `threshold`/`topK` are applied against that, exactly like the native store.
///
/// The vec0 table is created **lazily** on the first [addDocument] (so the
/// embedding dimension can be learned), or recovered from an existing table on
/// [initialize].
class WebSqliteVectorStore implements VectorStoreRepository {
  WebSqliteVectorStore({
    @visibleForTesting this.forceBrowserLocksUnavailableForTesting = false,
    @visibleForTesting this.durabilityFenceForTesting,
  });

  /// Test seam for the fail-closed browser capability branch.
  @visibleForTesting
  final bool forceBrowserLocksUnavailableForTesting;

  /// Test seam for deterministic post-COMMIT persistence failure.
  @visibleForTesting
  final Future<void> Function()? durabilityFenceForTesting;

  static const String _tableName = 'vec_documents';

  /// Where the custom wasm ships in the published package's web assets.
  /// Resolved relative to the app's base href at runtime.
  static const String _wasmUrl = 'rag/sqlite3.wasm';

  /// The single logical database file the persistent VFS reserves. OPFS /
  /// IndexedDB persist exactly one file; opening it is the simolus3-documented
  /// persistent path.
  static const String _dbFile = '/database';

  WasmSqlite3? _sqlite3;
  CommonDatabase? _db;
  int? _detectedDimension;
  EmbeddingProfile? _embeddingProfile;
  bool _isInitialized = false;
  WebStoreLocationLease? _locationLease;

  /// Serializes initialize/close calls on this instance. The counter changes
  /// synchronously when a transition is queued, so operations cannot slip in
  /// before the queued callback starts on the next microtask.
  Future<void> _lifecycleTail = Future<void>.value();
  int _pendingLifecycleActions = 0;

  /// Binding and explicit flush cross an await boundary. Lifecycle transitions
  /// wait for those durability operations; all other store operations execute
  /// their SQLite work synchronously before their returned Future is observed.
  int _activeDurabilityOperations = 0;
  Completer<void>? _durabilityOperationsIdle;

  /// Which VFS [_registerPersistentVfs] actually settled on.
  ///
  /// Not cosmetic: it is the difference between a store that survives a reload
  /// and one that does not, and [flush] cannot answer honestly without it.
  _WebPersistence _persistence = _WebPersistence.inMemory;

  /// The IndexedDB VFS, kept so [flush] and [close] can drain it.
  ///
  /// Held deliberately. `sqlite3`'s IndexedDB VFS writes asynchronously and its
  /// `xSync` is a documented no-op ("We can't wait for a sync either way"), so
  /// a commit does NOT mean the bytes reached IndexedDB. `flush()` on the VFS
  /// is the drain, and without a reference there is nothing to call it on.
  IndexedDbFileSystem? _idb;

  /// Declared filterable-metadata schema (via [configure]). Empty by default,
  /// so callers that never declare a schema keep the historical behaviour
  /// (filters are an ignored no-op).
  FilterSchema _filterSchema = const FilterSchema();

  @override
  bool get isInitialized => _isInitialized && _pendingLifecycleActions == 0;

  @override
  FilterSchema get filterSchema => _filterSchema;

  @override
  void configure(FilterSchema schema) {
    // Validate here, not only in FilterField's assert: asserts are stripped in
    // release, and a field name read from config at runtime would otherwise
    // reach the storage layer unchecked. Rejecting at configure() points the
    // error at the schema the developer wrote rather than at a query built
    // from it much later.
    // Core checks what is wrong on every backend; this store checks what
    // ITS storage cannot take. Splitting them keeps one backend's grammar
    // out of a package that has no backends.
    FilterField.validateSchema(schema);
    for (final field in schema.fields) {
      FilterToVec0.validateFieldName(field.name);
    }
    _filterSchema = schema;
  }

  @override
  Future<void> initialize(String databasePath) =>
      _enqueueLifecycle(() => _initialize(databasePath));

  Future<void> _initialize(String databasePath) async {
    // A store owns at most one location. Release a previous location before
    // attempting the next one, then acquire the new lease before opening any
    // OPFS or IndexedDB handle.
    await _waitForDurabilityOperations();
    await _closeResources();
    _locationLease = await WebStoreLocationLease.acquire(
      databasePath,
      forceBrowserLocksUnavailable: forceBrowserLocksUnavailableForTesting,
    );
    try {
      _sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse(_wasmUrl));
      await _registerPersistentVfs(_sqlite3!, databasePath);

      _db = _sqlite3!.open(_dbFile);

      ensureSqliteEmbeddingProfileTable(_db!);
      // Recover the dimension from an existing vec0 table (page reload).
      _detectExistingTable();
      _embeddingProfile = readSqliteEmbeddingProfile(_db!);
      _validateProfileDimension();

      _isInitialized = true;
    } catch (e) {
      // Settle the state, same as the native arm. A FIRST failed initialize
      // was already honest here (the flag is set last), but a RE-initialize
      // that throws used to keep the previous run's `true` — and `_db` had
      // already been reassigned above, dropping the old handle unclosed. So
      // "isInitialized reports true after an initialize() that threw" was only
      // half fixed if this arm were left alone.
      _isInitialized = false;
      _detectedDimension = null;
      _embeddingProfile = null;
      await _closeResources();
      if (e is VectorStoreException) rethrow;
      throw VectorStoreException('Failed to initialize SQLite WASM (vec0)', e);
    }
  }

  /// Registers the best persistent VFS the current runtime supports and makes
  /// it the default, so `open(_dbFile)` persists across reloads.
  ///
  /// Preference order: OPFS (fastest, needs a dedicated worker context) →
  /// IndexedDB (works on the main isolate, where Flutter web runs) →
  /// in-memory (no persistence; last resort so the store still functions).
  Future<void> _registerPersistentVfs(
    WasmSqlite3 sqlite3,
    String databasePath,
  ) async {
    // OPFS first — only available in a dedicated web worker; on the main
    // isolate (the usual Flutter web context) it throws, so we fall through.
    try {
      final opfs = await SimpleOpfsFileSystem.loadFromStorage(databasePath);
      sqlite3.registerVirtualFileSystem(opfs, makeDefault: true);
      _persistence = _WebPersistence.opfs;
      _idb = null;
      sqliteLog('[WebVectorStore] Using OPFS VFS for persistence');
      return;
    } catch (e) {
      sqliteLog('[WebVectorStore] OPFS VFS unavailable ($e); trying IndexedDB');
    }

    // IndexedDB — main-isolate-safe and persistent. The IndexedDB database name
    // is derived from the caller's path so distinct stores stay isolated.
    try {
      final idb = await IndexedDbFileSystem.open(
        dbName: 'flutter_gemma_rag_$databasePath',
      );
      sqlite3.registerVirtualFileSystem(idb, makeDefault: true);
      _persistence = _WebPersistence.indexedDb;
      _idb = idb;
      sqliteLog('[WebVectorStore] Using IndexedDB VFS for persistence');
      return;
    } catch (e) {
      sqliteLog(
        '[WebVectorStore] IndexedDB VFS unavailable ($e); '
        'falling back to in-memory (no persistence)',
      );
    }

    // Last resort: in-memory — the store works but loses all documents on page
    // reload. Logged explicitly (symmetric with the OPFS/IndexedDB branches) so
    // the durability downgrade is at least visible in debug builds. NOTE:
    // sqliteLog is stripped in release, so a production user in a restricted-
    // storage context (private browsing, partitioned storage) gets a
    // non-persistent store silently — surfacing this through a public
    // persistence-mode API is tracked as a follow-up.
    sqliteLog(
      '[WebVectorStore] Neither OPFS nor IndexedDB available — using in-memory '
      'storage. Documents will NOT persist across page reloads.',
    );
    sqlite3.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
    _persistence = _WebPersistence.inMemory;
    _idb = null;
  }

  /// Reads the embedding dimension back from an existing vec0 table, if any.
  void _detectExistingTable() {
    // Reset first, and do NOT catch — both exactly as the native arm.
    //
    // Both early returns below mean "this database tells us nothing", and
    // keeping the previous value there let a re-initialize onto a DIFFERENT,
    // empty database inherit the old dimension.
    //
    // The catch that used to sit here logged and continued, so `initialize()`
    // went on to set `_isInitialized = true` with no dimension: `searchSimilar`
    // then returned `[]`, `getStats` reported `documentCount: 0`, and
    // `removeDocument` reported success while deleting nothing — over a corpus
    // that was there and merely unreadable. Its comment claimed it would
    // "start fresh"; it dropped nothing, so the next `addDocument` ran
    // `CREATE VIRTUAL TABLE IF NOT EXISTS` against the surviving table and did
    // nothing either. An app deploying the stock `sqlite3.wasm` instead of the
    // vec0-linked one this package ships hits it on the first query, and the
    // only trace was a `gemmaLog` that does not exist in a release build.
    _detectedDimension = null;
    final exists = _db!.select(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
      [_tableName],
    );
    if (exists.isEmpty) return;
    final createSql = exists.first['sql'];
    if (createSql is String) {
      final match = RegExp(
        r'\bembedding\s+float\[(\d+)\]',
        caseSensitive: false,
      ).firstMatch(createSql);
      final dimension = int.tryParse(match?.group(1) ?? '');
      if (dimension != null && dimension > 0) {
        _detectedDimension = dimension;
        return;
      }
    }
    final row = _db!.select('SELECT embedding FROM $_tableName LIMIT 1');
    if (row.isEmpty) return;
    final blob = row.first['embedding'] as Uint8List;
    _detectedDimension = blob.length ~/ 4; // float32 = 4 bytes
  }

  void _validateProfileDimension() {
    final profile = _embeddingProfile;
    final dimension = _detectedDimension;
    if (profile != null &&
        dimension != null &&
        profile.dimension != dimension) {
      throw VectorStoreException(
        'The persisted $profile conflicts with the SQLite vec_documents '
        'dimension $dimension.',
      );
    }
  }

  EmbeddingProfile _requireEmbeddingProfile() {
    final profile = _embeddingProfile;
    if (profile == null) {
      throw StateError(
        'This SQLite vector store has no embedding profile. Bind one through '
        'FlutterEdgeAiRag.open() before adding or searching vectors.',
      );
    }
    return profile;
  }

  @override
  Future<EmbeddingProfile?> readEmbeddingProfile() async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }
    final profile = readSqliteEmbeddingProfile(_db!);
    _embeddingProfile = profile;
    _validateProfileDimension();
    return profile;
  }

  @override
  Future<void> bindEmbeddingProfile(EmbeddingProfile profile) async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }
    _beginDurabilityOperation();
    try {
      final dimension = _detectedDimension;
      if (dimension != null && dimension != profile.dimension) {
        throw VectorStoreException(
          'Cannot bind $profile to a SQLite vec_documents shard with dimension '
          '$dimension.',
        );
      }
      try {
        await bindSqliteEmbeddingProfile(
          _db!,
          profile,
          durabilityFence: durabilityFenceForTesting ?? _flushDurably,
        );
        _embeddingProfile = profile;
      } on SqliteProfileDurabilityException {
        // The SQL COMMIT has already succeeded when the durability fence fails.
        // Its durable state is now unknown, so this connection must never keep
        // serving reads or writes from the live-but-unconfirmed snapshot.
        await _closeResources();
        rethrow;
      }
    } finally {
      _finishDurabilityOperation();
    }
  }

  /// Builds the `vec0` virtual table for dimension [dimension] with one typed,
  /// filterable column per declared [FilterSchema] field, plus auxiliary
  /// (SELECT-only) `+content` / `+metadata` columns.
  void _createTable(int dimension) {
    final columns = <String>[
      'id TEXT PRIMARY KEY',
      // distance_metric=cosine so KNN `distance` is cosine distance in [0,2]
      // and `similarity = 1 - distance` holds. Without it vec0 defaults to L2,
      // breaking the similarity convention (matches the native store).
      'embedding float[$dimension] distance_metric=cosine',
      // Deliberately bare, never quoted — sqlite-vec's DDL tokenizer has no
      // quoted-identifier form. FilterField's constructor guarantees the name
      // is a legal bare identifier. Matches the native store.
      for (final field in _filterSchema.fields)
        '${field.name} ${_columnType(field.type)}',
      '+content TEXT',
      '+metadata TEXT',
    ];
    _db!.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS $_tableName USING vec0(\n'
      '  ${columns.join(',\n  ')}\n'
      ')',
    );
  }

  static String _columnType(FilterFieldType type) => switch (type) {
    FilterFieldType.string => 'TEXT',
    FilterFieldType.number => 'FLOAT',
    FilterFieldType.bool => 'INTEGER',
  };

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }

    final profile = _requireEmbeddingProfile();
    if (embedding.length != profile.dimension) {
      throw ArgumentError(
        'Embedding dimension mismatch: profile ${profile.dimension}, '
        'got ${embedding.length}',
      );
    }

    // Learn the dimension on the first add, then create the vec0 table.
    if (_detectedDimension == null) {
      _detectedDimension = embedding.length;
      _createTable(_detectedDimension!);
    } else if (embedding.length != _detectedDimension) {
      throw ArgumentError(
        'Embedding dimension mismatch: expected $_detectedDimension, '
        'got ${embedding.length}',
      );
    }

    try {
      // Shared with the native arm — see FilterToVec0.declaredColumnValues.
      // One entry per declared field, in schema order, so both arms write the
      // same column list for the same document.
      final declared = FilterToVec0.declaredColumnValues(
        metadata,
        _filterSchema,
      );
      final columns = <String>[
        'id',
        'embedding',
        // Quoted here (SQLite parses this statement) but NOT in the vec0 DDL
        // above — see FilterToVec0.quoteColumn.
        ...declared.keys.map(FilterToVec0.quoteColumn),
        'content',
        'metadata',
      ];
      // `CAST(? AS REAL)` for every declared NUMBER column — a web-only
      // necessity, not belt-and-braces.
      //
      // The shared codec already does `value.toDouble()` for a number field
      // (FilterToVec0.coerceForColumn), which is what makes the NATIVE arm bind
      // REAL. Under dart2js that call cannot work: it has one numeric type, so
      // `10.0` and `10` are the same JS number and `10.0 is int` is TRUE
      // (`_isInt` is `Math.floor(x) === x`). package:sqlite3 does no coercion of
      // its own — its bind switch simply tests `is int` before `is double`, and
      // dart2js makes the first branch win. vec0 then refuses the row:
      //   Expected float for FLOAT metadata column price, received INTEGER
      // so an ordinary `{"price": 10}` document was insertable natively and not
      // in a browser. SQL is the one place the distinction survives, so SQL is
      // where the type gets declared.
      //
      // dart2wasm does NOT have this problem — it keeps BoxedInt/BoxedDouble
      // apart, so the CAST is a harmless no-op there. `flutter build web --wasm`
      // still falls back to the dart2js output on a browser without WasmGC, so
      // the hazard is browser-conditional and the CAST has to stay.
      final numberColumns = {
        for (final f in _filterSchema.fields)
          if (f.type == FilterFieldType.number) f.name,
      };
      // A non-finite declared value is the absent-field sentinel
      // (FilterToVec0.absentNumber). It goes in as a literal for the same
      // reason the WHERE clause does it: binding -Infinity on the web throws
      // "cannot be converted to a BigInt" before SQL ever sees it.
      final declaredSql = <String>[];
      final declaredBinds = <Object?>[];
      for (final entry in declared.entries) {
        final v = entry.value;
        if (numberColumns.contains(entry.key)) {
          if (v is num && !v.isFinite) {
            declaredSql.add(FilterToVec0.absentNumberSql);
            continue;
          }
          declaredSql.add('CAST(? AS REAL)');
        } else {
          declaredSql.add('?');
        }
        declaredBinds.add(v);
      }
      final placeholders = [
        '?', // id
        '?', // embedding
        ...declaredSql,
        '?', // content
        '?', // metadata
      ].join(', ');
      final binds = <Object?>[
        id,
        _embeddingToBlob(embedding),
        ...declaredBinds,
        content,
        metadata,
      ];
      // vec0 does NOT honor `INSERT OR REPLACE`/UPSERT conflict resolution on
      // its declared TEXT primary key — a duplicate id raises a UNIQUE
      // violation instead of replacing. Emulate upsert with delete-then-insert
      // (matches the native store).
      _db!.execute('DELETE FROM $_tableName WHERE id = ?', [id]);
      _db!.execute(
        'INSERT INTO $_tableName (${columns.join(', ')}) '
        'VALUES ($placeholders)',
        binds,
      );
    } catch (e) {
      throw VectorStoreException('Failed to add document', e);
    }
  }

  @override
  Future<void> removeDocument({required String id}) async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }
    try {
      // No-op when the table doesn't exist yet (nothing was ever added) or the
      // id is absent — DELETE simply matches zero rows.
      if (_detectedDimension == null) return;
      _db!.execute('DELETE FROM $_tableName WHERE id = ?', [id]);
    } catch (e) {
      throw VectorStoreException('Failed to remove document', e);
    }
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }

    final profile = _requireEmbeddingProfile();
    if (queryEmbedding.length != profile.dimension) {
      throw ArgumentError(
        'Query dimension mismatch: profile ${profile.dimension}, '
        'got ${queryEmbedding.length}',
      );
    }

    // No table yet → no documents → empty result (never throws on filter).
    if (_detectedDimension == null) return const [];

    if (queryEmbedding.length != _detectedDimension) {
      throw ArgumentError(
        'Query dimension mismatch: expected $_detectedDimension, '
        'got ${queryEmbedding.length}',
      );
    }

    try {
      final translated = FilterToVec0.translate(filter, _filterSchema);
      // An unsatisfiable filter has one answer and it costs nothing to give:
      // an empty result. Without this the over-fetch loop below would grow the
      // candidate set to the 16x cap looking for rows that cannot exist, and
      // then log that the result "may be truncated" — a warning about a
      // shortfall that is the correct and complete answer.
      if (translated.matchesNothing) return const [];
      final whereExtra = translated.whereSql.isEmpty
          ? ''
          : ' AND ${translated.whereSql}';

      // Over-fetch exactly as the native arm does. Both arms share
      // FilterToVec0, so the SQL and binds are byte-identical — and this loop
      // was missing here, which meant the same filter answered `[d4]` on
      // native and `[]` on web. See the native store for why an unpushable
      // filter needs it at all.
      var fetch = topK;
      int? totalRows;
      final results = <RetrievalResult>[];
      var rowsReturned = 0;

      while (true) {
        final rows = _db!.select(
          'SELECT id, content, metadata, distance FROM $_tableName '
          'WHERE embedding MATCH ? AND k = ?$whereExtra '
          'ORDER BY distance',
          [_embeddingToBlob(queryEmbedding), fetch, ...translated.binds],
        );
        rowsReturned = rows.length;

        results.clear();
        for (final row in rows) {
          final similarity = 1.0 - (row['distance'] as num).toDouble();
          // Ordered by distance, so this only trims the tail — not a reason to
          // fetch more (see FilterToVec0.shouldOverFetch).
          if (similarity < threshold) break;
          results.add(
            RetrievalResult(
              id: row['id'] as String,
              content: row['content'] as String? ?? '',
              similarity: similarity,
              metadata: row['metadata'] as String?,
            ),
          );
        }

        if (translated.whereSql.isEmpty) break;
        totalRows ??=
            _db!.select('SELECT COUNT(*) AS c FROM $_tableName').first['c']
                as int;
        if (!FilterToVec0.shouldOverFetch(
          rowsReturned: rowsReturned,
          topK: topK,
          fetch: fetch,
          totalRows: totalRows,
        )) {
          break;
        }
        fetch *= 2;
      }

      return results.length > topK ? results.sublist(0, topK) : results;
    } catch (e) {
      throw VectorStoreException('Search failed', e);
    }
  }

  @override
  Future<VectorStoreStats> getStats() async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }

    try {
      final count = _detectedDimension == null
          ? 0
          : (_db!
                    .select('SELECT COUNT(*) AS count FROM $_tableName')
                    .first['count']
                as int);
      return VectorStoreStats(
        documentCount: count,
        vectorDimension: _detectedDimension ?? 0,
      );
    } catch (e) {
      throw VectorStoreException('Failed to get stats', e);
    }
  }

  @override
  Future<void> clear() async {
    if (!isInitialized || _db == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }

    try {
      // Drop only the document table. The separately persisted embedding
      // profile deliberately survives clear().
      if (_detectedDimension != null) {
        _db!.execute('DROP TABLE IF EXISTS $_tableName');
      }
      _detectedDimension = null;
    } catch (e) {
      throw VectorStoreException('Failed to clear vector store', e);
    }
  }

  @override
  Future<void> flush() async {
    if (!_isInitialized && _idb == null && _pendingLifecycleActions == 0) {
      return;
    }
    if (!isInitialized || _db == null) {
      throw StateError(
        'VectorStore lifecycle transition in progress. Await initialize() or '
        'close() before flushing.',
      );
    }
    _beginDurabilityOperation();
    try {
      await _flushDurably();
    } finally {
      _finishDurabilityOperation();
    }
  }

  Future<void> _flushDurably() async {
    // NOT a no-op here, unlike the native arm, and the difference is the whole
    // reason this method exists on web.
    //
    // sqlite3 autocommits, so the bytes have reached the VFS. Whether the VFS
    // has written them anywhere durable is a separate question, and for the
    // one Flutter web actually gets — IndexedDB, since OPFS needs a dedicated
    // worker — the answer is no: its `xSync` is a documented no-op ("We can't
    // wait for a sync either way"), and `open()` describes its writes as
    // asynchronous "without any durability guarantees. You can invoke flush".
    // That `flush` is this call.
    //
    // HOW COMPLETE the drain is depended on the sqlite3 version, which is why
    // this package floors it at 3.6.0. Between 3.4.0 and 3.5.2 `flush()`
    // returned immediately whenever a write batch was already in flight — the
    // ordinary state right after indexing — because upstream commit 11be8acb
    // ("Optimize indexeddb flush on idle") took out the marker it used to
    // queue behind, while its own doc still promised to await. Measured: zero
    // event-loop turns on 3.5.2 against seven on 3.3.3. Reported as
    // simolus3/sqlite3.dart#408 and fixed in 3.6.0. That constraint, and the
    // Flutter 3.47 floor it drags in through hooks -> record_use -> meta, is
    // what keeps this a real fence rather than a comment; relax either and a
    // quiet success comes back.
    //
    // `close()` is the strong drain on web either way — it queues behind the
    // running batch on every version.
    //
    // Not gated on `_isInitialized` alone: a re-initialize that threw leaves
    // this store uninitialized while its IndexedDB VFS still holds unwritten
    // pages, and returning quietly there would report success over them. Not
    // on `_sqlite3` either — it is set before any VFS is chosen, so a flush
    // landing mid-initialize read `_persistence` unset and threw.
    // Nothing set up at all is the one case that stays quiet, per the contract.
    switch (_persistence) {
      case _WebPersistence.indexedDb:
        try {
          await _idb?.flush();
        } catch (e) {
          throw VectorStoreException('Failed to flush the IndexedDB store', e);
        }
      case _WebPersistence.opfs:
        // Nothing to drain, but not for the reason it looks like: an OPFS
        // write is NOT durable merely because `writeDart` returned. What makes
        // it durable is that SQLite calls `xSync` on commit and this VFS's
        // `xSync` is `syncHandle.flush()`. That holds while nothing sets
        // `PRAGMA synchronous=OFF` — this store sets no pragma, so the default
        // (FULL) applies and every autocommit statement syncs.
        break;
      case _WebPersistence.inMemory:
        // Neither OPFS nor IndexedDB was available, so this store cannot
        // persist at all. Returning normally would be the #492 defect wearing
        // a different hat: the caller asks "make this durable", gets a
        // success, and loses the index on reload. The only warning otherwise
        // is a sqliteLog that release builds strip.
        throw const VectorStoreException(
          'This store is running on an in-memory VFS (neither OPFS nor '
          'IndexedDB was available, e.g. private browsing or partitioned '
          'storage), so its documents cannot be persisted. Re-index after '
          'each reload, or run in a context that allows storage.',
        );
    }
  }

  @override
  Future<void> close() => _enqueueLifecycle(() async {
    await _waitForDurabilityOperations();
    await _closeResources();
  });

  Future<void> _closeResources() async {
    // Deliberately NOT gated on `_isInitialized` alone — same rule as the
    // native arm. A store whose initialize() failed is exactly the one still
    // holding resources nobody else will release, and the flag is false for it.
    // `_sqlite3` and the lease are named here because initialization can fail
    // after acquiring either one but before setting `_isInitialized`.
    if (_db == null &&
        _sqlite3 == null &&
        _locationLease == null &&
        !_isInitialized) {
      return;
    }
    // Settle every field BEFORE the await, not in a `finally` after it. While
    // that await ran, `isInitialized` still reported true over an
    // already-closed database, and a `flush()` landing in that window reached
    // a VFS that was closing underneath it.
    final db = _db;
    final idb = _idb;
    final lease = _locationLease;
    _db = null;
    _sqlite3 = null;
    _idb = null;
    _locationLease = null;
    _persistence = _WebPersistence.inMemory;
    _isInitialized = false;
    _detectedDimension = null;
    _embeddingProfile = null;
    try {
      db?.close();
      // The strong drain on web. `IndexedDbFileSystem.close()` queues a close
      // item BEHIND the running batch and awaits its completer, so unlike
      // `flush()` it is a true fence on every sqlite3 version. Without it a
      // caller that only ever calls close() loses the tail of its index.
      // Best-effort by design: close() is a cleanup path callers usually
      // cannot act on, and `flush()` is the call that reports failure.
      await idb?.close();
    } catch (e) {
      sqliteLog('[WebVectorStore] close() could not drain the VFS: $e');
    } finally {
      try {
        await lease?.release();
      } catch (e) {
        sqliteLog('[WebVectorStore] could not release the location lock: $e');
      }
    }
  }

  Future<void> _enqueueLifecycle(Future<void> Function() action) {
    final result = Completer<void>();
    _pendingLifecycleActions++;
    _lifecycleTail = _lifecycleTail.then((_) async {
      try {
        await action();
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pendingLifecycleActions--;
      }
    });
    return result.future;
  }

  void _beginDurabilityOperation() {
    if (_activeDurabilityOperations++ == 0) {
      _durabilityOperationsIdle = Completer<void>();
    }
  }

  void _finishDurabilityOperation() {
    _activeDurabilityOperations--;
    if (_activeDurabilityOperations == 0) {
      final idle = _durabilityOperationsIdle;
      _durabilityOperationsIdle = null;
      idle?.complete();
    }
  }

  Future<void> _waitForDurabilityOperations() async {
    if (_activeDurabilityOperations == 0) return;
    await _durabilityOperationsIdle!.future;
  }

  // === BLOB encoding (float32 little-endian, identical to native + Kotlin/Swift)

  static Uint8List _embeddingToBlob(List<double> embedding) {
    final buffer = ByteData(embedding.length * 4);
    for (var i = 0; i < embedding.length; i++) {
      buffer.setFloat32(i * 4, embedding[i].toDouble(), Endian.little);
    }
    return buffer.buffer.asUint8List();
  }
}

/// Which virtual filesystem the web store ended up on.
///
/// The three differ in durability, not in speed, so [WebSqliteVectorStore.flush]
/// has to know which one it is talking to: one needs draining, one is already
/// on disk, and one cannot persist at all and must say so.
enum _WebPersistence { opfs, indexedDb, inMemory }
