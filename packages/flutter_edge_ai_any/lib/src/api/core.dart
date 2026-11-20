part of 'any_sync.dart';

/// One location's core (design §4.2): its native index handle, its write
/// lock and its follower, shared by at most one store and any number of
/// account calls, ref-counted by the account.
final class _LocationCore {
  _LocationCore(this.account, this.location);

  final AnySyncAccount account;
  final AnySyncLocation location;
  late final int handle;

  /// Serialises every write and every follower page of this location.
  final _lock = _Mutex();

  LocConfig? cfg;
  VectorStoreBinding? binding;
  bool textSearch = false;
  int refs = 0;
  bool hasOwner = false;

  /// Bumped when the owning store closes (not when one opens): an account
  /// call that started before stops early (backfill).
  int ownerCloses = 0;
  bool _closed = false;
  bool _following = false;
  Timer? _debounce;
  Timer? _retry;
  int _failures = 0;

  /// The last background follower failure, until a pull succeeds (D2).
  String? lastFollowerError;
  DateTime? lastFollowerErrorAt;

  String get spaceId => location.spaceId;

  Future<T> _idx<T>(IndexJob<T> job) => account._index(job, spaceId: spaceId);

  /// A read: waits at most 10 s for a bind or swap (indexBusy after).
  Future<T> _read<T>(IndexJob<T> job) =>
      account._index(job, spaceId: spaceId, read: true);

  Future<T> _sdk<T>(SdkJob<T> job) => account._sdk(job, spaceId: spaceId);

  /// An SDK write (object_patch, records_modify), with NOT_FOUND mapped
  /// by [_notFoundAsNotReady].
  Future<T> _sdkWrite<T>(SdkJob<T> job) async {
    try {
      return await _sdk(job);
    } on AnySyncException catch (e) {
      throw _notFoundAsNotReady(e) ?? e;
    }
  }

  /// The one NOT_FOUND mapping of bind, the bundle reads and the writes
  /// (D3-7): definitions not synced here (either wording) and a space the
  /// account does not know are retryable readiness, with the native message
  /// and cause; anything else ("object … is not here") is not, and null.
  AnySyncNotReadyException? _notFoundAsNotReady(AnySyncException e) {
    final c = e.cause;
    if (c is! AnyShimException || c.status != AnyShimStatus.notFound) {
      return null;
    }
    if (c.message.contains('have not synced') ||
        c.message.contains('has not synced')) {
      return AnySyncNotReadyException._(
        spaceId,
        AnySyncNotReadyReason.definitionsNotSynced,
        c.message,
        c,
      );
    }
    if (c.message.contains('is not known to this account')) {
      return AnySyncNotReadyException._(
        spaceId,
        AnySyncNotReadyReason.unknownSpace,
        c.message,
        c,
      );
    }
    return null;
  }

  /// Records a background failure and reports it on followerEvents.
  void _recordError(String error) {
    lastFollowerError = error;
    lastFollowerErrorAt = DateTime.now();
    account._emitFollower(this);
  }

  /// A pull that applied but had vectors refused keeps its error.
  bool _rejectedInLastPull = false;

  void _clearError() {
    if (lastFollowerError == null || _rejectedInLastPull) return;
    lastFollowerError = null;
    lastFollowerErrorAt = null;
    account._emitFollower(this);
  }

  /// This device's superseded objects whose delete currently fails with
  /// something other than gone (D3-9), and the last such error.
  final _supersedeFailing = <String>{};
  String? lastSupersedeError;

  /// Generations a swap left that gc has not dropped yet (an estimate:
  /// after an open, 1 until a gc round reports done).
  int orphanGenerations = 1;
  String? lastGcError;
  bool _gcRunning = false;

  /// Reads the local binding. A binding without its config is a bind that
  /// did not finish: unbound (D6).
  Future<void> attach(int h) async {
    handle = h;
    account._rt.attachIndex(this, h);
    final st = await _idx(getStatesJob(h, ['binding', 'cfg', 'rebuilding']));
    if (st['rebuilding'] != null) {
      // A rebuild interrupted by a restart: index_open dropped its shadow;
      // the condition that started it starts the next one from shadowBegin.
      await _idx(setStatesJob(h, {'rebuilding': null}));
    }
    final b = st['binding'];
    final c = st['cfg'];
    if (b != null && c != null) {
      binding = _bindingFrom((jsonDecode(b) as Map).cast());
      cfg = LocConfig.fromJson((jsonDecode(c) as Map).cast());
    }
    final info = await _idx(indexInfoJob(h));
    textSearch = info['textSearch'] == true;
    _gc();
  }

