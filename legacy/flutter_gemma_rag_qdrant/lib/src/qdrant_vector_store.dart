import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_rag_qdrant/src/filter_codec.dart';
import 'package:flutter_gemma_rag_qdrant/src/point_id_hasher.dart';
import 'package:flutter_gemma_rag_qdrant/src/qdrant_edge_client.dart';
import 'package:path/path.dart' as p;

/// Thrown when a store written by `flutter_gemma_rag_qdrant` 1.x is found at
/// the bare `databasePath`, and ONLY then.
///
/// It is a separate type because the two things `initialize` can refuse over
/// want opposite responses. This one is permanent and needs the old files
/// removed; a plain [VectorStoreException] means a 2.0 shard is present and
/// will not open right now — a WAL held by another store, a permission
/// problem — which usually clears on its own. For a moment this package threw
/// the base type for both, and the recipe in its own README consequently
/// destroyed an intact 2.0 corpus whenever the store happened to be open
/// elsewhere. Measured, with two documents.
///
/// The message names what to remove, and it only names files when the marker
/// is a shard config this package wrote. Nothing in this package deletes them
/// for you.
class QdrantLegacyStoreException extends VectorStoreException {
  const QdrantLegacyStoreException(super.message);
}

/// Native-only RAG vector store backed by the official `qdrant_edge` SDK.
/// Implements
/// flutter_gemma's [VectorStoreRepository]. Its HNSW index makes it the fastest
/// native option — roughly 5–11× faster search than the in-SQLite sqlite-vec
/// store at 1k–10k docs (with identical top-K results). Web is unsupported
/// (qdrant-edge can't compile to WASM); use flutter_gemma_rag_sqlite there.
///
/// Public API parity with the existing contract:
///
/// * `String id` continues to be the user-facing identifier. Internally
///   each id is mapped to a stable UUIDv5 via [PointIdHasher] and stored
///   alongside the document content in the qdrant payload so that
///   [searchSimilar] returns the original String back without a sidecar
///   mapping table.
/// * `addDocument`'s `metadata` is still a JSON string. We do **not**
///   parse it eagerly — we forward the raw string into the payload under
///   the key `metadata`. Filtering by metadata fields therefore requires
///   that callers pass valid JSON; this matches the existing constraint.
/// * `enableHnsw` is accepted but ignored — qdrant decides indexing
///   internally based on its `indexing_threshold` (~20k points). Below
///   that it brute-forces a plain segment, which is already faster than
///   our Dart HNSW for typical RAG corpora.
///
/// Distance defaults to cosine, matching the historical behaviour.
///
/// ### On-disk layout
///
/// The store owns a bounded, format-scoped subdirectory —
/// `databasePath/qdrant_edge_v1` — created on first write, and that is the only
/// shard it ever opens. This means:
///
///   * a shard written by 1.x (crate 0.7.x) sits at the bare `databasePath` and
///     is never opened, so there is no partial-open or WAL-corruption risk from
///     mixing engine versions. It is not ignored either: [initialize] refuses
///     it with a [QdrantLegacyStoreException] rather than letting the store
///     come up silently empty over a populated index;
///   * [clear] never deletes a file. It empties the shard in place through the
///     SDK, so the directory survives and the store stays usable — and when a
///     1.x layout is present it refuses outright rather than removing data it
///     cannot read. Nothing the caller keeps alongside the store is ever
///     touched, by this package or by anything it tells the caller to do.
class QdrantVectorStore implements VectorStoreRepository {
  QdrantEdgeClient? _client;

  /// Dimension is captured on the first `addDocument` call (matches the
  /// existing auto-detection contract). Subsequent inserts must agree.
  int? _dim;

  /// Cached for [getStats] — the shim never exposes the configured dim,
  /// only the count. We keep it in Dart-land instead.
  final Distance _distance = Distance.cosine;

  /// The path passed to [initialize]. The store never opens or deletes this
  /// path directly — only the owned subdirectory under it (see [_storeDirFor]).
  String? _databasePath;

  /// In-flight [QdrantEdgeClient.open]. Two concurrent `addDocument` calls on a
  /// cold store both saw `_client == null` and both opened the same directory;
  /// qdrant holds the WAL exclusively, so the loser failed with
  /// `Can't init WAL: Kind(WouldBlock)` and its document was lost.
  /// `Future.wait(docs.map(store.addDocument))` is the obvious way to index a
  /// corpus, so this was reachable from ordinary use.
  Future<QdrantEdgeClient>? _opening;

