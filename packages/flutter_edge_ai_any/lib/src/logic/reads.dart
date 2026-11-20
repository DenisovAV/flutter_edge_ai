// The SDK side of the follower and the rebuild: what a page reads before it
// goes to the index isolate. Each function runs inside one SDK job.
import 'engine.dart';
import 'formats.dart';
import '../native/any_native.dart';

/// The properties a document read returns.
const docXkeys = ['doc', 'vecs'];

/// The properties a manifest read returns.
const manifestXkeys = ['core', 'fields', 'profiles', 'textSearch'];

/// The largest id list one object_read takes here.
const _readChunk = 100;

/// Reads [ids] (in chunks) with [xkeys].
Map<String, ObjItem> readObjects(
  AnySdk sdk,
  String spaceId,
  Iterable<String> ids,
  List<String> xkeys,
) {
  final out = <String, ObjItem>{};
  final list = ids.toList();
  for (var i = 0; i < list.length; i += _readChunk) {
    final chunk = list.sublist(
      i,
      i + _readChunk > list.length ? list.length : i + _readChunk,
    );
    final r = sdk.objectRead(spaceId, {'ids': chunk, 'xkeys': xkeys});
    for (final item in (r['items'] as List? ?? const [])) {
      final o = ObjItem.fromJson((item as Map).cast());
      out[o.id] = o;
    }
  }
  return out;
}

/// The location's manifest as this device has it.
ManifestRead readManifest(AnySdk sdk, String spaceId, String manifestId) {
  final items = readObjects(sdk, spaceId, [manifestId], manifestXkeys);
  final m = items[manifestId];
  if (m == null || m.state != 'ok') return ManifestRead.absent;
  return ManifestRead.fromProps(m.props);
}

/// Every tombstone record changed after [since], and the largest
/// `_applySeq` among them (or [since]).
({List<Map<String, Object?>> records, int seq}) readTombs(
  AnySdk sdk,
  LocConfig cfg, {
  required int since,
}) {
  final records = <Map<String, Object?>>[];
  var seq = since;
  String? after;
  do {
    final r = sdk.recordsRead(
      cfg.spaceId,
      cfg.manifestId,
      cfg.tombColl,
      after: after,
      sinceApplySeq: since,
      limit: 500,
    );
    for (final rec in (r['records'] as List? ?? const [])) {
      final m = (rec as Map).cast<String, Object?>();
      records.add(m);
      final s = m['_applySeq'];
      if (s is int && s > seq) seq = s;
    }
    after = r['next'] as String?;
  } while (after != null);
  return (records: records, seq: seq);
}

/// One follower page from [fromSeq] (design §3, §4.1): the changes, the
/// objects they name (plus [extraIds], winners an earlier attempt needed),
/// and, when [readTombstones] or the manifest object changed, the manifest
/// and the tombstones written since [tombSeq].
Page readFollowerPage(
  AnySdk sdk,
  LocConfig cfg, {
  required int fromSeq,
  required String? cursorRaw,
  required String? clearRaw,
  required int tombSeq,
  required bool readTombstones,
  List<String> extraIds = const [],
  int limit = 200,
}) {
  final feed = sdk.changesSince(cfg.spaceId, fromSeq, limit: limit);
  final generation = feed['generation'] as String?;
  final maxApplySeq = (feed['maxApplySeq'] as int?) ?? 0;
  final changes = [
    for (final c in (feed['changes'] as List? ?? const []))
      ChangeItem(
        (c as Map)['objectId']! as String,
        c['applySeq']! as int,
        c['deleted'] == true,
      ),
  ];
  final more = changes.length >= limit;
  var toSeq = fromSeq;
  if (changes.isNotEmpty && changes.last.applySeq > toSeq) {
    toSeq = changes.last.applySeq;
  }
  // The whole feed was read: the cursor may stand at its end.
  if (!more && maxApplySeq > toSeq) toSeq = maxApplySeq;
  final ids = <String>{
    for (final c in changes)
      if (!c.deleted && c.objectId != cfg.manifestId) c.objectId,
    ...extraIds,
  };
  final items = readObjects(sdk, cfg.spaceId, ids, docXkeys);
  final all = withExtras(changes, extraIds);
  final manifestChanged =
      readTombstones || changes.any((c) => c.objectId == cfg.manifestId);
  ManifestRead? manifest;
  ({List<Map<String, Object?>> records, int seq})? tombs;
  if (manifestChanged) {
    manifest = readManifest(sdk, cfg.spaceId, cfg.manifestId);
    tombs = readTombs(sdk, cfg, since: tombSeq);
  }
  return Page(
    generation: generation,
    maxApplySeq: maxApplySeq,
    fromSeq: fromSeq,
    toSeq: toSeq,
    cursorRaw: cursorRaw,
    clearRaw: clearRaw,
    changes: all,
    items: items,
    manifest: manifest,
    tombs: tombs?.records,
    tombSeq: tombs?.seq,
    more: more,
  );
}