  /// Drops orphan generations in bounded rounds, in the background (H4):
  /// after open, after every swap, after a rebuild that gave up (D-R5). A
  /// failure is reported in locationStatus; none runs on a closed index.
  void _gc() {
    if (_closed || _gcRunning) return;
    _gcRunning = true;
    final h = handle;
    // A failing step (an orphan that cannot be dropped rotates to the back
    // natively) is reported and the next step tried after a backoff; a
    // PENDING (a bind or swap) waits the same way. Runs out after a bounded
    // number of steps: "gc did not finish" (D3-9).
    Future<void> rounds() async {
      var failures = 0;
      for (var i = 0; i < 10000; i++) {
        if (_closed) return;
        try {
          final done = await account._rt.index(indexGcJob(h));
          if (done) {
            orphanGenerations = 0;
            lastGcError = null;
            return;
          }
          failures = 0;
          await Future<void>.delayed(Duration.zero);
        } on AnyShimException catch (e) {
          if (_closed) return; // a close racing the gc is not a failure
          if (e.status != AnyShimStatus.pending) {
            lastGcError = '${e.operation}: ${e.message}';
            print(
              'flutter_edge_ai_any: index gc of ${location.value} failed: '
              '${e.message}',
            );
          }
          if (++failures > 20) break;
          await Future<void>.delayed(AnySyncAccount._backoff(failures));
        }
      }
      if (!_closed) lastGcError ??= 'gc did not finish';
    }

    rounds()
        .catchError((Object e) {
          if (_closed) return;
          lastGcError = '$e';
          print(
            'flutter_edge_ai_any: index gc of ${location.value} failed: $e',
          );
        })
        .whenComplete(() => _gcRunning = false);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopFollower();
    // Waits for the write or page in flight, then closes the file. A
    // failed close is said and thrown (D3-2); the finalizer-shaped release
    // stays attached as the backstop.
    await _lock.run(() async {
      try {
        await account._rt.index(indexCloseJob(handle));
      } on Object catch (e) {
        print(
          'flutter_edge_ai_any: closing the index of ${location.value} '
          'failed: $e',
        );
        throw AnySyncException(
          'closing the index of ${location.value} failed: $e',
          retryable: false,
          cause: e,
        );
      }
      account._rt.detachIndex(this);
    });
  }

  VectorStoreBinding requireBinding() {
    final b = binding;
    if (b == null || cfg == null) {
      throw StateError(
        '${location.value} is not bound on this device: open it with '
        'FlutterEdgeAiRag first.',
      );
    }
    return b;
  }

  LocConfig requireCfg() {
    requireBinding();
    return cfg!;
  }

  // ------------------------------------------------------- open and bind

  /// `initialize`: resolves the space, starts a new file's first pull, and
  /// when this device bound the location before, brings the local index to
  /// [schema] (D7) and starts the follower.
  Future<void> prepare(FilterSchema schema, {required bool enableText}) async {
    await account._resolveSpace(spaceId);
    final head = await _idx(getStateJob(handle, 'cursor'));
    if (head == null) {
      final (gen, target) = await _sdk(feedHeadJob(spaceId));
      await _idx(
        setStatesJob(handle, {
          'cursor': cursorValue(gen, 0),
          'firstPull': jsonEncode({'t': target, 'd': target == 0}),
        }),
      );
    }
    final b = binding;
    final c = cfg;
    if (b == null || c == null) return;
    final grown = _schemaGrows(c.schema, schema);
    final pending = await _idx(getStateJob(handle, 'needsRebuild')) != null;
    await _lock.run(() async {
      final next = grown
          ? LocConfig.fromJson(c.toJson(), schema: _union(c.schema, schema))
          : c;
      // Every open of a bound location compares the manifest with this
      // binding and publishes what is missing, FIRST (idempotent), then
      // index_bind, then one state commit: bind's order (D-R8).
      final manifest = await _sdk(readManifestJob(spaceId, c.manifestId));
      final refusal = manifestConflict(manifest, next, _bindingJson(b));
      if (refusal != null) {
        throw AnySyncConflictException._(
          AnySyncManifest._fromJson(manifest.toJson()),
          await _conflictingDocuments(),
          [for (final r in refusal['reasons']! as List) r as String],
        );
      }
      final published = await _publishMissing(
        next,
        b,
        manifest: manifest,
        enableText: enableText || textSearch,
        readOnlyOk: true,
      );
      await _bindIndex(next, enableText: enableText);
      await _idx(
        setStatesJob(handle, {
          'cfg': jsonEncode(next.toJson()),
          'manifest': jsonEncode(published.toJson()),
          if (grown) 'needsRebuild': '1',
        }),
      );
      cfg = next;
      // A grown schema's rows lack the new f.* values: rebuild, also when
      // a previous open was interrupted before its swap.
      if (grown || pending) await _rebuildLocked();
    });
    _startFollower();
    await _catchUp();
  }

