// Every job the provider sends to the SDK or index isolate, built by a
// top-level function. A closure literal inside an instance method can
// capture `this` (the VM shares one context per scope), and the store or the
// account cannot cross isolates; a closure built here captures exactly its
// parameters, which are plain data.
import 'dart:convert';
import 'dart:typed_data';

import '../native/any_native.dart';
import 'engine.dart' as e;
import 'formats.dart';
import 'reads.dart' as r;

// ------------------------------------------------------------------ SDK

/// Starts the open (claims and lock now: BUSY / REFUSED at once) and waits
/// for `anysyncsdk.Open` in slices. Returns the handle.
SdkJob<int> openAccountJob(
  Map<String, Object?> options, {
  Duration max = const Duration(minutes: 2),
}) => (s) async {
  final op = s.openAccountStart(options);
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    final p = s.opWait(op, 250);
    if (p.done) return s.adoptAccount(p.result!);
    await Future<void>.delayed(Duration.zero);
  }
  // The deadline passed. One last poll: an account the op opened in the
  // meantime is closed again, never left open unowned (D-R9).
  final last = s.opWait(op, 0);
  if (last.done) {
    s.adoptAccount(last.result!);
    final close = s.closeAccountStart();
    await awaitOp(
      s,
      close,
      deadline: DateTime.now().add(const Duration(seconds: 15)),
    );
  } else {
    s.opCancel(op);
  }
  throw AnyShimException(
    'any_shim_account_open_start',
    AnyShimStatus.timeout.code,
    'the SDK did not open within ${max.inSeconds} s',
  );
};

/// Starts the close and waits for it in slices, at most [waitLoadsMs] for
/// space loads in flight plus 15 s for the close itself.
SdkJob<void> closeAccountJob({int waitLoadsMs = 0}) => (s) async {
  final op = s.closeAccountStart(waitLoadsMs: waitLoadsMs);
  final r = await awaitOp(
    s,
    op,
    deadline: DateTime.now().add(Duration(milliseconds: waitLoadsMs + 15000)),
  );
  if (r == null) {
    throw AnyShimException(
      'any_shim_account_close_start',
      AnyShimStatus.timeout.code,
      'the SDK did not close in time; it goes on closing natively',
    );
  }
};

SdkJob<Map<String, Object?>> accountInfoJob() =>
    (s) => s.accountInfo();

SdkJob<Map<String, Object?>> spaceCreateJob(String name) =>
    (s) => s.spaceCreate(name);

SdkJob<Map<String, Object?>> spaceListJob() =>
    (s) => s.spaceList();

SdkJob<Map<String, Object?>> spaceListSyncJob(int timeoutMs) => (s) async {
  final op = s.spaceListSyncStart(timeoutMs);
  // The op has its own deadline; a little slack on top for the answer.
  final res = await awaitOp(
    s,
    op,
    deadline: DateTime.now().add(Duration(milliseconds: timeoutMs + 2000)),
  );
  // The deadline passed: the local list, said to be one.
  return res ?? {...s.spaceList(), 'syncError': 'timed out', 'timedOut': true};
};

/// Resolves a space, waiting at most [waitMs]: `ok`, or `loading` when the
/// wait ended first (the load goes on natively).
SdkJob<String> spaceResolveJob(String spaceId, int waitMs) => (s) async {
  final op = s.spaceResolveStart(spaceId);
  final res = await awaitOp(
    s,
    op,
    deadline: DateTime.now().add(Duration(milliseconds: waitMs)),
  );
  return res == null ? 'loading' : 'ok';
};

SdkJob<Map<String, Object?>> spaceStatusJob(String spaceId) =>
    (s) => s.spaceStatus(spaceId);

/// `{reachedPeer, timedOut, error}`; the deadline passing is a result.
SdkJob<Map<String, Object?>> syncHeadsJob(String spaceId, int timeoutMs) =>
    (s) async {
      if (timeoutMs <= 0) timeoutMs = 1;
      final op = s.syncHeadsStart(spaceId, timeoutMs);
      final res = await awaitOp(
        s,
        op,
        deadline: DateTime.now().add(Duration(milliseconds: timeoutMs + 2000)),
      );
      return res ?? {'reachedPeer': false, 'timedOut': true, 'error': null};
    };