  /// Bumped by [initialize] and [close]. An open that started before
  /// the bump must not install its client afterwards: it would resurrect a
  /// closed store (holding the WAL lock for the process lifetime) or, worse,
  /// point `_client` at the PREVIOUS path while `_databasePath` names the new
  /// one — sending every later write into the wrong store.
  int _generation = 0;

  /// Lifecycle transitions run one at a time.
  ///
  /// initialize/clear/close each mutate several fields around an await, and
  /// interleaving any two of them produced states no single method can:
  ///
  ///   * two concurrent `initialize(samePath)` calls — a provider rebuilt, an
  ///     initState firing twice — raced qdrant's exclusive WAL. One won, the
  ///     other caught `WouldBlock` and latched the store unreadable over an
  ///     intact corpus, while BOTH calls reported success. Measured.
  ///   * a `close()` landing inside initialize()'s `await existing.close()`
  ///     was silently undone: initialize resumed and re-installed a live
  ///     client, so a store the caller closed sat holding a WAL lock.
  ///   * a `clear()` landing in the same gap dropped a client a concurrent
  ///     initialize had just installed, without closing it — WAL held for the
  ///     process lifetime, every later write failing WouldBlock.
  ///
  /// `_generation` still guards the OPEN inside one transition. This guards
  /// the transitions against each other, which a counter captured after the
  /// await cannot do.
  Future<void> _lifecycle = Future<void>.value();

  Future<T> _serializeLifecycle<T>(Future<T> Function() body) {
    // The lane advances through a gate that never errors, NOT by attaching a
    // handler to the caller's own future.
    //
    // `_lifecycle = run.then((_) {}, onError: (_) {})` looked equivalent and
    // was not: attaching onError to `run` registers a listener, which marks
    // the error handled globally, so an UNAWAITED call reached neither
    // Zone.handleUncaughtError nor FlutterError.onError. `initState()` cannot
    // await, so `store.initialize(dir);` fire-and-forget is the ordinary shape
    // — the one this lane's own comment cites — and over a 1.x store the
    // headline error of this release went nowhere at all. Measured against a
    // plain unawaited async throw in the same zone: the control arrived, this
    // did not.
    final gate = Completer<void>();
    final previous = _lifecycle;
    _lifecycle = gate.future;
    return previous.then((_) async {
      try {
        return await body();
      } finally {
        gate.complete();
      }
    });
  }

  /// Set when the store is armed but must NOT be read: the full message
  /// explaining why.
  ///
  /// `_client == null` collapsed three different facts into one value: never
  /// initialized (a caller error), initialized-but-cold (genuinely empty), and
  /// "there are documents on disk that we failed to read". The third read as
  /// the second — searchSimilar returned `[]`, getStats returned 0 — so an app
  /// whose corpus was intact but unreadable answered without context and said
  /// nothing about it. That is the defect this release exists to fix; leaving
  /// it on the read path would be shipping it under a new version number.
  ///
  /// Two things set it, and both used to be invisible to a reader:
  ///   * adoption failed — a shard is on disk and would not open;
  ///   * a 1.x store was found, which initialize() also throws for.
  ///
  /// The second is why this is a latch and not just a return value.
  /// initialize() arms `_databasePath` BEFORE it throws, so that clear() — the
  /// remedy its own message prescribes — stays reachable. Without a latch that
  /// left the object looking healthy: a caller that logged the exception and
  /// carried on got `getStats() == 0` and no search hits over an intact 1.x
  /// corpus. That is the exact defect this release exists to remove, in the one
  /// case the release is about. Measured, not reasoned about.
  ///
  /// Cleared once an open succeeds, and on initialize/clear/close.
  String? _unusableReason;

  /// `enableHnsw` is part of the contract but a no-op for qdrant.
  bool _enableHnsw = true;

  /// Declared filterable-metadata schema (via [configure]). Empty by default,
  /// so callers that never declare a schema get byte-identical payloads. When
  /// non-empty, [addDocument] promotes each declared field to a TOP-LEVEL
  /// payload key (alongside the opaque [_metadataKey] blob) so qdrant's
  /// [FilterCodec] — which already targets top-level keys — can match on them.
  FilterSchema _filterSchema = const FilterSchema();

  /// Payload key under which we stash the original String id sent by the
  /// caller. qdrant point ids are UUID-hashed for storage; this lets
  /// [searchSimilar] reconstruct the original on the way out.
  static const _userIdKey = '__flutter_gemma_id';
  static const _contentKey = '__flutter_gemma_content';
  static const _metadataKey = '__flutter_gemma_metadata';

  /// The three keys above, as a set — [configure] refuses a filter field that
  /// would collide with one.
  static const _reservedPayloadKeys = <String>{
    _userIdKey,
    _contentKey,
    _metadataKey,
  };