  /// Never lets a failed count replace the conflict it describes (D-R12).
  Future<int> _conflictingDocuments() async {
    try {
      return await account._rt.index(conflictingDocumentsJob(handle));
    } on Exception catch (e) {
      print('flutter_edge_ai_any: counting conflicting documents failed: $e');
      return 0;
    }
  }

  static bool _schemaGrows(FilterSchema have, FilterSchema want) =>
      want.fields.any((f) => have.fieldFor(f.name)?.type != f.type);

  /// [have] plus the fields of [want] it lacks. A name [want] declares with
  /// another type keeps [want]'s, so the conflict check sees it.
  static FilterSchema _union(FilterSchema have, FilterSchema want) {
    final fields = [
      for (final f in have.fields)
        if (want.fieldFor(f.name) == null) f,
      ...want.fields,
    ];
    return FilterSchema(fields: fields);
  }

  /// index_bind (an op: a growing bind backfills). Writes no state.
  Future<void> _bindIndex(LocConfig c, {required bool enableText}) async {
    final manifestText = await _idx(getStateJob(handle, 'manifest'));
    final published =
        manifestText != null &&
        (jsonDecode(manifestText) as Map)['textSearch'] == true;
    final text = enableText || published || textSearch;
    final info = await _idx(
      indexBindJob(handle, {
        'dim': c.dimension,
        'metric': 'cosine',
        'fields': [
          for (final f in c.schema.fields)
            {'key': fieldKeyOf(f), 'type': f.type.name},
        ],
        'textSearch': text,
      }),
    );
    textSearch = info['textSearch'] == true;
  }

  /// `bind` (design §2.1): the bundles, the publish gate or the conflict
  /// check, index_bind, then binding, manifest and config in ONE state
  /// commit (D6), then the follower.
  Future<void> bindLocation(
    VectorStoreBinding b,
    FilterSchema schema, {
    required bool enableText,
  }) async {
    await _lock.run(() async {
      final have = binding;
      if (have != null) {
        if (have == b) return;
        throw VectorStoreException(
          '${location.value} is bound to $have on this device, not $b.',
        );
      }
      // The bundles: ensured by a writer, read by a reader.
      var readOnly = false;
      Map<String, Object?> bundles;
      try {
        bundles = await _sdk(ragBundlesJob(spaceId, true));
      } on AnySyncReadOnlyException {
        readOnly = true;
        bundles = await _readBundles();
      } on AnySyncException catch (e) {
        throw _notFoundAsNotReady(e) ?? e;
      }
      final loc = (bundles['location']! as Map).cast<String, Object?>();
      final doc = (bundles['document']! as Map).cast<String, Object?>();
      final locRoot = loc['rootId']! as String;
      // Computed, never written (D11): a reader may call it.
      final manifestId = await _sdk(manifestIdJob(spaceId, location.indexName));
      final c = LocConfig(
        spaceId: spaceId,
        indexName: location.indexName,
        docRoot: doc['rootId']! as String,
        manifestId: manifestId,
        tombColl: loc['tombstones']! as String,
        locRoot: locRoot,
        profileId: b.profile.id,
        dimension: b.profile.dimension,
        documents: b.documents.name,
        schema: schema,
      );
      var manifest = await _sdk(readManifestJob(spaceId, manifestId));
      if (!manifest.present) {
        manifest = await _gate(c, manifest);
      }
      if (manifest.present) {
        final refusal = manifestConflict(manifest, c, _bindingJson(b));
        if (refusal != null) {
          throw AnySyncConflictException._(
            AnySyncManifest._fromJson(manifest.toJson()),
            await _conflictingDocuments(),
            [for (final r in refusal['reasons']! as List) r as String],
          );
        }
      }
      final published = await _publishMissing(
        c,
        b,
        manifest: manifest,
        enableText: enableText || textSearch,
        readOnly: readOnly,
      );
      await _bindIndex(c, enableText: enableText);
      await _idx(
        setStatesJob(handle, {
          'binding': jsonEncode(_bindingJson(b)),
          'manifest': jsonEncode(published.toJson()),
          'cfg': jsonEncode(c.toJson()),
        }),
      );
      cfg = c;
      binding = b;
    });
    _startFollower();
    await _catchUp();
  }