SdkJob<Map<String, Object?>> ragBundlesJob(String spaceId, bool ensure) =>
    (s) => s.ragBundles(spaceId, ensure: ensure);

/// The location's manifest object id, computed without a write (a reader
/// may call it).
SdkJob<String> manifestIdJob(String spaceId, String indexName) =>
    (s) => s.objectDeriveId(spaceId, manifestSeed(indexName))['id']! as String;

SdkJob<ManifestRead> readManifestJob(String spaceId, String manifestId) =>
    (s) => r.readManifest(s, spaceId, manifestId);

SdkJob<Map<String, Object?>> patchJob(
  String spaceId,
  Map<String, Object?> target,
  List<Object?> ops,
) =>
    (s) => s.objectPatch(spaceId, target, ops);

SdkJob<void> setBodyJob(String spaceId, String id, String text) =>
    (s) => s.objectSetBody(spaceId, id, text);

SdkJob<void> deleteObjectJob(String spaceId, String id) =>
    (s) => s.objectDelete(spaceId, id);

SdkJob<String> objectSyncStateJob(String spaceId, String id) =>
    (s) => (s.objectSyncState(spaceId, id)['state'] as String?) ?? 'unknown';

SdkJob<void> recordsModifyJob(
  String spaceId,
  String objectId,
  String collection,
  List<Object?> records,
) =>
    (s) => s.recordsModify(spaceId, objectId, collection, records);

/// `(generation, maxApplySeq)` of the space's change feed.
SdkJob<(String?, int)> feedHeadJob(String spaceId) => (s) {
  final f = s.changesSince(spaceId, 0, limit: 1);
  return (f['generation'] as String?, (f['maxApplySeq'] as int?) ?? 0);
};

SdkJob<int> watchChangesJob(String spaceId) =>
    (s) => s.watchChanges(spaceId);

SdkJob<int> watchSyncStatusJob() =>
    (s) => s.watchSyncStatus();

// ----------------------------------------------------------- pipelines

/// One follower step: the page is read on the SDK isolate and applied on
/// the index isolate; only the outcome comes back.
SdkJob<(e.PageOutcome, bool more)> pullStepJob(
  e.LocConfig cfg,
  int handle, {
  required int fromSeq,
  required String? cursorRaw,
  required String? clearRaw,
  required int tombSeq,
  required bool readTombstones,
  required List<String> extraIds,
  required int nowMs,
  bool shadow = false,
}) => (s) async {
  final page = r.readFollowerPage(
    s,
    cfg,
    fromSeq: fromSeq,
    cursorRaw: cursorRaw,
    clearRaw: clearRaw,
    tombSeq: tombSeq,
    readTombstones: readTombstones,
    extraIds: extraIds,
  );
  final outcome = await _applyConverging(s, cfg, handle, page, nowMs, shadow);
  return (outcome, page.more);
};

/// Applies [page]; when it needs winners it did not carry, reads them (with
/// a synthetic change each, D1) and applies again, a few rounds at most.
Future<e.PageOutcome> _applyConverging(
  AnySdk s,
  e.LocConfig cfg,
  int handle,
  e.Page page,
  int nowMs,
  bool shadow,
) async {
  var p = page;
  var outcome = await s.toIndex(_applyJob(handle, cfg, p, nowMs, shadow));
  final asked = <String>{};
  for (var round = 0; round < 5 && outcome.needObjects.isNotEmpty; round++) {
    final fresh = [
      for (final id in outcome.needObjects)
        if (asked.add(id)) id,
    ];
    if (fresh.isEmpty) break;
    p = r.withObjects(s, cfg, p, asked.toList());
    outcome = await s.toIndex(_applyJob(handle, cfg, p, nowMs, shadow));
  }
  return outcome;
}

IndexJob<e.PageOutcome> _applyJob(
  int handle,
  e.LocConfig cfg,
  e.Page page,
  int nowMs,
  bool shadow,
) =>
    (h) =>
        e.applyPage(h.index(handle), cfg, page, nowMs: nowMs, shadow: shadow);

