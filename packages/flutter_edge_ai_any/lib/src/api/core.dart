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
  int ownerEpoch = 0;
  bool _closed = false;
  bool _following = false;
  Timer? _debounce;

  String get spaceId => location.spaceId;

  Future<T> _idx<T>(IndexJob<T> job) => account._index(job, spaceId: spaceId);

  Future<T> _sdk<T>(SdkJob<T> job) => account._sdk(job, spaceId: spaceId);

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
    if (b != null) binding = _bindingFrom((jsonDecode(b) as Map).cast());
    if (c != null) cfg = LocConfig.fromJson((jsonDecode(c) as Map).cast());
    final info = await _idx(indexInfoJob(h));
    textSearch = info['textSearch'] == true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopFollower();
    // Waits for the write or page in flight, then closes the file.
    await _lock.run(() async {
      try {
        await account._rt.index(indexCloseJob(handle));
      } on Object {
        // The finalizer-shaped release is the backstop; detaching it would
        // leak the handle if the close failed.
        return;
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

  /// `initialize` (design §2.1: it only reads): resolves the space, starts a
  /// new file's first pull, and when this device bound the location before,
  /// brings the local index to [schema] and starts the follower.
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
    final next = LocConfig.fromJson(
      c.toJson(),
      schema: _union(c.schema, schema),
    );
    await _lock.run(() async {
      await _bindIndex(next, enableText: enableText);
      if (grown) {
        // Publishing the new field leaves is the one write an open makes:
        // the schema is a union (design §2.1, D4), and the open is where
        // this device learns it grew.
        await _publishMissing(next, b, readOnlyOk: true);
        await _rebuildLocked();
      }
    });
    _startFollower();
    await _catchUp();
  }

  static bool _schemaGrows(FilterSchema have, FilterSchema want) =>
      want.fields.any((f) => have.fieldFor(f.name)?.type != f.type);

  /// [have] plus the fields of [want] it lacks (a name declared with
  /// another type keeps both, and the conflict check refuses it).
  static FilterSchema _union(FilterSchema have, FilterSchema want) {
    final fields = [...have.fields];
    for (final f in want.fields) {
      if (!fields.any((x) => x.name == f.name && x.type == f.type)) {
        fields.add(f);
      }
    }
    // FilterSchema refuses duplicate names; keep the stored type then.
    final seen = <String>{};
    return FilterSchema(
      fields: [
        for (final f in fields)
          if (seen.add(f.name)) f,
      ],
    );
  }

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
    await _idx(setStatesJob(handle, {'cfg': jsonEncode(c.toJson())}));
    cfg = c;
  }

  /// `bind` (design §2.1): the bundles, the publish gate or the conflict
  /// check, then the local binding and the follower.
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
        if (_isStatus(e, AnyShimStatus.notFound)) {
          throw AnySyncNotReadyException._(
            spaceId,
            AnySyncNotReadyReason.definitionsNotSynced,
          );
        }
        rethrow;
      }
      final loc = (bundles['location']! as Map).cast<String, Object?>();
      final doc = (bundles['document']! as Map).cast<String, Object?>();
      final locRoot = loc['rootId']! as String;
      final String manifestId;
      try {
        manifestId = await _sdk(
          manifestIdJob(spaceId, location.indexName, locRoot),
        );
      } on AnySyncReadOnlyException {
        throw AnySyncReadOnlyException._(
          'this account cannot derive the manifest of ${location.value}',
        );
      }
      final c = LocConfig(
        spaceId: spaceId,
        indexName: location.indexName,
        docRoot: doc['rootId']! as String,
        manifestId: manifestId,
        tombColl: loc['tombstones']! as String,
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
            0,
            [for (final r in refusal['reasons']! as List) r as String],
          );
        }
      }
      final published = await _publishMissing(
        c,
        b,
        manifest: manifest,
        enableText: enableText,
        readOnly: readOnly,
      );
      await _idx(
        setStatesJob(handle, {
          'binding': jsonEncode(_bindingJson(b)),
          'manifest': jsonEncode(published.toJson()),
        }),
      );
      await _bindIndex(c, enableText: enableText);
      binding = b;
    });
    _startFollower();
    await _catchUp();
  }

  Future<Map<String, Object?>> _readBundles() async {
    try {
      return await _sdk(ragBundlesJob(spaceId, false));
    } on AnySyncException catch (e) {
      if (_isStatus(e, AnyShimStatus.notFound)) {
        throw AnySyncNotReadyException._(
          spaceId,
          AnySyncNotReadyReason.definitionsNotSynced,
        );
      }
      rethrow;
    }
  }

  static bool _isStatus(AnySyncException e, AnyShimStatus s) {
    final c = e.cause;
    return c is AnyShimException && c.status == s;
  }

  /// The publish gate (design §2.1) for a manifest without `core`: returns
  /// the manifest to bind against, `present: false` meaning "publish it".
  Future<ManifestRead> _gate(LocConfig c, ManifestRead absent) async {
    final status = AnySyncStatus._fromJson(await _sdk(spaceStatusJob(spaceId)));
    // Creator exception (S3): no peer ever synced this space here, so no
    // manifest can have reached this device.
    if (!status.everPeerSynced) return absent;
    final wait = account._spaceOpenWait;
    final heads = await _sdk(syncHeadsJob(spaceId, wait.inMilliseconds));
    if (heads['reachedPeer'] == true) {
      final deadline = DateTime.now().add(wait);
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
    throw AnySyncNotReadyException._(
      spaceId,
      AnySyncNotReadyReason.manifestNotSynced,
      'no peer answered',
    );
  }

  /// Writes the manifest leaves this binding needs and [manifest] lacks
  /// (all of them, with `core`, when it is absent); returns the manifest as
  /// published.
  Future<ManifestRead> _publishMissing(
    LocConfig c,
    VectorStoreBinding b, {
    ManifestRead? manifest,
    bool enableText = false,
    bool readOnly = false,
    bool readOnlyOk = false,
  }) async {
    final ManifestRead m =
        manifest ??
        await _sdk<ManifestRead>(readManifestJob(spaceId, c.manifestId));
    final ops = <Map<String, Object?>>[];
    if (!m.present) {
      ops.add({'xkey': 'core', 'value': encodeCore(c.documents)});
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
    if (enableText && !m.textSearch) {
      ops.add({'xkey': 'textSearch', 'value': true});
    }
    if (ops.isEmpty) return m;
    if (readOnly) {
      if (readOnlyOk) return m;
      throw AnySyncReadOnlyException._(
        '${location.value} needs manifest entries this account cannot write',
      );
    }
    try {
      await _sdk(patchJob(spaceId, {'id': c.manifestId}, ops));
    } on AnySyncReadOnlyException {
      if (readOnlyOk) return m;
      rethrow;
    } on AnySyncException catch (e) {
      if (_isStatus(e, AnyShimStatus.notFound)) {
        throw AnySyncNotReadyException._(
          spaceId,
          AnySyncNotReadyReason.definitionsNotSynced,
        );
      }
      rethrow;
    }
    return ManifestRead(
      present: true,
      documents: m.present ? m.documents : c.documents,
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
  }

  /// A change event: pull after 200 ms of quiet (design §4.1).
  void onChange() {
    if (!_following || _closed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      _debounce = null;
      if (account._state != AnySyncAccountState.open) return;
      pull().ignore();
    });
  }

  /// The catch-up after open: a failure here (suspended, a peer gone) is
  /// not the open's, and the next change or explicit pull retries.
  Future<void> _catchUp() async {
    try {
      await pull();
    } on AnySyncException {
      // Reported by the next call that needs it.
    }
  }

  /// One pull (design §3): follower pages until the feed is exhausted,
  /// rebuilding when the generation moved, then the supersede deletes that
  /// became safe.
  Future<AnySyncPull> pull() => _lock.run(() async {
    final c = cfg;
    if (c == null || binding == null || _closed) return AnySyncPull._();
    var result = AnySyncPull._();
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
          nowMs: _nowMs(),
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
      } on AnySyncException catch (e) {
        if (_isStatus(e, AnyShimStatus.deleted) ||
            _isStatus(e, AnyShimStatus.notFound)) {
          done.add('s/$old');
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
    final since = _nowMs();
    await _idx(markRebuildingJob(handle, since));
    for (var attempt = 0; attempt < 5; attempt++) {
      await _idx(beginShadowJob(handle));
      await _sdk(rebuildManifestJob(c, handle, nowMs: _nowMs()));
      String? after;
      String? gen;
      int? anchor;
      var moved = false;
      do {
        final p = await _sdk(
          rebuildPageJob(c, handle, after: after, nowMs: _nowMs()),
        );
        if (anchor == null) {
          gen = p.generation;
          anchor = p.anchor;
        } else if (p.generation != gen) {
          moved = true;
          break;
        }
        after = p.next;
      } while (after != null);
      if (moved) continue;
      final (hwGen, hw) = await _sdk(feedHeadJob(spaceId));
      if (hwGen != gen) continue;
      var seq = anchor;
      var extra = <String>[];
      while (seq < hw) {
        final s = await _sdk(
          replayStepJob(
            c,
            handle,
            fromSeq: seq,
            extraIds: extra,
            nowMs: _nowMs(),
          ),
        );
        if (s.generation != gen) {
          moved = true;
          break;
        }
        if (s.outcome.needObjects.isNotEmpty) {
          if (s.outcome.needObjects.every(extra.contains)) {
            throw StateError(
              '${location.value}: objects ${s.outcome.needObjects} cannot be '
              'read',
            );
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
      return AnySyncPull._()._rebuilt();
    }
    throw AnySyncException(
      '${location.value}: the space generation kept moving during a rebuild',
      retryable: true,
    );
  }

  // --------------------------------------------------------------- writes

  Never _refused(WriteRefused w, StackTrace st) {
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
    Error.throwWithStackTrace(
      AnySyncConflictException._(
        AnySyncManifest._fromJson({...j, 'present': true}),
        0,
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
        _refused(w, st);
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
      try {
        await _sdk(
          patchJob(
            spaceId,
            {'id': id},
            [
              {'xkey': 'vecs', 'leaf': c.profileKey, 'value': leaf},
            ],
          ),
        );
        await _idx(applyLeafJob(handle, c, key, id, ch, vector));
        return;
      } on AnySyncException catch (e) {
        // The winner was deleted meanwhile: the caller asked to add.
        if (!_isStatus(e, AnyShimStatus.deleted)) rethrow;
      }
    }
    final rev = await _idx(allocateWriteRevJob(handle, _nowMs()));
    final doc = DocValue.encode(
      loc: c.indexName,
      key: key,
      rev: rev,
      mod: c.documents,
      content: content,
      meta: meta,
    );
    final created = await _sdk(
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
          nowMs: _nowMs(),
        ),
      );
    } catch (e) {
      throw AnySyncCommittedException._(key, rev, id, e);
    }
    try {
      await _sdk(setBodyJob(spaceId, id, content));
    } on Object {
      try {
        await _idx(markBlankBodyJob(handle, id, key));
      } on Object {
        // Counted on the next compact's scan instead.
      }
    }
  });

  /// Remove (design §2.3): a tombstone rev, then the local delete, then
  /// this device's older objects of the key.
  Future<void> remove(String key) => _write((c) async {
    final rev = await _idx(allocateWriteRevJob(handle, _nowMs()));
    await _sdk(
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
    final rev = await _idx(allocateWriteRevJob(handle, _nowMs()));
    await _sdk(
      recordsModifyJob(spaceId, c.manifestId, c.tombColl, [
        {
          'id': clearRecordId,
          'addToSet': {'revs': rev},
        },
      ]),
    );
    final List<String> doomed;
    try {
      doomed = await _idx(applyClearJob(handle, rev, _nowMs()));
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
      if (v.any((x) => !x.isFinite)) {
        t.failed.add(AnySyncVectorFailure._(item.key, 'not finite'));
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
        await _sdk(
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
      final ok = await _idx(
        applyLeafJob(handle, c, item.key, item._objectId, item.contentHash, v),
      );
      if (ok) {
        t.written++;
      } else {
        t.changed++;
      }
    }
    return t;
  });

  // ------------------------------------------------------------ reading

  Future<AnySyncMissingVectors> missing(String? after, int limit) async {
    final c = requireCfg();
    final page = await _idx(readMissingJob(handle, after, limit));
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
    final now = _nowMs();
    final j = await _idx(readStatusJob(handle, now));
    return AnySyncLocationStatus._fromJson(j, now);
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
    for (final (id, key) in plan.blank) {
      // A superseded object gets no body: it is about to go.
      if (plan.dominated.contains(id)) {
        fixed.add('b/$id');
        continue;
      }
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