  Future<Map<String, Object?>> _readBundles() async {
    try {
      return await _sdk(ragBundlesJob(spaceId, false));
    } on AnySyncException catch (e) {
      throw _notFoundAsNotReady(e) ?? e;
    }
  }

  static bool _isStatus(AnySyncException e, AnyShimStatus s) {
    final c = e.cause;
    return c is AnyShimException && c.status == s;
  }

  /// The publish gate (design §2.1, D8) for a manifest without `core`:
  /// returns the manifest to bind against, `present: false` meaning
  /// "publish it". A converged round first; the creator exception only when
  /// no peer could be reached, for a space created here that never synced
  /// with a peer, and whose account state saved.
  Future<ManifestRead> _gate(LocConfig c, ManifestRead absent) async {
    var wait = account._spaceOpenWait.inMilliseconds;
    if (wait <= 0) wait = 1;
    final heads = await _sdk(syncHeadsJob(spaceId, wait));
    if (heads['reachedPeer'] == true) {
      final deadline = DateTime.now().add(Duration(milliseconds: wait));
      while (true) {
        final s = AnySyncStatus._fromJson(await _sdk(spaceStatusJob(spaceId)));
        if (s.state == AnySyncSpaceState.synced) break;
        if (DateTime.now().isAfter(deadline)) {
          throw AnySyncNotReadyException._(
            spaceId,
            AnySyncNotReadyReason.manifestNotSynced,
            'a peer answered, the space did not reach synced',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // Converged: what this device has now is what the peers have.
      return _sdk(readManifestJob(spaceId, c.manifestId));
    }
    final status = AnySyncStatus._fromJson(await _sdk(spaceStatusJob(spaceId)));
    if (status.createdHere &&
        !status.everPeerSynced &&
        status.stateSaveError == null) {
      return absent;
    }
    throw AnySyncNotReadyException._(
      spaceId,
      AnySyncNotReadyReason.manifestNotSynced,
      status.stateSaveError != null
          ? 'the account state did not save: ${status.stateSaveError}'
          : 'no peer answered',
    );
  }

  /// Writes the manifest leaves this binding needs and [manifest] lacks
  /// (all of them, with `core`, when it is absent); returns the manifest as
  /// published. A reader never writes.
  Future<ManifestRead> _publishMissing(
    LocConfig c,
    VectorStoreBinding b, {
    required ManifestRead manifest,
    bool enableText = false,
    bool readOnly = false,
    bool readOnlyOk = false,
  }) async {
    final m = manifest;
    final ops = <Map<String, Object?>>[];
    final core = [...m.coreLeaves];
    if (!m.present) {
      ops.add(coreOp(c.documents));
      core.add(c.documents);
    }
    final fields = <FieldLeaf>[...m.fields];
    for (final f in c.schema.fields) {
      final leaf = FieldLeaf(f.name, f.type.name);
      if (!m.fields.any((x) => x.key == leaf.key)) {
        ops.add({'xkey': 'fields', 'leaf': leaf.key, 'value': leaf.toJson()});
        fields.add(leaf);
      }
    }
    final profiles = <ProfileLeaf>[...m.profiles];
    final mine = ProfileLeaf(b.profile.id, b.profile.dimension, c.documents);
    if (!m.profiles.any((p) => p.key == mine.key)) {
      ops.add({'xkey': 'profiles', 'leaf': mine.key, 'value': mine.toJson()});
      profiles.add(mine);
    }
    if (enableText && !m.textSearch) ops.add(textSearchOp);
    if (ops.isEmpty) return m;
    if (readOnly) {
      if (readOnlyOk) return m;
      throw AnySyncReadOnlyException._(
        '${location.value} needs manifest entries this account cannot write',
      );
    }
    try {
      // Derive, not {id}: the first publish creates the manifest object.
      await _sdkWrite(
        patchJob(spaceId, {
          'derive': {'seed': manifestSeed(c.indexName), 'type': c.locRoot},
        }, ops),
      );
    } on AnySyncReadOnlyException {
      if (readOnlyOk) return m;
      rethrow;
    }
    return ManifestRead(
      coreLeaves: core..sort(),
      coreNewerFormat: m.coreNewerFormat,
      fields: fields,
      profiles: profiles,
      textSearch: m.textSearch || enableText,
      ignoredLeaves: m.ignoredLeaves,
    );
  }

  // ------------------------------------------------------------ follower

  void _startFollower() {
    if (_closed) return;
    _following = true;
  }

  void stopFollower() {
    _following = false;
    _debounce?.cancel();
    _debounce = null;
    _retry?.cancel();
    _retry = null;
  }

  /// A change event: pull after 200 ms of quiet (design §4.1).
  void onChange() {
    // A failing follower waits for its backoff timer (D-R11).
    if (!_following || _closed || _retry != null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      _debounce = null;
      if (account._state != AnySyncAccountState.open) return;
      _background();
    });
  }

  /// A background pull: a failure is recorded, reported on followerEvents
  /// and retried with backoff (1 s doubling to 60 s), never thrown (D2).
  Future<void> _background() async {
    if (_closed || !_following) return;
    try {
      await pull();
      _failures = 0;
      _retry?.cancel();
      _retry = null;
      _clearError();
    } catch (e) {
      _failures++;
      _recordError('$e');
      final secs = _failures >= 7 ? 60 : 1 << (_failures - 1);
      _retry?.cancel();
      _retry = Timer(Duration(seconds: secs), () {
        _retry = null;
        if (account._state == AnySyncAccountState.open) _background();
      });
    }
  }

  /// The catch-up after open: its failure is the follower's, not the
  /// open's (D2); it is recorded and retried.
  Future<void> _catchUp() => _background();

  /// An app's pull (pull, syncNow): its error is the app's; its success
  /// clears the follower's error and backoff (D-R11).
  Future<AnySyncPull> manualPull() async {
    final r = await pull();
    _failures = 0;
    _retry?.cancel();
    _retry = null;
    _clearError();
    return r;
  }

  /// One pull (design §3): follower pages until the feed is exhausted,
  /// rebuilding when the generation moved, then the supersede deletes that
  /// became safe.
  Future<AnySyncPull> pull() => _lock.run(() async {
    final c = cfg;
    if (c == null || binding == null || _closed) return AnySyncPull._();
    var result = AnySyncPull._();
    _rejectedInLastPull = false;
    var readTombstones = true;
    var extra = <String>[];
    var rounds = 0;
    while (true) {
      if (++rounds > 10000) {
        throw StateError('${location.value}: the follower does not settle');
      }
      final fs = await _idx(followStateJob(handle));
      final cursor = parseCursor(fs.cursorRaw);
      final (o, more) = await _sdk(
        pullStepJob(
          c,
          handle,
          fromSeq: cursor?.seq ?? 0,
          cursorRaw: fs.cursorRaw,
          clearRaw: fs.clearRaw,
          tombSeq: fs.tombSeq,
          readTombstones: readTombstones,
          extraIds: extra,
          nowMs: account._nowMs(),
        ),
      );
      if (o.needRebuild) {
        result = (await _rebuildLocked())._plus(PageOutcome());
        readTombstones = true;
        extra = [];
        continue;
      }
      if (o.casMiss) continue;
      if (o.needObjects.isNotEmpty) {
        if (o.needObjects.every(extra.contains)) {
          throw StateError(
            '${location.value}: objects ${o.needObjects} cannot be read',
          );
        }
        extra = {...extra, ...o.needObjects}.toList();
        continue;
      }
      result = result._plus(o);
      _reportRejected(o);
      readTombstones = false;
      extra = [];
      if (!more) break;
    }
    await _sweepSupersede(c);
    return result;
  });

  /// Runs the supersede deletes whose new object a peer acknowledged
  /// (design §2.2 step 6). Best effort: what fails waits for the next pull.
  Future<int> _sweepSupersede(LocConfig c) async {
    final plan = await _idx(supersedeListJob(handle));
    if (plan.isEmpty) return 0;
    final done = <String>[];
    for (final (old, fresh) in plan) {
      try {
        final state = await _sdk(objectSyncStateJob(spaceId, fresh));
        if (state != 'synced' &&
            !debugEngineMutations.contains('supersedeBeforeSync')) {
          continue;
        }
        await _sdk(deleteObjectJob(spaceId, old));
        done.add('s/$old');
        _supersedeFailing.remove(old);
      } on AnySyncException catch (e) {
        if (_isStatus(e, AnyShimStatus.deleted) ||
            _isStatus(e, AnyShimStatus.notFound)) {
          done.add('s/$old');
          _supersedeFailing.remove(old);
        } else {
          _supersedeFailing.add(old);
          lastSupersedeError = e.message;
        }
      }
    }
    if (done.isNotEmpty) await _idx(dropStateJob(handle, done));
    return done.length;
  }

  /// Rebuild (design §3): anchor, page the document type into a shadow,
  /// replay the feed from the anchor, swap. Runs under the lock.
  Future<AnySyncPull> _rebuildLocked() async {
    final c = cfg!;
    final since = account._nowMs();
    await _idx(markRebuildingJob(handle, since));
    // The winners the last attempt could not read; null when it restarted
    // because the generation moved (D3-5).
    List<String>? unreadable;
    for (var attempt = 0; attempt < 5; attempt++) {
      unreadable = null;
      await _idx(beginShadowJob(handle));
      await _sdk(rebuildManifestJob(c, handle, nowMs: account._nowMs()));
      String? after;
      String? gen;
      int? anchor;
      var moved = false;
      do {
        final p = await _sdk(
          rebuildPageJob(c, handle, after: after, nowMs: account._nowMs()),
        );
        // A page that could not read the winners it needs: never swap with
        // keys missing; this attempt starts again (D-R2).
        _reportRejected(p.outcome);
        if (p.outcome.needObjects.isNotEmpty) {
          unreadable = p.outcome.needObjects;
          moved = true;
          break;
        }
        if (anchor == null) {
          gen = p.generation;
          anchor = p.anchor;
        } else if (p.generation != gen) {
          moved = true;
          break;
        }
        after = p.next;
      } while (after != null);
      if (moved || anchor == null) continue;
      final (hwGen, hw) = await _sdk(feedHeadJob(spaceId));
      if (hwGen != gen) continue;
      int seq = anchor;
      var extra = <String>[];
      while (seq < hw) {
        final s = await _sdk(
          replayStepJob(
            c,
            handle,
            fromSeq: seq,
            extraIds: extra,
            nowMs: account._nowMs(),
          ),
        );
        if (s.generation != gen) {
          moved = true;
          break;
        }
        _reportRejected(s.outcome);
        if (s.outcome.needObjects.isNotEmpty) {
          if (s.outcome.needObjects.every(extra.contains)) {
            unreadable = s.outcome.needObjects;
            moved = true; // restart the attempt (D-R2)
            break;
          }
          extra = {...extra, ...s.outcome.needObjects}.toList();
          continue;
        }
        extra = [];
        if (s.toSeq <= seq) break;
        seq = s.toSeq;
      }
      if (moved) continue;
      await _idx(carryOwnJob(handle));
      await _idx(swapShadowJob(handle, gen, seq > hw ? seq : hw));
      orphanGenerations++;
      _gc();
      return AnySyncPull._()._rebuilt();
    }
    // Each attempt began a shadow; they are orphans now.
    orphanGenerations++;
    _gc();
    if (unreadable != null) {
      throw AnySyncException(
        '${location.value}: a rebuild could not complete: objects '
        '$unreadable cannot be read',
        retryable: true,
      );
    }
    throw AnySyncException(
      '${location.value}: the space generation kept moving during a rebuild',
      retryable: true,
    );
  }

  /// Vectors the index refused in a page are the follower's error (D-R1),
  /// also during a rebuild or replay (D3-9).
  void _reportRejected(PageOutcome o) {
    if (o.rejected.isEmpty) return;
    _rejectedInLastPull = true;
    _recordError(
      'the index refused vectors of ${o.rejected.length} object(s): '
      '${o.rejected.values.first}',
    );
  }

  // --------------------------------------------------------------- writes

  Future<Never> _refused(WriteRefused w, StackTrace st) async {
    if (w.reason == 'firstPullPending') {
      Error.throwWithStackTrace(
        AnySyncNotReadyException._(
          spaceId,
          AnySyncNotReadyReason.firstPullPending,
          'this local index has not caught up with the space yet',
        ),
        st,
      );
    }
    final j = (jsonDecode(w.detail ?? '{}') as Map).cast<String, Object?>();
    final conflicting = await account._rt.index(
      conflictingDocumentsJob(handle),
    );
    Error.throwWithStackTrace(
      AnySyncConflictException._(
        AnySyncManifest._fromJson({...j, 'present': true}),
        conflicting,
        [for (final r in (j['reasons'] as List? ?? const [])) r as String],
      ),
      st,
    );
  }

  Future<T> _write<T>(Future<T> Function(LocConfig c) body) {
    final c = requireCfg();
    account._checkOpen();
    return _lock.run(() async {
      try {
        return await body(c);
      } on WriteRefused catch (w, st) {
        return _refused(w, st);
      }
    });
  }

  /// Add or update (design §2.2): S1, else copy-on-write.
  Future<void> add({
    required String key,
    required String content,
    required Float32List vector,
    required String? meta,
  }) => _write((c) async {
    final ch = sha256Hex(content);
    final mh = metaHash(meta);
    final plan = await _idx(planAddJob(handle, key, ch, mh));
    final leaf = LeafValue.encode(vector, ch);
    if (plan.plan == AddPlan.noop) return;
    if (plan.plan == AddPlan.leafOnly) {
      final id = plan.objectId!;
      var patched = false;
      try {
        await _sdkWrite(
          patchJob(
            spaceId,
            {'id': id},
            [
              {'xkey': 'vecs', 'leaf': c.profileKey, 'value': leaf},
            ],
          ),
        );
        patched = true;
      } on AnySyncException catch (e) {
        // The winner was deleted meanwhile: the caller asked to add.
        if (!_isStatus(e, AnyShimStatus.deleted)) rethrow;
      }
      if (patched) {
        // The leaf is in the space now: a local failure is committed (D12).
        bool applied;
        try {
          applied = await _idx(applyLeafJob(handle, c, key, id, ch, vector));
        } catch (e) {
          throw AnySyncCommittedException._(key, null, id, e);
        }
        if (!applied) {
          throw AnySyncCommittedException._(
            key,
            null,
            id,
            StateError('the object stopped being the visible winner'),
          );
        }
        return;
      }
    }
    final rev = await _idx(allocateWriteRevJob(handle, account._nowMs()));
    final doc = DocValue.encode(
      loc: c.indexName,
      key: key,
      rev: rev,
      mod: c.documents,
      content: content,
      meta: meta,
    );
    final created = await _sdkWrite(
      patchJob(
        spaceId,
        {
          'create': {'type': c.docRoot},
        },
        [
          {'xkey': 'doc', 'value': doc},
          {'xkey': 'vecs', 'leaf': c.profileKey, 'value': leaf},
        ],
      ),
    );
    final id = created['id']! as String;
    try {
      await _idx(
        applyOwnAddJob(
          handle,
          c,
          key: key,
          objectId: id,
          rev: rev,
          content: content,
          meta: meta,
          vector: vector,
          nowMs: account._nowMs(),
        ),
      );
    } catch (e) {
      throw AnySyncCommittedException._(key, rev, id, e);
    }
    try {
      await _sdk(setBodyJob(spaceId, id, content));
    } on Object catch (e) {
      // Best effort, but recorded: compact() repairs what is marked, so a
      // mark that fails is reported, not dropped (D18).
      print(
        'flutter_edge_ai_any: the editor body of $id ($key) was not '
        'written: $e',
      );
      try {
        await _idx(markBlankBodyJob(handle, id, key));
      } catch (e) {
        throw AnySyncCommittedException._(key, rev, id, e);
      }
    }
  });

  /// Remove (design §2.3): a tombstone rev, then the local delete, then
  /// this device's older objects of the key.
  Future<void> remove(String key) => _write((c) async {
    final rev = await _idx(allocateWriteRevJob(handle, account._nowMs()));
    await _sdkWrite(
      recordsModifyJob(spaceId, c.manifestId, c.tombColl, [
        {
          'id': sha256Hex(key),
          'set': {'key': key},
          'addToSet': {'revs': rev},
        },
      ]),
    );
    final List<String> doomed;
    try {
      doomed = await _idx(applyRemoveJob(handle, key, rev));
    } catch (e) {
      throw AnySyncCommittedException._(key, rev, c.manifestId, e);
    }
    await _deleteQuietly(doomed);
  });

  /// Clear (design §2.3): a clear rev, one local transaction, then the
  /// mapped objects below it.
  Future<void> clear() => _write((c) async {
    final rev = await _idx(allocateWriteRevJob(handle, account._nowMs()));
    await _sdkWrite(
      recordsModifyJob(spaceId, c.manifestId, c.tombColl, [
        {
          'id': clearRecordId,
          'addToSet': {'revs': rev},
        },
      ]),
    );
    final List<String> doomed;
    try {
      doomed = await _idx(applyClearJob(handle, rev, account._nowMs()));
    } catch (e) {
      throw AnySyncCommittedException._('', rev, c.manifestId, e);
    }
    await _deleteQuietly(doomed);
  });

  Future<void> _deleteQuietly(List<String> ids) async {
    for (final id in ids) {
      try {
        await _sdk(deleteObjectJob(spaceId, id));
      } on AnySyncException {
        // compact() deletes what is left.
      }
    }
  }

  /// writeMissingVectors (design §1 Vector writes).
  Future<_Tally> writeVectors(List<AnySyncVectorItem> items) => _write((
    c,
  ) async {
    final t = _Tally();
    for (final it in items) {
      final item = it.item;
      final v = it.vector;
      if (v.length != c.dimension) {
        t.failed.add(
          AnySyncVectorFailure._(
            item.key,
            'dimension ${v.length}, the location is ${c.dimension}',
          ),
        );
        continue;
      }
      final problem = vectorProblem(v);
      if (problem != null) {
        t.failed.add(AnySyncVectorFailure._(item.key, problem));
        continue;
      }
      final check = await _idx(
        checkLeafJob(handle, item.key, item._objectId, item.contentHash),
      );
      switch (check) {
        case LeafCheck.changed:
          t.changed++;
          continue;
        case LeafCheck.gone:
          t.gone++;
          continue;
        case LeafCheck.newerFormat:
          t.newer++;
          continue;
        case LeafCheck.write:
          break;
      }
      try {
        await _sdkWrite(
          patchJob(
            spaceId,
            {'id': item._objectId},
            [
              {
                'xkey': 'vecs',
                'leaf': c.profileKey,
                'value': LeafValue.encode(v, item.contentHash),
              },
            ],
          ),
        );
      } on AnySyncSuspendedException {
        rethrow;
      } on AnySyncClosedException {
        rethrow;
      } on AnySyncException catch (e) {
        if (_isStatus(e, AnyShimStatus.deleted)) {
          t.gone++;
        } else {
          t.failed.add(AnySyncVectorFailure._(item.key, e.message));
        }
        continue;
      }
      // The leaf is in the space now: a local failure is committed (D12).
      bool ok;
      try {
        ok = await _idx(
          applyLeafJob(
            handle,
            c,
            item.key,
            item._objectId,
            item.contentHash,
            v,
          ),
        );
      } catch (e) {
        throw AnySyncCommittedException._(item.key, null, item._objectId, e);
      }
      if (ok) {
        t.written++;
      } else {
        t.failed.add(
          AnySyncVectorFailure._(
            item.key,
            'committed to the space; the local index takes it at the next '
            'pull',
          ),
        );
      }
    }
    return t;
  });

  // ------------------------------------------------------------ reading

  Future<AnySyncMissingVectors> missing(String? after, int limit) async {
    final c = requireCfg();
    final page = await _read(readMissingJob(handle, after, limit));
    final modality = _modality(c.documents) ?? EmbeddingModality.text;
    return AnySyncMissingVectors._(
      List.unmodifiable([
        for (final m in page.items)
          AnySyncMissingVector._(
            key: m['key']! as String,
            content: m['content']! as String,
            meta: m['meta'] as String?,
            contentHash: m['ch']! as String,
            modality: modality,
            objectId: m['objectId']! as String,
          ),
      ]),
      page.next,
    );
  }

  Future<AnySyncLocationStatus> status() async {
    final now = account._nowMs();
    final j = await _read(readStatusJob(handle, now));
    return AnySyncLocationStatus._fromJson(
      j,
      now,
      followerError: lastFollowerError,
      followerErrorAt: lastFollowerErrorAt,
      orphanGenerations: orphanGenerations,
      lastGcError: lastGcError,
      supersedeErrors: _supersedeFailing.length,
      lastSupersedeError: lastSupersedeError,
      eventsDownSince: account._eventsDownSince,
      eventsDownError: account._eventsDownError,
    );
  }

  /// compact (design §2.4), then a pull, so the totals reflect its deletes.
  Future<AnySyncCompaction> compact() async {
    final r = await _compact();
    await _catchUp();
    return r;
  }

  Future<AnySyncCompaction> _compact() => _write((c) async {
    final plan = await _idx(planCompactionJob(handle));
    var deleted = 0;
    var failed = 0;
    for (final id in plan.dominated) {
      try {
        await _sdk(deleteObjectJob(spaceId, id));
        deleted++;
      } on AnySyncReadOnlyException {
        rethrow;
      } on AnySyncException catch (e) {
        if (_isStatus(e, AnyShimStatus.refused) &&
            e.message.contains('read-only')) {
          rethrow;
        }
        failed++;
      }
    }
    final superseded = await _sweepSupersede(c);
    var repaired = 0;
    final fixed = <String>[];
    // An object no row shows keeps its mark: it may be the winner again
    // (D-R12); its mark goes with the object.
    for (final (id, key) in plan.blank) {
      final row = await _idx(getRowJob(handle, key));
      final content = row?['text'] as String?;
      if (content == null) continue;
      try {
        await _sdk(setBodyJob(spaceId, id, content));
        repaired++;
        fixed.add('b/$id');
      } on AnySyncException {
        failed++;
      }
    }
    if (fixed.isNotEmpty) await _idx(dropStateJob(handle, fixed));
    return AnySyncCompaction._(
      deleted: deleted,
      failed: failed,
      supersedeDeletesRun: superseded,
      bodiesRepaired: repaired,
    );
  });
}