/// One rebuild page of the document type into the shadow, with its anchor.
SdkJob<({e.PageOutcome outcome, String? generation, int anchor, String? next})>
rebuildPageJob(
  e.LocConfig cfg,
  int handle, {
  required String? after,
  required int nowMs,
}) => (s) async {
  final page = r.readTypePage(s, cfg, after: after);
  final outcome = await _applyConverging(s, cfg, handle, page, nowMs, true);
  return (
    outcome: outcome,
    generation: page.generation,
    anchor: page.maxApplySeq,
    next: page.next,
  );
};

/// The manifest and every tombstone into the shadow (rebuild, first step).
SdkJob<e.PageOutcome> rebuildManifestJob(
  e.LocConfig cfg,
  int handle, {
  required int nowMs,
}) => (s) async {
  final page = r.readManifestPage(s, cfg);
  return s.toIndex(_applyJob(handle, cfg, page, nowMs, true));
};

/// A replay page (rebuild step 3) into the shadow, without the cursor.
SdkJob<({e.PageOutcome outcome, String? generation, int toSeq, bool more})>
replayStepJob(
  e.LocConfig cfg,
  int handle, {
  required int fromSeq,
  required List<String> extraIds,
  required int nowMs,
}) => (s) async {
  final page = r.readFollowerPage(
    s,
    cfg,
    fromSeq: fromSeq,
    cursorRaw: null,
    clearRaw: null,
    tombSeq: 0,
    readTombstones: false,
    extraIds: extraIds,
  );
  final noCursor = e.Page(
    generation: page.generation,
    maxApplySeq: page.maxApplySeq,
    fromSeq: page.fromSeq,
    changes: page.changes,
    items: page.items,
  );
  final outcome = await _applyConverging(s, cfg, handle, noCursor, nowMs, true);
  return (
    outcome: outcome,
    generation: page.generation,
    toSeq: page.toSeq,
    more: page.more,
  );
};

// ---------------------------------------------------------------- index

IndexJob<int> indexOpenJob(Map<String, Object?> options) =>
    (h) => h.open(options);

/// Starts the close and waits for it in slices.
IndexJob<void> indexCloseJob(int handle) => (h) async {
  final op = h.index(handle).closeStart();
  final r = await awaitOp(
    h,
    op,
    deadline: DateTime.now().add(const Duration(minutes: 1)),
  );
  if (r == null) {
    throw AnyShimException(
      'any_shim_index_close_start',
      AnyShimStatus.timeout.code,
      'the index did not close within 1 min',
    );
  }
};

/// Binds (a growing bind backfills every row, so it is an op) and returns
/// the bound configuration.
IndexJob<Map<String, Object?>> indexBindJob(
  int handle,
  Map<String, Object?> config,
) => (h) async {
  final op = h.index(handle).bindStart(config);
  return (await awaitOp(h, op))!;
};

/// One bounded round of dropping orphan generations; whether all are gone.
IndexJob<bool> indexGcJob(int handle) =>
    (h) => h.index(handle).gc(200)['done'] == true;

/// Documents written under a binding the manifest does not have.
IndexJob<int> conflictingDocumentsJob(int handle) => (h) {
  var n = 0;
  e.scanAll(h.index(handle), 'u/', (k, v) {
    if ((jsonDecode(v) as Map)['r'] == 'conflictingBinding') n++;
  });
  return n;
};

IndexJob<Map<String, Object?>> indexInfoJob(int handle) =>
    (h) => h.index(handle).info();

IndexJob<String?> getStateJob(int handle, String key) =>
    (h) => h.index(handle).getState(key);

IndexJob<Map<String, String?>> getStatesJob(int handle, List<String> keys) =>
    (h) {
      final x = h.index(handle);
      return {for (final k in keys) k: x.getState(k)};
    };

IndexJob<void> setStatesJob(int handle, Map<String, String?> values) => (h) {
  final tx = e.Tx(h.index(handle));
  for (final MapEntry(:key, :value) in values.entries) {
    tx.set(key, value);
  }
  tx.commit();
};

IndexJob<({String? cursorRaw, String? clearRaw, int tombSeq, bool fresh})>
followStateJob(int handle) =>
    (h) => e.readFollowState(h.index(handle));

IndexJob<({e.AddPlan plan, String? objectId})> planAddJob(
  int handle,
  String key,
  String ch,
  String mh,
) =>
    (h) => e.planAdd(h.index(handle), key, ch, mh);