  /// The package's on-disk format namespace. A new location for the 0.8.0
  /// SDK / crate-0.8.0 shard format. A shard written by an older (1.x /
  /// crate 0.7.x) release sits at the bare [_databasePath]; this release never
  /// opens it, refuses to start over it, and can remove it via [clear].
  static const _storeDirName = 'qdrant_edge_v1';

  @override
  /// The contract is "true if [initialize] was called successfully" — so a
  /// store whose initialize() threw must answer false, even though the path is
  /// still armed so clear() can reach it. Answering true told a caller it was
  /// ready when every operation on it refuses.
  bool get isInitialized => _databasePath != null && _unusableReason == null;

  @override
  bool get enableHnsw => _enableHnsw;

  @override
  set enableHnsw(bool value) => _enableHnsw = value;

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
      FilterCodec.validateFieldName(field.name);
      // Declared fields are promoted to TOP-LEVEL payload keys, the same map
      // that carries the document's id, content and metadata. A field named
      // like one of those overwrites it: a String value silently swaps the id
      // or the body of every hit, and a non-String value escapes searchSimilar
      // as a raw _TypeError rather than a VectorStoreException. Reject it here,
      // where the error points at the schema the developer wrote.
      if (_reservedPayloadKeys.contains(field.name)) {
        throw ArgumentError.value(
          field.name,
          'schema.fields',
          'is reserved by flutter_gemma_rag_qdrant for the stored document '
              'id/content/metadata — choose another field name',
        );
      }
    }
    _filterSchema = schema;
  }

  @override
  Future<void> initialize(String databasePath) =>
      _serializeLifecycle(() => _initialize(databasePath));

  Future<void> _initialize(String databasePath) async {
    // Re-init is allowed and matches the DartVectorStoreRepository contract:
    // close any prior shard, then arm the new path. Dimension is detected
    // lazily on the first addDocument so we don't have to commit to one
    // before we've seen an embedding.
    final existing = _client;
    if (existing != null) {
      try {
        await existing.close();
      } on QdrantException catch (e) {
        gemmaLog('[QdrantVectorStore] close() failed (best-effort): $e');
      }
    }
    _client = null;
    _dim = null;
    _unusableReason = null;
    _generation++;
    _databasePath = databasePath;

    // Adopt an existing shard NOW rather than on the first write. Opening
    // lazily meant a store re-opened after an app restart reported zero
    // documents and no search hits until something happened to write to it —
    // and a removeDocument() issued before that first write was dropped with
    // only a log line. The dimension comes from the shard itself, so we do not
    // need an embedding in hand to do this.
    final gen = _generation;
    final storeDir = _storeDirFor(databasePath);

    // Detect the 1.x layout HERE, not on the first write. Checking it only in
    // _ensureClient meant a read-only session — open the app, ask a question —
    // never reached the check: initialize() succeeded, searchSimilar returned
    // no hits, and the model answered without the corpus that was sitting on
    // disk the whole time. Only a write complained.
    //
    // Order matters: `_databasePath` is already armed above, so the clear()
    // this message prescribes is reachable. Throwing before that would leave
    // the caller holding a store that refuses the remedy it just recommended.
    // Latch BEFORE throwing. A caller that catches this and carries on, or any
    // other code path that reads, must not be told the store is empty.
    try {
      _refuseIfNotOurs(databasePath, storeDir);
    } on VectorStoreException catch (e) {
      _unusableReason = e.message;
      rethrow;
    }

    try {
      final opened = await QdrantEdgeClient.openExisting(path: storeDir);
      if (opened == null) return;
      if (_generation != gen) {
        // initialize()/clear()/close() ran while we were opening.
        try {
          await opened.client.close();
        } catch (_) {
          // Best-effort, and bounded: a shard we cannot close keeps its WAL
          // lock for the process lifetime, but the next open reports that
          // loudly (WouldBlock -> latched) rather than answering "empty".
          // Nothing here can act on the cause, and the store we are unwinding
          // from is not the one the caller now owns.
        }
        return;
      }
      _client = opened.client;
      _dim = opened.dim;
      _unusableReason = null;
    } on QdrantException catch (e) {
      // Belt-and-suspenders, and honestly so: with lifecycle transitions
      // serialized, nothing can bump `_generation` while this method is
      // suspended, so this check is unreachable today — a mutation removing it
      // kills no test, because no test CAN reach it. It stays because it costs
      // one line and is the correct behaviour if the lane is ever bypassed;
      // the property it protects (a failure for the old path must not latch a
      // store since armed at a new one) is pinned by an outcome test instead.
      if (_generation != gen) return;
      // An earlier version of this comment said the failure was not fatal here
      // because the write path would retry "with the dimension the caller
      // intends". That was wrong: openExisting passes no dim at all
      // (`EdgeShard.load(path, config: null)`), so a dimension mismatch cannot
      // be why it failed. What can: an exclusive WAL held elsewhere, a
      // corrupted config, permissions. None of those are resolved by a write,
      // so a write must not paper over them either — addDocument asserts the
      // latch too. gemmaLog alone would not do: it is debug-only, so in a
      // release build nobody is told at all.
      // Two different situations, two different things to tell the caller.
      // They arrived as one generic error until the SDK gave the lock its own
      // type — and conflating "someone else has it open" with "this data is
      // damaged" is how a recovery step written for the second once ran
      // against the first.
      _unusableReason = e is QdrantShardLockedException
          ? 'The qdrant shard at $storeDir is open elsewhere, so this store '
                'cannot read it — and reporting no results would hide an '
                'intact corpus. Close the other store (or wait for it), then '
                'call initialize() again. Underlying error: $e'
          : 'A qdrant shard exists at $storeDir but could not be opened, so '
                'this store cannot tell you whether it is empty — reporting no '
                'results would hide an intact corpus. Call initialize() again '
                'once the cause is cleared. Underlying error: $e';
      gemmaLog('[QdrantVectorStore] could not adopt existing shard: $e');
      // And REPORT it. The contract says initialize() throws
      // VectorStoreException when initialization fails, and this failed: a
      // shard is on disk and we could not open it. Returning normally left the
      // caller believing the store was ready while `isInitialized` said false
      // and every read refused — the failure surfacing later, somewhere else,
      // as a surprise.
      throw VectorStoreException(_unusableReason!);
    }
  }

  /// The owned, format-scoped shard directory for [databasePath] — the only
  /// path this store ever opens or deletes. Never the bare [databasePath]
  /// itself.
  static String _storeDirFor(String databasePath) =>
      p.join(databasePath, _storeDirName);

  /// Entries a 1.x store (crate 0.7.x) wrote DIRECTLY at [_databasePath],
  /// before this package owned a format-scoped subdirectory. `edge_config.json`
  /// is the marker; `wal` and `segments` are the payload.
  static const _legacyEntries = ['edge_config.json', 'wal', 'segments'];

  /// Refuses to run over anything at the bare [databasePath] this release
  /// cannot open, choosing BOTH the exception type and the message from a
  /// single probe.
  ///
  /// The type matters as much as the text. [QdrantLegacyStoreException] means
  /// "this is a 1.x store, here are the files to remove" — the README tells
  /// callers to catch it and act on the message. Throwing it for data we could
  /// NOT identify would hand that destructive instruction to someone whose own
  /// files happen to share those names, which is the defect this package has
  /// closed twice already and must not reopen through the exception type.
  /// `existsSync` is not total: dart:io throws `FileSystemException` when the
  /// stat itself fails (EACCES/EBADF/ENOMEM/EOVERFLOW) and returns false only
  /// for ENOENT/ENOTDIR/ELOOP. An iOS container before first unlock, or Android
  /// scoped storage after a permission change, lands in the first group — and a
  /// raw FileSystemException out of initialize() is outside the contract the
  /// caller was told to handle.
  ///
  /// "I could not look" is not "there is nothing there": this release's thesis,
  /// one layer down.
  static bool _existsOrThrow(FileSystemEntity entity, String what) {
    try {
      return entity.existsSync();
    } on FileSystemException catch (e) {
      throw VectorStoreException(
        'Cannot determine whether $what exists at "${entity.path}", so this '
        'store will not guess that it is absent: $e',
      );
    }
  }

  /// Records why a shard that EXISTS could not be opened, so a later read
  /// refuses instead of answering "empty".
  ///
  /// initialize() did this and the other three open sites did not, which left
  /// exactly the asymmetry the latch exists to remove: the same fact — a shard
  /// is here and we could not read it — was loud when a read found it and
  /// silent when a write did.
  void _latchOpenFailure(String storeDir, Object cause) {
    // Nothing on disk means nothing is being hidden; a cold store that simply
    // failed to create its shard must not be latched.
    if (!Directory(storeDir).existsSync()) return;
    _unusableReason = cause is QdrantShardLockedException
        ? 'The qdrant shard at $storeDir is open elsewhere, so this store '
              'cannot read it — and reporting no results would hide an intact '
              'corpus. Close the other store (or wait for it), then call '
              'initialize() again. Underlying error: $cause'
        : 'A qdrant shard exists at $storeDir but could not be opened, so this '
              'store cannot tell you whether it is empty — reporting no '
              'results would hide an intact corpus. Call initialize() again '
              'once the cause is cleared. Underlying error: $cause';
  }

  static void _refuseIfNotOurs(String databasePath, String storeDir) {
    if (_existsOrThrow(Directory(storeDir), 'the qdrant shard')) return;
    switch (_whatIsAt(databasePath)) {
      case _AtPath.nothingOfOurs:
        return;
      case _AtPath.legacyStore:
        throw QdrantLegacyStoreException(
          'Found a store written by flutter_gemma_rag_qdrant 1.x at '
          '$databasePath. Its on-disk format is not readable by 2.0, and this '
          'release never deletes files it cannot read: remove '
          '"${_legacyEntries.join('", "')}" from that directory yourself, then '
          're-index. Anything else you keep there is left alone.',
        );
      case _AtPath.somethingElse:
        // Deliberately not the legacy type, and deliberately naming no files:
        // we could not identify this data, so we must not tell anyone to
        // delete it.
        throw VectorStoreException(
          'The directory $databasePath already holds an '
          '"${_legacyEntries.first}" that this package did not write, beside '
          'files named "${_legacyEntries.skip(1).join('", "')}". This store '
          'will not open over it. Point initialize() at a subdirectory of its '
          'own, or move those files aside — do not assume they are ours.',
        );
    }
  }

  /// True when [databasePath] holds a shard written by 1.x. Such a store is
  /// invisible to this release — 2.0 only ever opens the owned subdir — so
  /// without this check the app comes up with an empty index, no error, and
  /// the old corpus still occupying disk.
  /// What sits at the bare [databasePath], for the purpose of what to TELL the
  /// caller.
  ///
  /// It stopped gating a delete when clear() stopped deleting — but the
  /// distinction survives, because the remedy is now an instruction and an
  /// instruction can destroy data just as well as a `deleteSync` can. Telling
  /// someone to remove `edge_config.json`, `wal/` and `segments/` is correct
  /// for a 1.x store and catastrophic for a caller who happens to keep files
  /// by those names. So we only say it when the marker is a shard config THIS
  /// package wrote: `{"vectors":{"":{…}}}` — the unnamed vector field is the
  /// signature. Anything else readable gets a message that names no files.
  ///
  /// A marker we cannot read counts as present: refusing costs one manual
  /// look, while missing a real 1.x store costs a silently empty index over an
  /// intact corpus, which is what this release exists to prevent.
  static _AtPath _whatIsAt(String databasePath) {
    final marker = File(p.join(databasePath, _legacyEntries.first));
    if (!_existsOrThrow(marker, 'a 1.x shard config')) {
      return _AtPath.nothingOfOurs;
    }
    final hasPayload = _legacyEntries.skip(1).any((name) {
      final at = p.join(databasePath, name);
      return _existsOrThrow(Directory(at), 'a 1.x shard entry') ||
          _existsOrThrow(File(at), 'a 1.x shard entry');
    });
    // A lone marker is a leftover, not a store.
    if (!hasPayload) return _AtPath.nothingOfOurs;
    try {
      final decoded = jsonDecode(marker.readAsStringSync());
      if (decoded is! Map) return _AtPath.nothingOfOurs;
      final vectors = decoded['vectors'];
      return vectors is Map && vectors.containsKey('')
          ? _AtPath.legacyStore
          : _AtPath.somethingElse;
    } on FormatException {
      return _AtPath.nothingOfOurs;
    } on FileSystemException {
      return _AtPath.somethingElse;
    }
  }

  /// Two refusals, one place.
  ///
  /// [VectorStoreRepository] documents `StateError` for an uninitialized store
  /// on addDocument/searchSimilar/getStats/removeDocument (and clear(), which
  /// raises it directly — it must stay callable on a LATCHED store, because
  /// clearing is the remedy). This one returned empty results instead, so the
  /// same misuse was loud in the sibling sqlite store and invisible here.
  ///
  /// The second refusal is the latch: armed, but holding data it cannot read.
  void _assertUsable(String operation) {
    final databasePath = _databasePath;
    if (databasePath == null) {
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }
    final reason = _unusableReason;
    if (reason != null) {
      throw VectorStoreException('$operation refused. $reason');
    }
  }

  Future<QdrantEdgeClient> _ensureClient({required int dim}) async {
    final databasePath = _databasePath;
    if (databasePath == null) {
      throw const VectorStoreException(
        'Vector store not initialized — call initialize(path) first.',
      );
    }
    final existing = _client;
    if (existing != null) {
      if (_dim != dim) {
        throw ArgumentError(
          'Embedding dimension mismatch: this shard stores $_dim-dimensional '
          'vectors and was given one of length $dim. qdrant bakes the vector '
          'size into the shard, so clear() cannot change it — switching '
          'embedding models means removing '
          '"${_storeDirFor(_databasePath ?? '<databasePath>')}" and '
          're-indexing.',
        );
      }
      return existing;
    }

    // Someone else is already opening this store — join them instead of racing
    // for the WAL lock.
    final inFlight = _opening;
    if (inFlight != null) {
      // Everything the leader gets, the joiner must get too. Three ways this
      // used to differ, all reachable from the one call the doc above names as
      // the obvious way to index a corpus — Future.wait over addDocument:
      //
      //   * the leader's failure was wrapped into VectorStoreException at the
      //     bottom of this method; the joiner's await sat OUTSIDE that try, so
      //     joiners received a raw QdrantException — a type this package does
      //     not export, so `on VectorStoreException` (the documented contract)
      //     missed every one of them;
      //   * the joiner had no generation check, so a store re-initialized
      //     mid-open handed it a client bound to the previous path;
      //   * with _dim nulled by that transition, the dim comparison below
      //     reported "shard was opened with dim=null" — blaming the caller's
      //     vector for a lifecycle event.
      final gen = _generation;
      final QdrantEdgeClient c;
      try {
        c = await inFlight;
      } on QdrantException catch (e) {
        _latchOpenFailure(_storeDirFor(databasePath), e);
        throw VectorStoreException(
          'Failed to open qdrant shard at ${_storeDirFor(databasePath)}',
          e,
        );
      }
      if (_generation != gen) {
        throw const VectorStoreException(
          'Vector store was re-initialized or closed while opening — '
          'retry the operation.',
        );
      }
      if (_dim != dim) {
        throw ArgumentError(
          'Embedding dimension mismatch: this shard stores $_dim-dimensional '
          'vectors and was given one of length $dim. qdrant bakes the vector '
          'size into the shard, so clear() cannot change it — switching '
          'embedding models means removing '
          '"${_storeDirFor(_databasePath ?? '<databasePath>')}" and '
          're-indexing.',
        );
      }
      return c;
    }
    // First open. The store owns `<databasePath>/qdrant_edge_v1` — created
    // recursively — and never opens the bare databasePath itself, so a
    // pre-existing (e.g. legacy) directory or file sitting directly at
    // databasePath is left untouched.
    final storeDir = _storeDirFor(databasePath);
    // A 1.x store sits directly at databasePath and this release never opens
    // it. Left undetected the app starts with an empty index, reports no
    // error, and answers without context while the old corpus still occupies
    // disk — so refuse loudly instead, and say what actually clears it.
    // Latch here too. initialize()'s copy does, and a store that reaches this
    // one first — a write before any read — must end up in the same state, or
    // the next read answers "empty" over the 1.x corpus.
    try {
      _refuseIfNotOurs(databasePath, storeDir);
    } on VectorStoreException catch (e) {
      _unusableReason = e.message;
      rethrow;
    }
    try {
      Directory(storeDir).createSync(recursive: true);
    } on FileSystemException catch (e) {
      throw VectorStoreException(
        'Failed to create qdrant shard directory at $storeDir: $e',
      );
    }
    final gen = _generation;
    try {
      final future = QdrantEdgeClient.open(
        path: storeDir,
        dim: dim,
        distance: _distance,
      );
      _opening = future;
      final QdrantEdgeClient c;
      try {
        c = await future;
      } finally {
        if (identical(_opening, future)) _opening = null;
      }
      if (_generation != gen) {
        // initialize()/clear()/close() ran while we were opening. Installing
        // this client now would either resurrect a store the caller closed —
        // keeping its WAL lock until the process exits — or bind `_client` to
        // the old path under a new `_databasePath`. Hand the shard back
        // instead, and let the caller retry against the current state.
        try {
          await c.close();
        } catch (_) {
          // Best-effort: we are already unwinding.
        }
        throw const VectorStoreException(
          'Vector store was re-initialized or closed while opening — '
          'retry the operation.',
        );
      }
      _client = c;
      _dim = dim;
      _unusableReason = null;
      return c;
    } on QdrantException catch (e) {
      // Wrap and rethrow — never auto-rename/delete/rebuild. Whether the
      // failure is transient (permissions, lock, missing native lib, I/O) or
      // a real format incompatibility, it surfaces the same safe way: thrown,
      // data untouched.
      // Say what failed, not what to delete. Most causes here are transient
      // or a plain caller error — a concurrent open, a lock still held by a
      // client that was not closed, a changed embedding dimension — and only
      // the last is corruption. Blanket "clear and re-index" advice told users
      // to destroy a working index to fix a lock.
      _latchOpenFailure(storeDir, e);
      throw VectorStoreException('Failed to open qdrant shard at $storeDir', e);
    }
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    // A shard we could not read is not a shard we may write into: appending to
    // it would merge into a corpus this store just refused to report, and the
    // successful open would clear the latch — erasing the only signal the user
    // ever gets.
    _assertUsable('addDocument');
    final c = await _ensureClient(dim: embedding.length);
    final payload = <String, dynamic>{
      _userIdKey: id,
      _contentKey: content,
      _metadataKey: ?metadata,
    };
    // Filter-field promotion: only when a schema is declared AND metadata is
    // present. Without a schema this branch never runs, so existing callers
    // get byte-identical payloads (the opaque blob under _metadataKey only).
    // With a schema, expand each DECLARED field to a top-level payload key so
    // FilterCodec's top-level-key predicates actually match.
    if (!_filterSchema.isEmpty && metadata != null) {
      _promoteFilterFields(payload, metadata);
    }
    try {
      await c.upsert(
        id: PointIdHasher.hash(id),
        vector: embedding,
        payload: payload,
      );
    } on QdrantException catch (e) {
      throw VectorStoreException('addDocument failed for id=$id', e);
    }
  }

  /// Expands the declared [FilterField]s out of the raw [metadata] JSON into
  /// top-level [payload] keys (in addition to the opaque [_metadataKey] blob).
  ///
  /// Defensive by design — promotion must never break an `addDocument` that
  /// would otherwise succeed:
  /// * non-object or unparseable [metadata] → logged, left as the opaque blob;
  /// * a declared field absent from the metadata → skipped (no key written),
  ///   so a [Filter] on it matches nothing (documented no-op, never a throw).
  void _promoteFilterFields(Map<String, dynamic> payload, String metadata) {
    Object? decoded;
    try {
      decoded = jsonDecode(metadata);
    } on FormatException catch (e) {
      gemmaLog(
        '[QdrantVectorStore] metadata is not valid JSON — filter fields not '
        'promoted (round-trip blob kept): $e',
      );
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      gemmaLog(
        '[QdrantVectorStore] metadata JSON is not an object — filter fields '
        'not promoted (round-trip blob kept)',
      );
      return;
    }
    for (final field in _filterSchema.fields) {
      if (decoded.containsKey(field.name)) {
        payload[field.name] = decoded[field.name];
      }
    }
  }

  @override
  Future<void> removeDocument({required String id}) async {
    _assertUsable('removeDocument');
    final c = _client;
    // Initialized, no shard on disk: deleting from an empty store is the
    // documented no-op. Reachable only when nothing was ever written.
    if (c == null) return;
    try {
      await c.delete([PointIdHasher.hash(id)]);
    } on QdrantException catch (e) {
      throw VectorStoreException('removeDocument failed for id=$id', e);
    }
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    _assertUsable('searchSimilar');
    final c = _client;
    if (c == null || _dim == null) {
      // No documents yet — nothing to retrieve. Genuinely empty: _assertUsable
      // has already ruled out "uninitialized" and "on disk but unreadable".
      return const [];
    }
    if (queryEmbedding.length != _dim) {
      throw ArgumentError(
        'Query embedding dimension ${queryEmbedding.length} does not '
        'match stored dimension $_dim',
      );
    }
    final filterJson = FilterCodec.encode(filter, _filterSchema);
    final List<SearchHit> hits;
    try {
      hits = await c.search(
        queryVector: queryEmbedding,
        topK: topK,
        filterJson: filterJson,
      );
    } on QdrantException catch (e) {
      throw VectorStoreException('searchSimilar failed', e);
    }
    return [
      for (final hit in hits)
        if (hit.score >= threshold)
          RetrievalResult(
            id: hit.payload?[_userIdKey] as String? ?? hit.id,
            content: hit.payload?[_contentKey] as String? ?? '',
            similarity: hit.score,
            metadata: hit.payload?[_metadataKey] as String?,
          ),
    ];
  }

  @override
  Future<VectorStoreStats> getStats() async {
    _assertUsable('getStats');
    final c = _client;
    if (c == null) {
      return VectorStoreStats(documentCount: 0, vectorDimension: 0);
    }
    final int n;
    try {
      n = await c.count();
    } on QdrantException catch (e) {
      throw VectorStoreException('getStats failed', e);
    }
    return VectorStoreStats(documentCount: n, vectorDimension: _dim ?? 0);
  }

  @override
  Future<void> clear() => _serializeLifecycle(_clear);

  Future<void> _clear() async {
    final databasePath = _databasePath;
    if (databasePath == null) {
      // The contract documents StateError here, and the sibling sqlite store
      // throws it. Returning silently made "I cleared the store" and "I was
      // never given a path" the same observable outcome.
      throw StateError('VectorStore not initialized. Call initialize() first.');
    }

    // Erase the documents, not the directory.
    //
    // Every destructive path this class used to carry — deleting the owned
    // subdirectory, the canonicalized boundary guard against a symlink escape,
    // the sweep over a 1.x layout, the marker-last ordering, the partial-sweep
    // report, a fault-injection seam that could silently skip a delete — grew
    // out of one sentence carried forward from the old Rust shim without ever
    // being rechecked against the SDK that replaced it: "qdrant-edge has no
    // truncate primitive".
    //
    // It has one. `deletePointsByFilter` with an empty filter matches every
    // point. Measured: 2 in, 0 after, directory intact, store still writable
    // and re-openable. So clear() no longer closes the client, no longer
    // touches the filesystem, and cannot delete anything that is not a point
    // it wrote — which retires the whole class of bug that reached a caller's
    // own `wal/` and `segments/` twice, and an intact 2.0 corpus once.
    // Same refusal, same helper, same choice of type. This branch used to
    // carry its OWN hardcoded copy of the message — which meant the
    // "delete these three files" instruction went to every caller the guard
    // fired for, including the ones whose data we had just admitted we could
    // not identify.
    _refuseIfNotOurs(databasePath, _storeDirFor(databasePath));

    try {
      final open = _client;
      if (open != null) {
        await open.deleteAll();
        return;
      }
      // NOTE on the dimension: the contract says clear() "resets dimension
      // (next add will auto-detect again)", and the sqlite sibling does. This
      // store cannot, and it is not an oversight — qdrant bakes the vector size
      // into the shard's segments, so an emptied shard still refuses a vector
      // of a different length ("expected vector size 8, but got 4", measured).
      // Resetting it would mean recreating the shard, i.e. deleting the
      // directory, which is the thing this release removed. The mismatch is
      // reported by _ensureClient with a message naming the way out.
      // Nothing adopted yet. Do not go through _ensureClient — it takes a
      // dimension, and inventing one here would CREATE a shard in order to
      // report it empty.
      final storeDir = _storeDirFor(databasePath);
      if (!Directory(storeDir).existsSync()) return; // never written to
      final opened = await QdrantEdgeClient.openExisting(path: storeDir);
      if (opened == null) return; // a directory, but no shard in it
      _client = opened.client;
      _dim = opened.dim;
      _unusableReason = null;
      await opened.client.deleteAll();
    } on QdrantException catch (e) {
      _latchOpenFailure(_storeDirFor(databasePath), e);
      throw VectorStoreException('Failed to clear the qdrant shard', e);
    }
  }

  @override
  Future<void> flush() => _serializeLifecycle(_flush);

  Future<void> _flush() async {
    // On the lifecycle lane, not beside it: a flush that overlapped a close
    // would reach a shard the other call had already unloaded.
    //
    // No client means nothing was written through this store, so there is
    // nothing to persist — including the case where an earlier open failed.
    // Callers flush from lifecycle callbacks they cannot make conditional
    // (`didChangeAppLifecycleState` and the like), so "not initialized" has to
    // be quiet rather than an exception nobody can act on.
    final c = _client;
    if (c == null) return;
    try {
      await c.flush();
    } on QdrantException catch (e) {
      // Translated, like every other method on this class. `QdrantException`
      // is not a `VectorStoreException` and is not exported from the barrel,
      // so letting it out would hand the caller a type they cannot name — and
      // `on VectorStoreException`, the catch the contract tells them to write,
      // would miss every flush failure.
      throw VectorStoreException(
        'Failed to flush the qdrant shard: ${e.message}',
        e,
      );
    }
  }

  @override
  Future<void> close() => _serializeLifecycle(_close);

  Future<void> _close() async {
    final c = _client;
    _client = null;
    _dim = null;
    _unusableReason = null;
    _generation++;
    _databasePath = null;
    if (c != null) {
      try {
        await c.close();
      } on QdrantException catch (e) {
        gemmaLog('[QdrantVectorStore] close() failed (best-effort): $e');
      }
    }
  }
}

/// What [QdrantVectorStore._whatIsAt] found at the bare `databasePath`.
///
/// Only [legacyStore] earns an instruction that names files to delete.
enum _AtPath { nothingOfOurs, legacyStore, somethingElse }