/// [changes] with a synthetic entry in front for each extra object a page
/// carries that the feed did not name (a winner an earlier attempt needed),
/// so applyPage judges it like any other (D1); a deleted one is forgotten.
List<ChangeItem> withExtras(List<ChangeItem> changes, List<String> extraIds) {
  if (debugEngineMutations.contains('extrasNotApplied')) return changes;
  final named = {for (final c in changes) c.objectId};
  return [
    for (final id in extraIds)
      if (!named.contains(id)) ChangeItem(id, 0, false),
    ...changes,
  ];
}

/// Adds [ids] to [page]: their objects and a synthetic change each.
Page withObjects(AnySdk sdk, LocConfig cfg, Page page, List<String> ids) {
  final items = {
    ...page.items,
    ...readObjects(sdk, cfg.spaceId, ids, docXkeys),
  };
  return Page(
    generation: page.generation,
    maxApplySeq: page.maxApplySeq,
    fromSeq: page.fromSeq,
    toSeq: page.toSeq,
    cursorRaw: page.cursorRaw,
    clearRaw: page.clearRaw,
    changes: withExtras(page.changes, ids),
    items: items,
    manifest: page.manifest,
    tombs: page.tombs,
    tombSeq: page.tombSeq,
    more: page.more,
    next: page.next,
  );
}

/// One page of the location's document type, by object id, for a rebuild
/// (design §3 step 2). Its generation and maxApplySeq are the anchor
/// object_read read before the page.
Page readTypePage(
  AnySdk sdk,
  LocConfig cfg, {
  required String? after,
  int limit = 100,
}) {
  final r = sdk.objectRead(cfg.spaceId, {
    'type': cfg.docRoot,
    'after': ?after,
    'limit': limit,
    'xkeys': docXkeys,
  });
  final anchor = (r['anchor'] as Map?) ?? const {};
  final items = <String, ObjItem>{};
  final changes = <ChangeItem>[];
  for (final item in (r['items'] as List? ?? const [])) {
    final o = ObjItem.fromJson((item as Map).cast());
    items[o.id] = o;
    changes.add(ChangeItem(o.id, 0, o.state == 'deleted'));
  }
  return Page(
    generation: anchor['generation'] as String?,
    maxApplySeq: (anchor['maxApplySeq'] as int?) ?? 0,
    changes: changes,
    items: items,
    next: r['next'] as String?,
  );
}

/// The manifest and every tombstone record, for the start of a rebuild.
Page readManifestPage(AnySdk sdk, LocConfig cfg) {
  final manifest = readManifest(sdk, cfg.spaceId, cfg.manifestId);
  final tombs = readTombs(sdk, cfg, since: 0);
  return Page(
    generation: null,
    maxApplySeq: 0,
    changes: const [],
    items: const {},
    manifest: manifest,
    tombs: tombs.records,
    tombSeq: tombs.seq,
  );
}
