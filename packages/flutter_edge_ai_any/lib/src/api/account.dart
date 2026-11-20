part of 'any_sync.dart';

/// One any-sync account on this device: its SDK instance, its local index
/// files, and every location this process opened in it (design §1, §4).
///
/// Runs on three isolates of its own (SDK, index, events); nothing here
/// blocks the caller's isolate. Open it once per data directory per process.
@experimental
final class AnySyncAccount {
  AnySyncAccount._(
    this._native,
    this._rt,
    this._options,
    this._dataDirectory,
    this._indexDirectory,
    this._keyHex,
    this._spaceOpenWait,
    this._previousInstanceWait,
  );

  final AnyNative _native;
  final AnyRuntime _rt;
  final Map<String, Object?> _options;
  final String _dataDirectory;
  final String _indexDirectory;
  final String? _keyHex;
  final Duration _spaceOpenWait;
  final Duration _previousInstanceWait;

  int? _handle;
  AnySyncAccountState _state = AnySyncAccountState.open;
  final _lifecycle = _Mutex();

  /// Bumped by suspend and close: an SDK call that fails with "closed"
  /// across a bump was cancelled by it.
  int _epoch = 0;

  final _cores = <String, _LocationCore>{};
  final _coreOpens = <String, Future<_LocationCore>>{};
  final _closingCores = <String, Future<void>>{};
  final _watched = <String>{};
  final _status = StreamController<AnySyncStatus>.broadcast();
  StreamSubscription<Map<String, Object?>>? _events;

  /// Data and index directories open in this isolate.
  static final _openDataDirs = <String>{};
  static final _openIndexDirs = <String>{};

  /// A new 12-word BIP-39 mnemonic. Persisting it is the app's job
  /// (Keychain / Keystore).
  static Future<String> newMnemonic() => _nativeLayer().newMnemonic();

  /// A new device key, hex. One per install; store it "this device only":
  /// a restored key is a second writer.
  static Future<String> newDeviceKey() => _nativeLayer().newDeviceKey();

  /// Opens the account.
  ///
  /// [indexDirectory] holds the local index files of every location (derived
  /// data: deleting it costs a re-download, never data); one per account.
  /// [localEncryptionKey] (exactly 32 bytes) encrypts those files.
  /// [spaceOpenWait] bounds how long opening a location waits for its space
  /// to load. [previousInstanceWait] bounds the wait for a previous instance
  /// (a hot restart) to let go of the directories.
  ///
  /// Throws [UnsupportedError] on the web, [ArgumentError] for a key of
  /// another length, [AnySyncBusyException] when the directories are held.
  static Future<AnySyncAccount> open({
    required String dataDirectory,
    required String indexDirectory,
    required String mnemonic,
    required String deviceKey,
    required String nodeConfYaml,
    Uint8List? localEncryptionKey,
    AnySyncP2p p2p = const AnySyncP2p.lan(),
    Duration spaceOpenWait = const Duration(seconds: 10),
    Duration previousInstanceWait = const Duration(seconds: 15),
  }) async {
    final native = _nativeLayer();
    if (!native.supported) {
      throw UnsupportedError(
        'flutter_edge_ai_any has no web implementation: any-sync needs '
        'native transports and storage.',
      );
    }
    if (localEncryptionKey != null && localEncryptionKey.length != 32) {
      throw ArgumentError.value(
        localEncryptionKey.length,
        'localEncryptionKey',
        'must be exactly 32 bytes',
      );
    }
    final data = absolutePath(dataDirectory);
    final index = absolutePath(indexDirectory);
    if (data == index) {
      throw ArgumentError.value(
        indexDirectory,
        'indexDirectory',
        'must differ from dataDirectory',
      );
    }
    if (_openDataDirs.contains(data) || _openIndexDirs.contains(index)) {
      throw AnySyncBusyException._(
        AnySyncBusyReason.alreadyOpenInProcess,
        'an account on $data or $index is already open in this process',
      );
    }
    ensureDirectory(data);
    ensureDirectory(index);
    final options = <String, Object?>{
      'dataDir': data,
      'indexDir': index,
      'ownerToken': ownerToken(),
      'mnemonic': mnemonic,
      'deviceKeyHex': deviceKey,
      'nodeConfYaml': nodeConfYaml,
      'p2p': p2p._toJson(),
    };
    _openDataDirs.add(data);
    _openIndexDirs.add(index);
    final AnyRuntime rt;
    try {
      rt = await native.start();
    } catch (_) {
      _openDataDirs.remove(data);
      _openIndexDirs.remove(index);
      rethrow;
    }
    final account = AnySyncAccount._(
      native,
      rt,
      options,
      data,
      index,
      localEncryptionKey == null ? null : _hex(localEncryptionKey),
      spaceOpenWait,
      previousInstanceWait,
    );
    try {
      await account._openNative();
    } catch (_) {
      _openDataDirs.remove(data);
      _openIndexDirs.remove(index);
      account._state = AnySyncAccountState.closed;
      await rt.dispose();
      rethrow;
    }
    return account;
  }