IndexJob<int> allocateWriteRevJob(int handle, int nowMs) =>
    (h) => e.allocateWriteRev(h.index(handle), nowMs);

IndexJob<void> checkWritableJob(int handle) =>
    (h) => e.checkWritable(e.Tx(h.index(handle)));

IndexJob<void> applyOwnAddJob(
  int handle,
  e.LocConfig cfg, {
  required String key,
  required String objectId,
  required int rev,
  required String content,
  required String? meta,
  required Float32List vector,
  required int nowMs,
}) =>
    (h) => e.applyOwnAdd(
      h.index(handle),
      cfg,
      key: key,
      objectId: objectId,
      rev: rev,
      content: content,
      meta: meta,
      vector: vector,
      nowMs: nowMs,
    );

IndexJob<void> markBlankBodyJob(int handle, String objectId, String key) =>
    (h) => e.markBlankBody(h.index(handle), objectId, key);

IndexJob<e.LeafCheck> checkLeafJob(
  int handle,
  String key,
  String objectId,
  String ch,
) =>
    (h) => e.checkLeafTarget(
      h.index(handle),
      key: key,
      objectId: objectId,
      ch: ch,
    );

IndexJob<bool> applyLeafJob(
  int handle,
  e.LocConfig cfg,
  String key,
  String objectId,
  String ch,
  Float32List vector,
) =>
    (h) => e.applyLeaf(
      h.index(handle),
      cfg,
      key: key,
      objectId: objectId,
      ch: ch,
      vector: vector,
    );

IndexJob<List<String>> applyRemoveJob(int handle, String key, int rev) =>
    (h) => e.applyRemove(h.index(handle), key, rev);

IndexJob<List<String>> applyClearJob(int handle, int rev, int nowMs) =>
    (h) => e.applyClear(h.index(handle), rev, nowMs: nowMs);

IndexJob<Map<String, Object?>> knnJob(
  int handle,
  Float32List query,
  int k,
  Map<String, Object?>? filter,
) =>
    (h) => h.index(handle).knn(query, k, filter);

IndexJob<Map<String, Object?>> textJob(
  int handle,
  String query,
  int k,
  Map<String, Object?>? filter,
) =>
    (h) => h.index(handle).text(query, k, filter);

IndexJob<(int, int)> countsJob(int handle) => (h) {
  final x = h.index(handle);
  return (x.count(), x.countVectors());
};

IndexJob<void> flushJob(int handle) =>
    (h) => h.index(handle).flush(250);

IndexJob<({List<Map<String, Object?>> items, String? next})> readMissingJob(
  int handle,
  String? after,
  int limit,
) =>
    (h) => e.readMissing(h.index(handle), after: after, limit: limit);

IndexJob<Map<String, Object?>> readStatusJob(int handle, int nowMs) =>
    (h) => e.readStatus(h.index(handle), nowMs: nowMs);

IndexJob<
  ({
    List<String> dominated,
    List<(String, String)> supersede,
    List<(String, String)> blank,
    List<String> blankStale,
  })
>
planCompactionJob(int handle) =>
    (h) => e.planCompaction(h.index(handle));

IndexJob<void> dropStateJob(int handle, List<String> keys) =>
    (h) => e.dropState(h.index(handle), keys);

IndexJob<Map<String, Object?>?> getRowJob(int handle, String id) =>
    (h) => h.index(handle).getRow(id);

IndexJob<void> beginShadowJob(int handle) =>
    (h) => e.beginShadow(h.index(handle));

IndexJob<void> carryOwnJob(int handle) =>
    (h) => e.carryOwn(h.index(handle));

IndexJob<void> swapShadowJob(int handle, String? generation, int seq) =>
    (h) => e.swapShadow(h.index(handle), generation: generation, seq: seq);

IndexJob<void> markRebuildingJob(int handle, int? since) =>
    (h) => e.markRebuilding(h.index(handle), since);

/// This device's superseded objects waiting for their successor to sync:
/// `(old, new)`.
IndexJob<List<(String, String)>> supersedeListJob(int handle) => (h) {
  final out = <(String, String)>[];
  e.scanAll(h.index(handle), 's/', (k, v) {
    out.add((k.substring(2), (jsonDecode(v) as Map)['new'] as String));
  });
  return out;
};