  static String _hex(Uint8List b) =>
      [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  Future<void> _openNative() async {
    final handle = await _retryBusy(
      'the account directory',
      () => _rt.sdk(openAccountJob(_options)),
      refusedMeansHeld: false,
    );
    _handle = handle;
    _rt.attachAccount(this, handle);
    _startEvents(handle);
  }

  /// Runs [open], retrying while native says busy, up to
  /// previousInstanceWait (design §4.3, owner token).
  ///
  /// Native answers REFUSED for a directory or file this isolate group
  /// already holds (the same owner token): that is
  /// [AnySyncBusyReason.alreadyOpenInProcess], not worth a retry. The
  /// account open also refuses the production network with REFUSED, so
  /// there only a message naming an open counts.
  Future<T> _retryBusy<T>(
    String what,
    Future<T> Function() open, {
    required bool refusedMeansHeld,
  }) async {
    final deadline = DateTime.now().add(_previousInstanceWait);
    while (true) {
      try {
        return await open();
      } on AnyShimException catch (e) {
        if (e.status == AnyShimStatus.refused &&
            (refusedMeansHeld || e.message.contains('already open'))) {
          throw AnySyncBusyException._(
            AnySyncBusyReason.alreadyOpenInProcess,
            '$what: ${e.message}',
            cause: e,
          );
        }
        if (e.status != AnyShimStatus.busy) throw _mapShim(e);
        if (DateTime.now().isAfter(deadline)) {
          throw AnySyncBusyException._(
            _busyReason(e),
            '$what is still held after ${_previousInstanceWait.inSeconds} s: '
            '${e.message}',
            cause: e,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// The time this account allocates revs with (a test may skew it).
  int _nowMs() =>
      DateTime.now().millisecondsSinceEpoch +
      (debugAccountClockSkewMs[_dataDirectory] ?? 0);

  void _startEvents(int handle) {
    _events = _rt
        .events(handle)
        .listen(
          _onEvent,
          // The poller gave up after repeated failures: say so on the
          // followers' status, and start a new one (D2).
          onError: (Object e) => _eventsFailed(handle, e),
          onDone: () => _eventsFailed(handle, null),
        );
    _rt.sdk(watchSyncStatusJob()).ignore();
    _watched.clear();
    for (final core in _cores.values) {
      _watch(core.location.spaceId);
    }
  }

  void _eventsFailed(int handle, Object? error) {
    if (_handle != handle || _state == AnySyncAccountState.closed) return;
    if (error != null) {
      for (final core in _cores.values) {
        core.lastFollowerError = 'events: $error';
        core.lastFollowerErrorAt = DateTime.now();
        _emitFollower(core);
      }
    }
    Timer(const Duration(seconds: 1), () {
      if (_handle != handle || _state != AnySyncAccountState.open) return;
      _events?.cancel();
      _startEvents(handle);
      for (final core in _cores.values) {
        core.onChange();
      }
    });
  }

  /// A change watch for [spaceId]; a failed one is retried at the next
  /// sync status event (D2). Needs the native account, not the open state,
  /// so resume can register them before it reports open (D4).
  void _watch(String spaceId) {
    if (_handle == null || _state == AnySyncAccountState.closed) return;
    if (!_watched.add(spaceId)) return;
    _rt.sdk(watchChangesJob(spaceId)).catchError((Object _) {
      _watched.remove(spaceId);
      return 0;
    });
  }

  /// Reports a follower's error (or its recovery) on statusChanges.
  void _emitFollower(_LocationCore core) {
    if (_status.isClosed) return;
    _status.add(
      AnySyncStatus._follower(
        core.location,
        core.lastFollowerError,
        core.lastFollowerErrorAt,
      ),
    );
  }

  void _onEvent(Map<String, Object?> e) {
    switch (e['kind']) {
      case 'syncStatus':
        if (!_status.isClosed) _status.add(AnySyncStatus._fromJson(e));
        for (final core in _cores.values) {
          _watch(core.location.spaceId);
        }
        // A completed sync can carry changes the feed already announced
        // while the space was loading; let the followers look.
        for (final core in _cores.values) {
          if (core.location.spaceId == e['spaceId']) core.onChange();
        }
      case 'change':
        for (final core in _cores.values) {
          if (core.location.spaceId == e['spaceId']) core.onChange();
        }
      case 'overflow':
        for (final core in _cores.values) {
          core.onChange();
        }
    }
  }

  // ---------------------------------------------------------- the calls

  void _checkOpen() {
    switch (_state) {
      case AnySyncAccountState.open:
        return;
      case AnySyncAccountState.suspended:
        throw const AnySyncSuspendedException._();
      case AnySyncAccountState.closed:
        throw const AnySyncClosedException._();
    }
  }

  /// Runs an SDK job, mapping native errors to this package's exceptions.
  Future<T> _sdk<T>(SdkJob<T> job, {String? spaceId}) async {
    _checkOpen();
    final epoch = _epoch;
    try {
      return await _rt.sdk(job);
    } on AnyShimException catch (e, st) {
      if (e.status == AnyShimStatus.closed && epoch != _epoch) {
        _checkOpen();
        Error.throwWithStackTrace(const AnySyncSuspendedException._(), st);
      }
      Error.throwWithStackTrace(_mapShim(e, spaceId: spaceId), st);
    }
  }

  /// Runs an index job; the index isolate outlives suspend.
  Future<T> _index<T>(IndexJob<T> job, {String? spaceId}) async {
    try {
      return await _rt.index(job);
    } on AnyShimException catch (e, st) {
      Error.throwWithStackTrace(_mapShim(e, spaceId: spaceId, index: true), st);
    } on ClockExhausted catch (_, st) {
      Error.throwWithStackTrace(const AnySyncClockExhaustedException._(), st);
    }
  }

  /// Native status → this package's exception. [index]: the call was on
  /// a local index, the only place `AnySyncLocalIndexException` fits (D15);
  /// the account's own state failing is a plain [AnySyncException].
  Object _mapShim(AnyShimException e, {String? spaceId, bool index = false}) {
    if (!index &&
        (e.status == AnyShimStatus.io ||
            e.status == AnyShimStatus.corrupt ||
            e.status == AnyShimStatus.keyMismatch ||
            e.status == AnyShimStatus.keyMissing)) {
      return AnySyncException(
        '${e.operation}: ${e.message}',
        retryable: e.status == AnyShimStatus.io,
        cause: e,
      );
    }
    switch (e.status) {
      case AnyShimStatus.closed:
        return _state == AnySyncAccountState.suspended
            ? const AnySyncSuspendedException._()
            : (_state == AnySyncAccountState.closed
                  ? const AnySyncClosedException._()
                  : AnySyncException(e.message, retryable: false, cause: e));
      case AnyShimStatus.pending:
        return AnySyncNotReadyException._(
          spaceId ?? '',
          AnySyncNotReadyReason.loading,
        );
      case AnyShimStatus.busy:
        return AnySyncBusyException._(_busyReason(e), e.message, cause: e);
      case AnyShimStatus.keyMismatch:
        return AnySyncLocalIndexException._(
          AnySyncLocalIndexErrorKind.keyMismatch,
          e.message,
        );
      case AnyShimStatus.corrupt:
        return AnySyncLocalIndexException._(
          AnySyncLocalIndexErrorKind.corrupt,
          e.message,
        );
      case AnyShimStatus.keyMissing:
        return AnySyncLocalIndexException._(
          AnySyncLocalIndexErrorKind.keyMissing,
          e.message,
        );
      case AnyShimStatus.io:
        return AnySyncLocalIndexException._(
          AnySyncLocalIndexErrorKind.io,
          e.message,
        );
      case AnyShimStatus.refused when e.message.contains('read-only'):
        return AnySyncReadOnlyException._(e.message);
      case AnyShimStatus.timeout:
        return AnySyncException(e.message, retryable: true, cause: e);
      default:
        return AnySyncException(
          '${e.operation}: ${e.message}',
          retryable: false,
          cause: e,
        );
    }
  }

  /// BUSY says which in its message only: a lock another process holds, or
  /// a previous owner (a hot restart) still holding or closing.
  static AnySyncBusyReason _busyReason(AnyShimException e) =>
      e.message.contains('another process')
      ? AnySyncBusyReason.lockedByAnotherProcess
      : AnySyncBusyReason.previousInstanceClosing;

  /// Creates a space; this device is recorded as its creator.
  Future<AnySyncSpace> createSpace(String name) async {
    final r = await _sdk(spaceCreateJob(name));
    return AnySyncSpace._(r['id']! as String, name);
  }

  /// The spaces this account knows; with [sync], after asking reachable
  /// peers (bounded by [timeout]).
  Future<AnySyncSpaceList> spaces({
    bool sync = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final r = sync
        ? await _sdk(spaceListSyncJob(_ms(timeout)))
        : await _sdk(spaceListJob());
    return AnySyncSpaceList._(
      [
        for (final s in (r['spaces'] as List? ?? const []))
          AnySyncSpace._(
            (s as Map)['id']! as String,
            (s['name'] as String?) ?? '',
          ),
      ],
      r['syncError'] as String?,
      r['timedOut'] == true,
    );
  }

  static int _ms(Duration d) {
    if (d <= Duration.zero) {
      throw ArgumentError.value(d, 'timeout', 'must be positive');
    }
    final ms = d.inMilliseconds;
    return ms > 0x7fffffff ? 0x7fffffff : ms;
  }

  /// One space's sync status.
  Future<AnySyncStatus> spaceStatus(String spaceId) async {
    try {
      return AnySyncStatus._fromJson(
        await _sdk(spaceStatusJob(spaceId), spaceId: spaceId),
      );
    } on AnySyncException catch (e) {
      throw _notFoundAsUnknown(e, spaceId);
    }
  }

  Object _notFoundAsUnknown(AnySyncException e, String spaceId) {
    final c = e.cause;
    if (c is AnyShimException && c.status == AnyShimStatus.notFound) {
      return AnySyncNotReadyException._(
        spaceId,
        AnySyncNotReadyReason.unknownSpace,
        'call spaces(sync: true) first',
      );
    }
    return e;
  }

  /// Every space status change while the account is open.
  Stream<AnySyncStatus> statusChanges() => _status.stream;

  /// Applies what the space has that the location's local index does not.
  Future<AnySyncPull> pull(AnySyncLocation location) =>
      _withCore(location, (core) => core.pull());

  /// Pushes heads to reachable peers (bounded by [timeout]), then pulls.
  Future<AnySyncSyncResult> syncNow(
    AnySyncLocation location, {
    Duration timeout = const Duration(seconds: 20),
  }) => _withCore(location, (core) async {
    final r = await _sdk(
      syncHeadsJob(location.spaceId, _ms(timeout)),
      spaceId: location.spaceId,
    );
    final pull = await core.pull();
    return AnySyncSyncResult._(
      r['reachedPeer'] == true,
      r['timedOut'] == true,
      r['error'] as String?,
      pull,
    );
  });

  /// Documents of the location whose row has no vector for this device's
  /// profile, by key from [after].
  Future<AnySyncMissingVectors> missingVectors(
    AnySyncLocation location, {
    int limit = 100,
    String? after,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be > 0');
    return _withCore(
      location,
      (core) => core.missing(after, limit),
      needsSdk: false,
    );
  }

  /// Writes each item's vector as a leaf of the object it came from, when
  /// that object is still the visible winner with the same content (design
  /// §1 Vector writes). Every modality.
  Future<AnySyncVectorWrite> writeMissingVectors(
    AnySyncLocation location,
    List<AnySyncVectorItem> items,
  ) => _withCore(location, (core) async {
    final r = await core.writeVectors(items);
    return AnySyncVectorWrite._(
      written: r.written,
      skippedChanged: r.changed,
      skippedGone: r.gone,
      skippedNewerFormat: r.newer,
      failed: List.unmodifiable(r.failed),
    );
  });

  /// Pages [missingVectors] from [after], embeds `inputFor(item)` with
  /// [embedder] (outside every lock) and writes the vectors. [embedder]'s
  /// profile must be the location's ([ArgumentError] otherwise). An embedder
  /// failure ends the call with the partial result.
  Future<AnySyncBackfill> backfillVectors(
    AnySyncLocation location,
    RagEmbedder embedder, {
    required EmbeddingInput Function(AnySyncMissingVector item) inputFor,
    int limit = 100,
    String? after,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be > 0');
    return _withCore(location, (core) async {
      final binding = core.requireBinding();
      final profile = await embedder.resolveProfile();
      if (profile != binding.profile) {
        throw ArgumentError.value(
          profile,
          'embedder',
          'embeds $profile, the location is bound to ${binding.profile}',
        );
      }
      final closes = core.ownerCloses;
      final page = await core.missing(after, limit);
      final tally = _Tally();
      // Where the next call resumes when this one stops early: just before
      // the item it did not finish, so that item is offered again.
      var resume = after;
      for (final item in page.items) {
        if (core.ownerCloses != closes) {
          return tally.backfill(resume); // the store closed: partial
        }
        // The app's own mistake in inputFor is its error, not the
        // embedder's (D18).
        final input = inputFor(item);
        final List<double> vector;
        try {
          vector = await embedder.embedDocument(input);
        } catch (e) {
          tally.failed.add(AnySyncVectorFailure._(item.key, 'embedder: $e'));
          return tally.backfill(resume);
        }
        try {
          tally.add(
            await core.writeVectors([
              AnySyncVectorItem(item, Float32List.fromList(vector)),
            ]),
          );
        } on AnySyncException catch (e) {
          tally.failed.add(AnySyncVectorFailure._(item.key, e.message));
          return tally.backfill(resume);
        }
        resume = item.key;
      }
      return tally.backfill(page.next);
    });
  }

  /// The location's totals on this device.
  Future<AnySyncLocationStatus> locationStatus(AnySyncLocation location) =>
      _withCore(location, (core) => core.status(), needsSdk: false);

  /// Deletes dominated objects, runs the supersede deletes whose new object
  /// has synced, and repairs blank bodies (design §2.4).
  Future<AnySyncCompaction> compact(AnySyncLocation location) =>
      _withCore(location, (core) => core.compact());

  /// Closes the SDK (stores keep searching their local index) and completes
  /// after it closed, returning the state then. A first space load in
  /// flight gets up to 25 s to finish first (the iOS background budget,
  /// D9). Calls cancelled by it fail with [AnySyncSuspendedException].
  Future<AnySyncAccountState> suspend() => _lifecycle.run(() async {
    if (_state != AnySyncAccountState.open) return _state;
    _state = AnySyncAccountState.suspended;
    _epoch++;
    await _closeNative(waitLoadsMs: 25000);
    return _state;
  });

  /// Reopens the SDK after [suspend]; returns the state when it completes.
  Future<AnySyncAccountState> resume() => _lifecycle.run(() async {
    if (_state != AnySyncAccountState.suspended) return _state;
    await _openNative();
    _state = AnySyncAccountState.open;
    for (final core in _cores.values) {
      _watch(core.location.spaceId);
    }
    for (final core in _cores.values) {
      core.onChange();
    }
    return _state;
  });

  /// Closes the account. Stores opened from it keep their local index
  /// until they close; anything that needs the SDK fails with
  /// [AnySyncClosedException].
  Future<void> close() => _lifecycle.run(() async {
    if (_state == AnySyncAccountState.closed) return;
    _state = AnySyncAccountState.closed;
    _epoch++;
    await _closeNative();
    await _status.close();
    _openDataDirs.remove(_dataDirectory);
    _openIndexDirs.remove(_indexDirectory);
    for (final core in [..._cores.values]) {
      core.stopFollower();
    }
    await _maybeDispose();
  });

  /// Closes the native account. A close cancels what is in flight first;
  /// a suspend does not (account_cancel is terminal, and the close op lets
  /// space loads finish within [waitLoadsMs]).
  Future<void> _closeNative({int waitLoadsMs = 0}) async {
    final h = _handle;
    if (h == null) return;
    _handle = null;
    if (waitLoadsMs == 0) _rt.cancelAccount(h);
    await _events?.cancel();
    _events = null;
    try {
      await _rt.sdk(closeAccountJob(waitLoadsMs: waitLoadsMs));
    } on Object catch (e) {
      // A failed SDK.Close still drops the registry entry and the lock
      // natively (design §4.3); nothing to retry, but it is said.
      developer.log(
        'closing the account failed: $e',
        name: 'flutter_edge_ai_any',
      );
    }
    _rt.detachAccount(this);
  }

  Future<void> _maybeDispose() async {
    if (_state == AnySyncAccountState.closed &&
        _cores.isEmpty &&
        _coreOpens.isEmpty &&
        _closingCores.isEmpty) {
      await _rt.dispose();
    }
  }

  // --------------------------------------------------------- locations

  /// Runs [body] with the location's core, opening it from its local file
  /// when no store has it open.
  /// [needsSdk] false: a local-only call, which also works while the
  /// account is suspended (D14).
  Future<T> _withCore<T>(
    AnySyncLocation location,
    Future<T> Function(_LocationCore core) body, {
    bool needsSdk = true,
  }) async {
    if (needsSdk || _state == AnySyncAccountState.closed) _checkOpen();
    final core = await _acquire(location, owner: false);
    try {
      return await body(core);
    } finally {
      await _release(core, owner: false);
    }
  }

  Future<_LocationCore> _acquire(
    AnySyncLocation location, {
    required bool owner,
  }) async {
    if (_state == AnySyncAccountState.closed) {
      throw const AnySyncClosedException._();
    }
    final key = location.value;
    // The previous core of this location is still closing: its native
    // handle holds the file until then (D5).
    final closing = _closingCores[key];
    if (closing != null) await closing;
    var core = _cores[key];
    if (core == null) {
      // Each caller's own rule, also when it joins an open in flight (D16).
      if (!owner && !fileExists(_indexPath(location))) {
        throw StateError(
          'No local index for ${location.value} on this device: open it with '
          'FlutterEdgeAiRag first.',
        );
      }
      final opening = _coreOpens[key] ??= _openCore(location);
      try {
        core = await opening;
      } finally {
        _coreOpens.remove(key);
        // An open that ends after close() must still let the runtime go.
        await _maybeDispose();
      }
    }
    if (owner) {
      if (core.hasOwner) {
        throw AnySyncBusyException._(
          AnySyncBusyReason.alreadyOpenInProcess,
          '${location.value} already has an open store in this process',
        );
      }
      core.hasOwner = true;
    }
    core.refs++;
    return core;
  }

  String _indexDir(AnySyncLocation l) =>
      '$_indexDirectory/${sha256Hex(l.value)}';

  String _indexPath(AnySyncLocation l) => '${_indexDir(l)}/index.anystore';

  Future<_LocationCore> _openCore(AnySyncLocation location) async {
    final path = _indexPath(location);
    ensureDirectory(_indexDir(location));
    final core = _LocationCore(this, location);
    final handle = await _retryBusy(
      'the index of ${location.value}',
      () => _rt.index(
        indexOpenJob({
          'path': path,
          'keyHex': ?_keyHex,
          'ownerToken': ownerToken(),
        }),
      ),
      refusedMeansHeld: true,
    );
    try {
      await core.attach(handle);
    } catch (_) {
      // Do not leave the file held by a handle nobody owns (D16).
      try {
        await _rt.index(indexCloseJob(handle));
      } on Object {
        // The finalizer releases it.
      }
      rethrow;
    }
    _cores[location.value] = core;
    _watch(location.spaceId);
    return core;
  }

  Future<void> _release(_LocationCore core, {required bool owner}) async {
    core.refs--;
    if (owner) {
      core.hasOwner = false;
      core.ownerCloses++;
    }
    if (core.refs == 0) {
      final key = core.location.value;
      _cores.remove(key);
      final closing = core.close();
      _closingCores[key] = closing;
      try {
        await closing;
      } finally {
        if (identical(_closingCores[key], closing)) _closingCores.remove(key);
      }
      await _maybeDispose();
    }
  }

  /// Makes the space available, waiting at most spaceOpenWait.
  Future<void> _resolveSpace(String spaceId) async {
    final String r;
    try {
      r = await _sdk(
        spaceResolveJob(spaceId, _spaceOpenWait.inMilliseconds),
        spaceId: spaceId,
      );
    } on AnySyncException catch (e) {
      throw _notFoundAsUnknown(e, spaceId);
    }
    if (r == 'loading') {
      throw AnySyncNotReadyException._(
        spaceId,
        AnySyncNotReadyReason.loading,
        'still loading after ${_spaceOpenWait.inSeconds} s',
      );
    }
  }
}

/// Totals of vector writes.
final class _Tally {
  int written = 0;
  int changed = 0;
  int gone = 0;
  int newer = 0;
  final failed = <AnySyncVectorFailure>[];

  void add(_Tally o) {
    written += o.written;
    changed += o.changed;
    gone += o.gone;
    newer += o.newer;
    failed.addAll(o.failed);
  }

  AnySyncBackfill backfill(String? next) => AnySyncBackfill._(
    written: written,
    skippedChanged: changed,
    skippedGone: gone,
    skippedNewerFormat: newer,
    failed: List.unmodifiable(failed),
    next: next,
  );
}
