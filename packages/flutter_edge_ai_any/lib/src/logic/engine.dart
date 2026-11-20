// The index side of the provider: the local state of one location (design
// §3) and every rule that changes it. Each function here runs inside ONE
// index job (on the index isolate, or in the caller with the fake) and
// commits at most ONE index_apply, so rows, key map, tombstones, HLC and
// cursor move together.
//
// State keys (collection `state`, or `shadowState` during a rebuild):
//
//   binding       this device's binding (readBinding)
//   cfg           the location's config: bundle ids, manifest id, profile
//   cursor        {"g": generation, "s": applySeq} of the follower
//   clear         the largest clear rev seen
//   hlc           the largest rev seen or written (persisted before writes)
//   firstPull     {"t": target applySeq, "d": done}
//   tombSeq       the records _applySeq the tombstones were read to
//   manifest      the last manifest read (ManifestRead.toJson)
//   conflict      the manifest facts when they refuse this binding
//   ahead         {"n": count, "lead": largest lead ms} of revs ahead of clock
//   lastPull      ms of the last follower page
//   rebuilding    ms since a rebuild started
//   tombIgnored   tombstone records whose id is not sha256(key), and revs
//                 out of range
//   needsRebuild  set with a grown schema; a swap clears it
//   k/<key>       {"t": tomb rev, "row": objectId|null, "o": {id: obj}}
//   o/<id>        the key the object belongs to
//   u/<id>        {"r": reason, "k": key?, "v": rev?, "at": ms}  unindexable
//   p/<id>        {"at": ms}                                     pending
//   s/<id>        {"new": id, "k": key, "at": ms}  supersede delete waiting
//   b/<id>        {"k": key}                       body not written
//   m/<key>       {"id": objectId, "c": ch}        row without this vector
//   d/<key>       n: filter values the row's meta dropped (wrong type)
//
// An object entry `obj`: {"r": rev, "o": own, "s": "ok"|"newer"|"conflict",
// "c": sha256(content), "m": metaHash, "l": leaf kind, "lc": leaf ch}.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import '../native/any_native.dart';
import 'filter_mongo.dart';
import 'formats.dart';

// ------------------------------------------------------------- the config

/// What every job needs to know about a bound location. Plain data.
final class LocConfig {
  LocConfig({
    required this.spaceId,
    required this.indexName,
    required this.docRoot,
    required this.manifestId,
    required this.tombColl,
    required this.locRoot,
    required this.profileId,
    required this.dimension,
    required this.documents,
    required this.schema,
  });

  final String spaceId;
  final String indexName;
  final String docRoot;
  final String manifestId;
  final String tombColl;

  /// The location bundle's root type (the manifest's type).
  final String locRoot;
  final String profileId;
  final int dimension;

  /// `text`, `image` or `audio`.
  final String documents;
  final FilterSchema schema;

  String get v1RecordId =>
      documents == 'text' ? profileId : '$profileId\u001F$documents';

  /// `<h>`: the vecs leaf of this device's profile.
  String get profileKey => profileLeafKey(v1RecordId, dimension);

  Map<String, Object?> toJson() => {
    'spaceId': spaceId,
    'indexName': indexName,
    'docRoot': docRoot,
    'manifestId': manifestId,
    'tombColl': tombColl,
    'locRoot': locRoot,
    'profileId': profileId,
    'dimension': dimension,
    'documents': documents,
    'fields': [
      for (final f in schema.fields) {'name': f.name, 'type': f.type.name},
    ],
  };

  static LocConfig fromJson(Map<String, Object?> j, {FilterSchema? schema}) =>
      LocConfig(
        spaceId: j['spaceId']! as String,
        indexName: j['indexName']! as String,
        docRoot: j['docRoot']! as String,
        manifestId: j['manifestId']! as String,
        tombColl: j['tombColl']! as String,
        locRoot: j['locRoot'] as String? ?? '',
        profileId: j['profileId']! as String,
        dimension: j['dimension']! as int,
        documents: j['documents']! as String,
        schema:
            schema ??
            FilterSchema(
              fields: [
                for (final f in (j['fields'] as List? ?? const []))
                  FilterField(
                    name: (f as Map)['name'] as String,
                    type: FilterFieldType.values.byName(f['type'] as String),
                  ),
              ],
            ),
      );
}

/// Mutation-test seam: each name disables one rule, so test/unit's
/// mutation suite can show that the rule's own test fails without it. Read
/// in the isolate the job runs in, so it works with the in-memory fake
/// only. Never set outside tests.
final Set<String> debugEngineMutations = {};

bool _mutated(String rule) => debugEngineMutations.contains(rule);

/// Thrown inside a job when a rev would pass [maxRev].
final class ClockExhausted implements Exception {
  const ClockExhausted();
}

/// Thrown inside a write job when the location cannot take writes yet.
final class WriteRefused implements Exception {
  const WriteRefused(this.reason, [this.detail]);

  /// `firstPullPending` or `conflict`.
  final String reason;
  final String? detail;
}

// ----------------------------------------------------------------- the tx

/// One index_apply in the making, with reads that see its own writes.
final class Tx {
  Tx(this.idx, {this.shadow = false});

  final AnyIndexApi idx;
  final bool shadow;
  final _overlay = <String, String?>{};
  final _ops = <Map<String, Object?>>[];
  final _cas = <Map<String, Object?>>[];
  final _vectors = <Float32List>[];
  int _floats = 0;

  String get _stateColl => shadow ? 'shadowState' : 'state';
  String get _docsColl => shadow ? 'shadow' : 'docs';

  String? get(String key) => _overlay.containsKey(key)
      ? _overlay[key]
      : idx.getState(key, shadow: shadow);

  Map<String, Object?>? getJson(String key) {
    final v = get(key);
    return v == null ? null : (jsonDecode(v) as Map).cast<String, Object?>();
  }

  int getInt(String key) => int.tryParse(get(key) ?? '') ?? 0;

  void set(String key, String? value) {
    _overlay[key] = value;
    _ops.add({
      'op': 'stateSet',
      'coll': _stateColl,
      'key': key,
      'value': value,
    });
  }

  void setJson(String key, Object? value) =>
      set(key, value == null ? null : jsonEncode(value));

  void expect(String key, String? value) =>
      _cas.add({'key': key, 'expect': value});

  void upsertRow({
    required String id,
    required String text,
    required String? meta,
    required Map<String, Object?> f,
    required Float32List? vector,
  }) {
    Map<String, Object?>? slot;
    if (vector != null) {
      slot = {'offset': _floats, 'dim': vector.length};
      _vectors.add(vector);
      _floats += vector.length;
    }
    _ops.add({
      'op': 'upsert',
      'coll': _docsColl,
      'id': id,
      'text': text,
      'meta': meta,
      'f': f,
      'vector': slot,
    });
  }

  void deleteRow(String id) =>
      _ops.add({'op': 'delete', 'coll': _docsColl, 'id': id});

  void clearDocs() => _ops.add({'op': 'clearDocs', 'coll': _docsColl});

  void raw(Map<String, Object?> op) => _ops.add(op);

  bool get isEmpty => _ops.isEmpty;

  /// Commits; a CAS miss throws [AnyShimException] (conflict).
  void commit() {
    if (_ops.isEmpty && _cas.isEmpty) return;
    final buffer = Float32List(_floats);
    var at = 0;
    for (final v in _vectors) {
      buffer.setAll(at, v);
      at += v.length;
    }
    idx.apply({'cas': _cas, 'ops': _ops}, buffer);
  }
}

// ------------------------------------------------------------ the key map

/// One object of a key.
final class ObjEntry {
  ObjEntry({
    required this.rev,
    required this.own,
    required this.status,
    this.ch,
    this.mh,
    this.leaf = 'missing',
    this.leafCh,
  });

  final int rev;
  bool own;

  /// `ok`, `newer` (higher fmt) or `conflict` (another `mod`).
  final String status;
  final String? ch;
  final String? mh;

  /// LeafKind name of this device's profile leaf.
  String leaf;
  String? leafCh;

  Map<String, Object?> toJson() => {
    'r': rev,
    'o': own,
    's': status,
    'c': ?ch,
    'm': ?mh,
    'l': leaf,
    'lc': ?leafCh,
  };

  static ObjEntry fromJson(Map<String, Object?> j) => ObjEntry(
    rev: j['r']! as int,
    own: j['o'] == true,
    status: j['s']! as String,
    ch: j['c'] as String?,
    mh: j['m'] as String?,
    leaf: j['l'] as String? ?? 'missing',
    leafCh: j['lc'] as String?,
  );
}

/// The objects of one key, its tombstone rev and the object its row shows.
final class KeyEntry {
  KeyEntry({this.tomb = 0, this.row, Map<String, ObjEntry>? objs})
    : objs = objs ?? {};

  int tomb;
  String? row;
  final Map<String, ObjEntry> objs;

  bool get isEmpty => objs.isEmpty && tomb == 0 && row == null;

  /// Highest rev, then the smaller object id (design §2.4).
  String? get winner {
    String? best;
    for (final MapEntry(:key, :value) in objs.entries) {
      if (best == null) {
        best = key;
        continue;
      }
      final b = objs[best]!;
      final smaller = _mutated('tieBreakLargerId')
          ? key.compareTo(best) > 0
          : key.compareTo(best) < 0;
      if (value.rev > b.rev || (value.rev == b.rev && smaller)) {
        best = key;
      }
    }
    return best;
  }

  /// The winner when it is visible: its rev is above the key's tombstone
  /// and the clear rev. Its status may still make it unindexable.
  String? visibleWinner(int clear) {
    final w = winner;
    if (w == null) return null;
    final r = objs[w]!.rev;
    final t = _mutated('ignoreTombstone') ? 0 : tomb;
    final c = _mutated('ignoreClear') ? 0 : clear;
    return r > t && r > c ? w : null;
  }

  /// Objects that are not the visible winner: losers, or below the
  /// tombstone or the clear rev.
  Iterable<String> dominated(int clear) {
    final v = visibleWinner(clear);
    return objs.keys.where((id) => id != v);
  }

  Map<String, Object?> toJson() => {
    't': tomb,
    'row': row,
    'o': {for (final e in objs.entries) e.key: e.value.toJson()},
  };

  static KeyEntry fromJson(Map<String, Object?> j) => KeyEntry(
    tomb: j['t'] as int? ?? 0,
    row: j['row'] as String?,
    objs: {
      for (final e in ((j['o'] as Map?) ?? const {}).entries)
        e.key as String: ObjEntry.fromJson((e.value as Map).cast()),
    },
  );
}

/// Upserts [key]'s row with its meta normalised into `f.*`, and keeps the
/// count of the values that normalising dropped (`d/<key>`).
void upsertDoc(
  Tx tx,
  LocConfig cfg, {
  required String key,
  required String text,
  required String? meta,
  required Float32List? vector,
}) {
  final n = normaliseFieldsCounted(meta, cfg.schema);
  tx.upsertRow(id: key, text: text, meta: meta, f: n.f, vector: vector);
  if (n.dropped > 0) {
    tx.set('d/$key', '${n.dropped}');
  } else if (tx.get('d/$key') != null) {
    tx.set('d/$key', null);
  }
}

/// Deletes [key]'s row and what describes it.
void deleteDoc(Tx tx, String key) {
  tx.deleteRow(key);
  if (tx.get('d/$key') != null) tx.set('d/$key', null);
}

KeyEntry loadKey(Tx tx, String key) {
  final j = tx.getJson('k/$key');
  return j == null ? KeyEntry() : KeyEntry.fromJson(j);
}

void saveKey(Tx tx, String key, KeyEntry e) {
  if (e.isEmpty) {
    tx.set('k/$key', null);
  } else {
    tx.setJson('k/$key', e.toJson());
  }
}

String cursorValue(String? generation, int seq) =>
    jsonEncode({'g': generation, 's': seq});

({String? generation, int seq})? parseCursor(String? raw) {
  if (raw == null) return null;
  final j = jsonDecode(raw) as Map;
  return (generation: j['g'] as String?, seq: j['s'] as int);
}

// ------------------------------------------------------------- the clock

/// Feeds every rev this device reads into the HLC and the ahead-of-clock
/// count.
final class Clock {
  Clock(Tx tx, this.nowMs)
    : maxSeen = tx.getInt('hlc'),
      _ahead = tx.getJson('ahead') ?? const {};

  final int nowMs;
  int maxSeen;
  final Map<String, Object?> _ahead;
  int _aheadCount = 0;
  int _aheadLead = 0;
  bool _changed = false;

  void see(int rev) {
    if (rev > maxSeen && !_mutated('hlcIgnoresReads')) {
      maxSeen = rev;
      _changed = true;
    }
    final lead = rev - nowMs;
    if (lead > aheadThresholdMs) {
      _aheadCount++;
      if (lead > _aheadLead) _aheadLead = lead;
    }
  }

  void save(Tx tx) {
    if (_changed) tx.set('hlc', '$maxSeen');
    if (_aheadCount > 0) {
      final prevLead = _ahead['lead'] as int? ?? 0;
      tx.setJson('ahead', {
        'n': (_ahead['n'] as int? ?? 0) + _aheadCount,
        'lead': _aheadLead > prevLead ? _aheadLead : prevLead,
      });
    }
  }
}

/// Allocates a rev: `max(now, maxSeen + 1)`, persisted before the space
/// write it is for (design §2.3).
int allocateRev(AnyIndexApi idx, int nowMs) {
  final tx = Tx(idx);
  final seen = tx.getInt('hlc');
  final rev = nowMs > seen ? nowMs : seen + 1;
  if (rev > maxRev || rev < 1) throw const ClockExhausted();
  tx.set('hlc', '$rev');
  tx.commit();
  return rev;
}

/// Throws [WriteRefused] when the location cannot take writes.
void checkWritable(Tx tx) {
  final fp = tx.getJson('firstPull');
  if (fp != null && fp['d'] != true) {
    throw const WriteRefused('firstPullPending');
  }
  final conflict = tx.get('conflict');
  if (conflict != null) throw WriteRefused('conflict', conflict);
}

// -------------------------------------------------------- follower pages

/// One object as object_read returned it.
final class ObjItem {
  ObjItem({
    required this.id,
    required this.typeId,
    required this.state,
    required this.props,
  });

  final String id;
  final String typeId;

  /// `ok`, `missing` or `deleted`.
  final String state;
  final Map<String, Object?> props;

  static ObjItem fromJson(Map<String, Object?> j) => ObjItem(
    id: j['id']! as String,
    typeId: j['typeId'] as String? ?? '',
    state: j['state'] as String? ?? 'ok',
    props: ((j['props'] as Map?) ?? const {}).cast<String, Object?>(),
  );
}

/// One entry of the change feed.
final class ChangeItem {
  ChangeItem(this.objectId, this.applySeq, this.deleted);
  final String objectId;
  final int applySeq;
  final bool deleted;
}

/// A page the SDK isolate read for the index isolate.
final class Page {
  Page({
    required this.generation,
    required this.maxApplySeq,
    required this.changes,
    required this.items,
    this.fromSeq = 0,
    this.toSeq = -1,
    this.cursorRaw,
    this.clearRaw,
    this.manifest,
    this.tombs,
    this.tombSeq,
    this.more = false,
    this.next,
  });

  final String? generation;
  final int maxApplySeq;

  /// The applySeq the page was read from; -1 for a type page (rebuild).
  final int fromSeq;

  /// The cursor after the page; -1 leaves the cursor alone.
  final int toSeq;

  /// The cursor and clear values the page was read under (the CAS).
  final String? cursorRaw;
  final String? clearRaw;
  final List<ChangeItem> changes;
  final Map<String, ObjItem> items;
  final ManifestRead? manifest;
  final List<Map<String, Object?>>? tombs;
  final int? tombSeq;
  final bool more;

  /// A type page's next id (rebuild).
  final String? next;
}

/// What applying a page did, or why it did nothing.
final class PageOutcome {
  bool needRebuild = false;
  bool casMiss = false;
  List<String> needObjects = const [];
  int applied = 0;
  int removed = 0;
  int pendingAdded = 0;
  int pendingCleared = 0;
  int unindexableAdded = 0;
  int duplicatesResolved = 0;
  bool conflict = false;
  int cursorSeq = 0;
  bool firstPullDone = false;

  /// Objects whose vector the index refused (INVALID_ARGUMENT), with the
  /// native message; their rows were applied without it.
  Map<String, String> rejected = const {};
}

/// Reads what a follower page must be read under: the cursor, the clear
/// rev and the tombstone seq.
({String? cursorRaw, String? clearRaw, int tombSeq, bool fresh})
readFollowState(AnyIndexApi idx) => (
  cursorRaw: idx.getState('cursor'),
  clearRaw: idx.getState('clear'),
  tombSeq: int.tryParse(idx.getState('tombSeq') ?? '') ?? 0,
  fresh: idx.getState('cursor') == null,
);

/// The reasons an object can be unindexable.
const unindexableReasons = [
  'malformed',
  'newerFormat',
  'badVector',
  'wrongDimension',
  'conflictingBinding',
  'revOutOfRange',
  'rejectedByIndex',
];

/// Applies [page] (design §3): tombstones and clear revs, then each change,
/// then each affected key's row. Rows for winners this page did not carry
/// are asked for in [PageOutcome.needObjects] and nothing is applied.
///
/// A page the index refuses (INVALID_ARGUMENT: a vector the shim checks
/// differently) does not stall the follower on one bad vector: each vector
/// row is probed alone, and the page is applied again with only the
/// refused objects' vectors left out. Those are marked `rejectedByIndex`
/// with the native message in their unindexable entry, and the follower
/// reports them (text-only rows not offered to backfill: the same vector
/// would be refused again) (D-R1). When no row is refused alone, the page
/// is refused as a whole and the error is thrown (D3-4).
PageOutcome applyPage(
  AnyIndexApi idx,
  LocConfig cfg,
  Page page, {
  required int nowMs,
  bool shadow = false,
  Map<String, String> rejected = const {},
}) {
  final out = PageOutcome();
  final tx = Tx(idx, shadow: shadow);

  if (!shadow) {
    final cursor = parseCursor(tx.get('cursor'));
    if (page.toSeq >= 0 &&
        cursor != null &&
        ((cursor.generation != null &&
                page.generation != null &&
                cursor.generation != page.generation) ||
            cursor.seq > page.maxApplySeq)) {
      out.needRebuild = true;
      return out;
    }
    tx.expect('cursor', page.cursorRaw);
    tx.expect('clear', page.clearRaw);
  }

  final clock = Clock(tx, nowMs);
  var clear = tx.getInt('clear');
  final clearBefore = clear;
  final affected = <String>{};
  final keys = <String, KeyEntry>{};
  KeyEntry entryOf(String key) => keys.putIfAbsent(key, () => loadKey(tx, key));

  // Tombstones and clear revs first, so this page's documents are judged
  // against them.
  var ignoredTombs = 0;
  for (final raw in page.tombs ?? const <Map<String, Object?>>[]) {
    final t = TombRecord.parse(raw);
    for (final r in t.revs) {
      clock.see(r);
    }
    ignoredTombs += t.badRevs;
    if (t.isClear) {
      if (t.maxRev > clear) clear = t.maxRev;
      continue;
    }
    if (!t.valid) {
      ignoredTombs++;
      continue;
    }
    final e = entryOf(t.key!);
    if (t.maxRev > e.tomb) {
      e.tomb = t.maxRev;
      affected.add(t.key!);
    }
  }
  if (ignoredTombs > 0) {
    tx.set('tombIgnored', '${tx.getInt('tombIgnored') + ignoredTombs}');
  }

  // The page's documents: the last change per object wins.
  final last = <String, ChangeItem>{};
  for (final c in page.changes) {
    last.remove(c.objectId);
    last[c.objectId] = c;
  }
  final pageDocs = <String, (DocValue, LeafValue)>{};

  void unindexable(String id, String reason, {String? key, int? rev}) {
    final had = tx.get('u/$id');
    if (had == null) out.unindexableAdded++;
    tx.setJson('u/$id', {'r': reason, 'k': ?key, 'v': ?rev, 'at': nowMs});
  }

  void forget(String id) {
    final key = tx.get('o/$id');
    if (key != null) {
      final e = entryOf(key);
      if (e.objs.remove(id) != null) affected.add(key);
      tx.set('o/$id', null);
    }
    if (tx.get('u/$id') != null) tx.set('u/$id', null);
    if (tx.get('p/$id') != null) {
      tx.set('p/$id', null);
      out.pendingCleared++;
    }
    if (tx.get('s/$id') != null) tx.set('s/$id', null);
    if (tx.get('b/$id') != null) tx.set('b/$id', null);
  }

  /// An object already mapped that now reads as not ours (malformed, no or
  /// another `loc`, another type) leaves the key map, so a winner fallback
  /// never waits for it (D-R3).
  void forgetIfMapped(String id) {
    if (_mutated('keepStaleMapping')) return;
    if (tx.get('o/$id') != null) forget(id);
  }

  for (final c in last.values) {
    if (c.objectId == cfg.manifestId) continue;
    final item = page.items[c.objectId];
    if (c.deleted || item?.state == 'deleted') {
      forget(c.objectId);
      continue;
    }
    if (item == null) continue;
    if (item.typeId.isNotEmpty && item.typeId != cfg.docRoot) {
      forgetIfMapped(c.objectId);
      continue;
    }
    final rawDoc = item.props['doc'];
    if (item.state == 'missing' || rawDoc == null) {
      // Our type, nothing readable yet (typed but not patched, or the
      // change has not fully arrived): absent, and pending.
      if (item.typeId == cfg.docRoot && tx.get('p/${c.objectId}') == null) {
        tx.setJson('p/${c.objectId}', {'at': nowMs});
        out.pendingAdded++;
      }
      continue;
    }
    final doc = DocValue.parse(rawDoc);
    if (doc.loc == null || doc.loc != cfg.indexName) {
      // Not readable as ours, or another location's document: absent.
      forgetIfMapped(c.objectId);
      continue;
    }
    if (tx.get('p/${c.objectId}') != null) {
      tx.set('p/${c.objectId}', null);
      out.pendingCleared++;
    }
    final id = c.objectId;
    switch (doc.kind) {
      case DocKind.malformed:
        forgetIfMapped(id);
        unindexable(id, 'malformed', key: doc.key, rev: doc.rev);
        continue;
      case DocKind.revOutOfRange:
        forgetIfMapped(id);
        unindexable(id, 'revOutOfRange', key: doc.key);
        continue;
      case DocKind.newerFormat || DocKind.ok:
        break;
    }
    final key = doc.key!;
    final rev = doc.rev!;
    clock.see(rev);
    final vecs = item.props['vecs'];
    var leaf = doc.kind == DocKind.ok
        ? LeafValue.parse(
            vecs is Map ? vecs[cfg.profileKey] : null,
            cfg.dimension,
          )
        : LeafValue(LeafKind.missing);
    // A vector of other content (an add raced a leaf write): text-only.
    if (leaf.kind == LeafKind.ok && leaf.ch != sha256Hex(doc.content ?? '')) {
      leaf = LeafValue(LeafKind.missing);
    }
    final refused = rejected[id];
    if (refused != null && leaf.kind == LeafKind.ok) {
      leaf = LeafValue(LeafKind.missing, ch: leaf.ch);
    }
    final String status;
    if (doc.kind == DocKind.newerFormat) {
      status = 'newer';
      unindexable(id, 'newerFormat', key: key, rev: rev);
    } else if (doc.mod != cfg.documents) {
      status = 'conflict';
      unindexable(id, 'conflictingBinding', key: key, rev: rev);
    } else {
      status = 'ok';
      if (leaf.kind == LeafKind.badVector) {
        unindexable(id, 'badVector', key: key, rev: rev);
      } else if (leaf.kind == LeafKind.wrongDimension) {
        unindexable(id, 'wrongDimension', key: key, rev: rev);
      } else if (refused != null) {
        final had = tx.get('u/$id');
        if (had == null) out.unindexableAdded++;
        tx.setJson('u/$id', {
          'r': 'rejectedByIndex',
          'k': key,
          'v': rev,
          'msg': refused,
          'at': nowMs,
        });
      } else if (tx.get('u/$id') != null) {
        tx.set('u/$id', null);
      }
    }
    // An object never moves to another key; a stale mapping is dropped.
    final oldKey = tx.get('o/$id');
    var own = false;
    if (oldKey != null && oldKey != key) {
      final o = entryOf(oldKey);
      own = o.objs.remove(id)?.own ?? false;
      affected.add(oldKey);
    }
    final e = entryOf(key);
    own = own || (e.objs[id]?.own ?? false);
    final content = doc.content;
    e.objs[id] = ObjEntry(
      rev: rev,
      own: own,
      status: status,
      ch: content == null ? null : sha256Hex(content),
      mh: status == 'ok' ? metaHash(doc.meta) : null,
      leaf: leaf.kind.name,
      leafCh: leaf.ch,
    );
    if (oldKey != key) tx.set('o/$id', key);
    affected.add(key);
    pageDocs[id] = (doc, leaf);
  }

  if (page.manifest != null) {
    tx.setJson('manifest', page.manifest!.toJson());
    final binding = tx.getJson('binding');
    final refusal = binding == null
        ? null
        : manifestConflict(page.manifest!, cfg, binding);
    tx.setJson('conflict', refusal);
    out.conflict = refusal != null;
  }

  if (clear > clearBefore) {
    tx.set('clear', '$clear');
    // Every key is judged again against the new clear rev.
    String? after;
    do {
      final s = idx.scanState(
        prefix: 'k/',
        after: after,
        limit: 500,
        shadow: shadow,
      );
      for (final (k, _) in s.entries) {
        affected.add(k.substring(2));
      }
      after = s.next;
    } while (after != null);
  }

  final needed = <String>[];
  final vectorRows = <(String, String, String, String?, Float32List)>[];
  for (final key in affected) {
    final e = entryOf(key);
    if (e.objs.length > 1) out.duplicatesResolved++;
    final w = e.visibleWinner(clear);
    final ok = w != null && e.objs[w]!.status == 'ok';
    if (!ok) {
      if (e.row != null) {
        deleteDoc(tx, key);
        out.removed++;
        e.row = null;
      }
      if (tx.get('m/$key') != null) tx.set('m/$key', null);
    } else if (e.row == w && !pageDocs.containsKey(w)) {
      // Unchanged winner.
    } else if (pageDocs.containsKey(w)) {
      final (doc, leaf) = pageDocs[w]!;
      final vector = leaf.kind == LeafKind.ok ? leaf.vector : null;
      upsertDoc(
        tx,
        cfg,
        key: key,
        text: doc.content!,
        meta: doc.meta,
        vector: vector,
      );
      if (vector != null) {
        vectorRows.add((w, key, doc.content!, doc.meta, vector));
      }
      out.applied++;
      e.row = w;
      if (vector == null && !rejected.containsKey(w)) {
        tx.setJson('m/$key', {'id': w, 'c': e.objs[w]!.ch});
      } else if (tx.get('m/$key') != null) {
        tx.set('m/$key', null);
      }
    } else {
      needed.add(w);
    }
    saveKey(tx, key, e);
  }
  if (needed.isNotEmpty) {
    out.needObjects = needed;
    return out;
  }

  clock.save(tx);
  if (page.tombSeq != null) tx.set('tombSeq', '${page.tombSeq}');
  if (page.toSeq >= 0) {
    tx.set('cursor', cursorValue(page.generation, page.toSeq));
    out.cursorSeq = page.toSeq;
    final fp = tx.getJson('firstPull');
    if (fp != null && fp['d'] != true && page.toSeq >= (fp['t'] as int)) {
      tx.setJson('firstPull', {'t': fp['t'], 'd': true});
      out.firstPullDone = true;
    }
  }
  tx.set('lastPull', '$nowMs');
  try {
    tx.commit();
  } on AnyShimException catch (e) {
    if (e.status == AnyShimStatus.conflict && !shadow) {
      return PageOutcome()..casMiss = true;
    }
    if (e.status == AnyShimStatus.invalidArgument &&
        rejected.isEmpty &&
        vectorRows.isNotEmpty) {
      final refused = _probeVectors(idx, cfg, vectorRows, shadow);
      // No single row is refused on its own: the page is refused for
      // something else. Stall on it, with the native message as the
      // follower's error, rather than strip every vector (D3-4).
      if (refused.isEmpty) rethrow;
      final again = applyPage(
        idx,
        cfg,
        page,
        nowMs: nowMs,
        shadow: shadow,
        rejected: refused,
      );
      again.rejected = refused;
      return again;
    }
    rethrow;
  }
  return out;
}

/// Which of [rows] the index refuses alone, with its message. Each probe is
/// an apply that cannot commit: index_apply validates every op before its
/// compare-and-set, and the probe's CAS expects a value no key holds, so a
/// refused row answers INVALID_ARGUMENT and an accepted one CONFLICT.
Map<String, String> _probeVectors(
  AnyIndexApi idx,
  LocConfig cfg,
  List<(String, String, String, String?, Float32List)> rows,
  bool shadow,
) {
  final out = <String, String>{};
  for (final (id, key, text, meta, vector) in rows) {
    // `f` is left empty: the probe never commits (its CAS cannot hold), and
    // f values are typed before any write, so only the vector is judged.
    final probe = Tx(idx, shadow: shadow)..expect('\u0000probe', '\u0000never');
    probe.upsertRow(
      id: key,
      text: text,
      meta: meta,
      f: const {},
      vector: vector,
    );
    try {
      probe.commit();
    } on AnyShimException catch (e) {
      if (e.status == AnyShimStatus.invalidArgument) out[id] = e.message;
      if (e.status != AnyShimStatus.invalidArgument &&
          e.status != AnyShimStatus.conflict) {
        rethrow;
      }
    }
  }
  return out;
}

/// The manifest's refusal of [binding] (design §2.1, conflict check), as
/// JSON, or null when they agree.
Map<String, Object?>? manifestConflict(
  ManifestRead m,
  LocConfig cfg,
  Map<String, Object?> binding,
) {
  if (!m.present) return null;
  final reasons = <String>[];
  if (m.coreNewerFormat) reasons.add('newerFormat');
  if (m.coreLeaves.length > 1 || m.documents != binding['documents']) {
    reasons.add('documents');
  }
  final types = <String, Set<String>>{};
  for (final f in m.fields) {
    types.putIfAbsent(f.name, () => {}).add(f.type);
  }
  for (final f in cfg.schema.fields) {
    final t = types[f.name];
    if (t != null && (t.length > 1 || !t.contains(f.type.name))) {
      reasons.add('field:${f.name}');
    }
  }
  for (final p in m.profiles) {
    if (p.id == binding['profileId'] &&
        p.documents == binding['documents'] &&
        p.dimension != binding['dimension']) {
      reasons.add('profile:${p.id}');
    }
  }
  return reasons.isEmpty ? null : {'reasons': reasons, ...m.toJson()};
}

// --------------------------------------------------------------- writes

/// What an add has to do (design §2.2 step 1).
enum AddPlan { full, leafOnly, noop }

/// Decides S1 for an add of [key] with [ch] and [mh]: a no-op when the
/// visible winner has equal content and meta and already this profile's
/// leaf for that content; only the leaf when it lacks it.
({AddPlan plan, String? objectId}) planAdd(
  AnyIndexApi idx,
  String key,
  String ch,
  String mh,
) {
  final tx = Tx(idx);
  checkWritable(tx);
  final e = loadKey(tx, key);
  final w = e.visibleWinner(tx.getInt('clear'));
  if (w == null || _mutated('noS1')) {
    return (plan: AddPlan.full, objectId: null);
  }
  final o = e.objs[w]!;
  if (o.status != 'ok' || o.ch != ch || o.mh != mh) {
    return (plan: AddPlan.full, objectId: null);
  }
  if ((o.leaf == 'ok' && o.leafCh == ch) || o.leaf == 'newerFormat') {
    return (plan: AddPlan.noop, objectId: w);
  }
  return (plan: AddPlan.leafOnly, objectId: w);
}

/// Allocates a rev for a write, after the write checks.
int allocateWriteRev(AnyIndexApi idx, int nowMs) {
  checkWritable(Tx(idx));
  return allocateRev(idx, nowMs);
}

/// Applies this device's new object of [key] (design §2.2 steps 4 and 6):
/// the row, the key map, and the supersede deletes of this device's older
/// objects of the key, which wait until the new object is synced.
void applyOwnAdd(
  AnyIndexApi idx,
  LocConfig cfg, {
  required String key,
  required String objectId,
  required int rev,
  required String content,
  required String? meta,
  required Float32List vector,
  required int nowMs,
}) {
  final tx = Tx(idx);
  final e = loadKey(tx, key);
  final ch = sha256Hex(content);
  for (final MapEntry(key: id, value: o) in e.objs.entries) {
    if (o.own && o.rev < rev) {
      tx.setJson('s/$id', {'new': objectId, 'k': key, 'at': nowMs});
    }
  }
  e.objs[objectId] = ObjEntry(
    rev: rev,
    own: true,
    status: 'ok',
    ch: ch,
    mh: metaHash(meta),
    leaf: 'ok',
    leafCh: ch,
  );
  tx.set('o/$objectId', key);
  final w = e.visibleWinner(tx.getInt('clear'));
  if (w == objectId) {
    upsertDoc(tx, cfg, key: key, text: content, meta: meta, vector: vector);
    e.row = objectId;
    if (tx.get('m/$key') != null) tx.set('m/$key', null);
  }
  saveKey(tx, key, e);
  final seen = tx.getInt('hlc');
  if (rev > seen) tx.set('hlc', '$rev');
  tx.commit();
}

/// Records that [objectId]'s body could not be written.
void markBlankBody(AnyIndexApi idx, String objectId, String key) {
  final tx = Tx(idx)..setJson('b/$objectId', {'k': key});
  tx.commit();
}

/// Applies a vector leaf written on [objectId] of [key], when the object is
/// still the visible winner with content [ch]. Returns false (and changes
/// nothing) otherwise.
bool applyLeaf(
  AnyIndexApi idx,
  LocConfig cfg, {
  required String key,
  required String objectId,
  required String ch,
  required Float32List vector,
}) {
  final tx = Tx(idx);
  final e = loadKey(tx, key);
  final o = e.objs[objectId];
  if (o == null ||
      e.visibleWinner(tx.getInt('clear')) != objectId ||
      o.ch != ch ||
      o.status != 'ok') {
    return false;
  }
  final row = tx.idx.getRow(key);
  if (row == null) return false;
  o.leaf = 'ok';
  o.leafCh = ch;
  final meta = row['meta'] as String?;
  upsertDoc(
    tx,
    cfg,
    key: key,
    text: row['text']! as String,
    meta: meta,
    vector: vector,
  );
  e.row = objectId;
  if (tx.get('m/$key') != null) tx.set('m/$key', null);
  if (tx.get('u/$objectId') != null) tx.set('u/$objectId', null);
  saveKey(tx, key, e);
  tx.commit();
  return true;
}

/// Where a vector write for one missing item stands.
enum LeafCheck { write, changed, gone, newerFormat }

LeafCheck checkLeafTarget(
  AnyIndexApi idx, {
  required String key,
  required String objectId,
  required String ch,
}) {
  final tx = Tx(idx);
  final e = loadKey(tx, key);
  final o = e.objs[objectId];
  if (o == null) return LeafCheck.gone;
  if (o.leaf == LeafKind.newerFormat.name) return LeafCheck.newerFormat;
  if (e.visibleWinner(tx.getInt('clear')) != objectId ||
      o.ch != ch ||
      o.status != 'ok') {
    return LeafCheck.changed;
  }
  return LeafCheck.write;
}

/// Applies a remove of [key] at [rev] (design §2.3): the tombstone rev, the
/// row. Returns this device's objects of the key below [rev], to delete.
List<String> applyRemove(AnyIndexApi idx, String key, int rev) {
  final tx = Tx(idx);
  final e = loadKey(tx, key);
  if (rev > e.tomb) e.tomb = rev;
  if (e.row != null) {
    deleteDoc(tx, key);
    e.row = null;
  }
  if (tx.get('m/$key') != null) tx.set('m/$key', null);
  final doomed = [
    for (final MapEntry(key: id, value: o) in e.objs.entries)
      if (o.own && o.rev < rev) id,
  ];
  for (final id in doomed) {
    if (tx.get('s/$id') != null) tx.set('s/$id', null);
  }
  saveKey(tx, key, e);
  if (rev > tx.getInt('hlc')) tx.set('hlc', '$rev');
  tx.commit();
  return doomed;
}

/// Applies a clear at [rev] (design §2.3): every row goes in one
/// transaction, with the pending, unindexable and text-only entries below
/// the rev. Returns the mapped objects below [rev], to delete.
List<String> applyClear(AnyIndexApi idx, int rev, {required int nowMs}) {
  final tx = Tx(idx);
  if (rev > tx.getInt('clear')) tx.set('clear', '$rev');
  tx.clearDocs();
  final doomed = <String>[];
  String? after;
  do {
    final s = idx.scanState(prefix: 'k/', after: after, limit: 500);
    for (final (k, v) in s.entries) {
      final e = KeyEntry.fromJson((jsonDecode(v) as Map).cast());
      e.row = null;
      for (final MapEntry(key: id, value: o) in e.objs.entries) {
        if (o.rev < rev) doomed.add(id);
      }
      saveKey(tx, k.substring(2), e);
    }
    after = s.next;
  } while (after != null);
  for (final prefix in ['m/', 'p/', 'u/', 's/', 'd/']) {
    String? a;
    do {
      final s = idx.scanState(prefix: prefix, after: a, limit: 500);
      for (final (k, v) in s.entries) {
        if (prefix == 'u/') {
          final r = (jsonDecode(v) as Map)['v'];
          if (r is int && r >= rev) continue;
        }
        tx.set(k, null);
      }
      a = s.next;
    } while (a != null);
  }
  if (rev > tx.getInt('hlc')) tx.set('hlc', '$rev');
  tx.commit();
  return doomed;
}

// -------------------------------------------------------------- reading

/// One page of `m/` entries with their rows' content; `next` is the last
/// key returned when more follow.
({List<Map<String, Object?>> items, String? next}) readMissing(
  AnyIndexApi idx, {
  String? after,
  required int limit,
}) {
  final s = idx.scanState(
    prefix: 'm/',
    after: after == null ? null : 'm/$after',
    limit: limit,
  );
  final items = <Map<String, Object?>>[];
  for (final (k, v) in s.entries) {
    final key = k.substring(2);
    final m = jsonDecode(v) as Map;
    final row = idx.getRow(key);
    if (row == null) continue;
    items.add({
      'key': key,
      'objectId': m['id'],
      'ch': m['c'],
      'content': row['text'],
      'meta': row['meta'],
    });
  }
  final next = s.next == null || s.entries.isEmpty
      ? null
      : s.entries.last.$1.substring(2);
  return (items: items, next: next);
}

/// Counts every `prefix` entry, and hands each to [visit].
int scanAll(
  AnyIndexApi idx,
  String prefix,
  void Function(String key, String value)? visit,
) {
  var n = 0;
  String? after;
  do {
    final s = idx.scanState(prefix: prefix, after: after, limit: 500);
    for (final (k, v) in s.entries) {
      n++;
      visit?.call(k, v);
    }
    after = s.next;
  } while (after != null);
  return n;
}

/// The sum of the integer values under [prefix].
int _sumValues(AnyIndexApi idx, String prefix) {
  var n = 0;
  scanAll(idx, prefix, (k, v) => n += int.tryParse(v) ?? 0);
  return n;
}

/// The totals of locationStatus, as plain data.
Map<String, Object?> readStatus(AnyIndexApi idx, {required int nowMs}) {
  final clear = int.tryParse(idx.getState('clear') ?? '') ?? 0;
  var tombstones = 0;
  var dominated = 0;
  scanAll(idx, 'k/', (k, v) {
    final e = KeyEntry.fromJson((jsonDecode(v) as Map).cast());
    if (e.tomb > 0) tombstones++;
    dominated += e.dominated(clear).length;
  });
  int? oldestPending;
  final pending = scanAll(idx, 'p/', (k, v) {
    final at = (jsonDecode(v) as Map)['at'] as int? ?? nowMs;
    if (oldestPending == null || at < oldestPending!) oldestPending = at;
  });
  final reasons = <String, int>{};
  scanAll(idx, 'u/', (k, v) {
    final r = (jsonDecode(v) as Map)['r'] as String? ?? 'unknown';
    reasons[r] = (reasons[r] ?? 0) + 1;
  });
  final cursor = parseCursor(idx.getState('cursor'));
  final ahead = idx.getState('ahead');
  final manifest = idx.getState('manifest');
  final conflict = idx.getState('conflict');
  var conflictingDocs = reasons['conflictingBinding'] ?? 0;
  return {
    'documents': idx.count(),
    'vectors': idx.countVectors(),
    'textOnly': scanAll(idx, 'm/', null),
    'pending': pending,
    'oldestPendingAt': oldestPending,
    'unindexable': reasons,
    'tombstones': tombstones,
    'clear': clear,
    'lastPull': int.tryParse(idx.getState('lastPull') ?? ''),
    'cursor': cursor?.seq ?? 0,
    'ahead': ahead == null ? null : jsonDecode(ahead),
    'blankBodies': scanAll(idx, 'b/', null),
    'dominated': dominated,
    'supersede': scanAll(idx, 's/', null),
    'rebuilding': int.tryParse(idx.getState('rebuilding') ?? ''),
    'manifest': manifest == null ? null : jsonDecode(manifest),
    'conflict': conflict == null ? null : jsonDecode(conflict),
    'conflictingDocuments': conflictingDocs,
    'tombIgnored': int.tryParse(idx.getState('tombIgnored') ?? '') ?? 0,
    'droppedFields': _sumValues(idx, 'd/'),
    'firstPull': idx.getState('firstPull'),
  };
}

/// What compact() should do (design §2.4).
({
  List<String> dominated,
  List<(String oldId, String newId)> supersede,
  List<(String id, String key)> blank,
})
planCompaction(AnyIndexApi idx) {
  final clear = int.tryParse(idx.getState('clear') ?? '') ?? 0;
  final supersede = <(String, String)>[];
  scanAll(idx, 's/', (k, v) {
    supersede.add((k.substring(2), (jsonDecode(v) as Map)['new'] as String));
  });
  // A superseded object whose successor has not synced waits (C3): the
  // supersede sweep deletes it once the successor is acknowledged.
  final waiting = {for (final (old, _) in supersede) old};
  final dominated = <String>[];
  final shown = <String>{};
  scanAll(idx, 'k/', (k, v) {
    final e = KeyEntry.fromJson((jsonDecode(v) as Map).cast());
    dominated.addAll(e.dominated(clear).where((id) => !waiting.contains(id)));
    if (e.row != null) shown.add(e.row!);
  });
  // Only the object a row shows gets its body repaired (with the row's
  // content); a superseded one never will.
  final blank = <(String, String)>[];
  scanAll(idx, 'b/', (k, v) {
    final id = k.substring(2);
    if (shown.contains(id)) {
      blank.add((id, (jsonDecode(v) as Map)['k'] as String));
    }
  });
  return (dominated: dominated, supersede: supersede, blank: blank);
}

/// Drops state entries by key.
void dropState(AnyIndexApi idx, List<String> keys) {
  if (keys.isEmpty) return;
  final tx = Tx(idx);
  for (final k in keys) {
    tx.set(k, null);
  }
  tx.commit();
}

// -------------------------------------------------------------- rebuild

/// The live state a rebuild keeps: config keys copied as they are.
const carriedKeys = [
  'binding',
  'cfg',
  'firstPull',
  'manifest',
  'conflict',
  'ahead',
  'tombIgnored',
];

/// Starts a shadow generation (design §3 Rebuild step 2) and copies the
/// configuration keys into it.
void beginShadow(AnyIndexApi idx) {
  idx.apply({
    'ops': [
      {'op': 'shadowBegin'},
    ],
  }, Float32List(0));
  final tx = Tx(idx, shadow: true);
  for (final k in carriedKeys) {
    final v = idx.getState(k);
    if (v != null) tx.set(k, v);
  }
  tx.commit();
}

/// Copies the own flags of the live key map onto the shadow's, so the
/// objects this device wrote stay its own after the swap.
void carryOwn(AnyIndexApi idx) {
  final tx = Tx(idx, shadow: true);
  String? after;
  do {
    final s = idx.scanState(prefix: 'k/', after: after, limit: 500);
    for (final (k, v) in s.entries) {
      final live = KeyEntry.fromJson((jsonDecode(v) as Map).cast());
      final ownIds = [
        for (final e in live.objs.entries)
          if (e.value.own) e.key,
      ];
      if (ownIds.isEmpty) continue;
      final shadowRaw = tx.get(k);
      if (shadowRaw == null) continue;
      final sh = KeyEntry.fromJson((jsonDecode(shadowRaw) as Map).cast());
      var changed = false;
      for (final id in ownIds) {
        final o = sh.objs[id];
        if (o != null && !o.own) {
          o.own = true;
          changed = true;
        }
      }
      if (changed) tx.setJson(k, sh.toJson());
    }
    after = s.next;
  } while (after != null);
  tx.commit();
}

/// Swaps the shadow in (design §3 Rebuild step 4): the cursor, the HLC as
/// the larger of both, the waiting supersede deletes and blank bodies whose
/// objects survived; then the shadow becomes active and the rebuild mark
/// goes.
void swapShadow(
  AnyIndexApi idx, {
  required String? generation,
  required int seq,
}) {
  final tx = Tx(idx, shadow: true);
  final liveHlc = int.tryParse(idx.getState('hlc') ?? '') ?? 0;
  final shadowHlc = tx.getInt('hlc');
  tx.set('hlc', '${liveHlc > shadowHlc ? liveHlc : shadowHlc}');
  tx.set('cursor', cursorValue(generation, seq));
  final fp = tx.getJson('firstPull');
  if (fp != null && fp['d'] != true && seq >= (fp['t'] as int)) {
    tx.setJson('firstPull', {'t': fp['t'], 'd': true});
  }
  for (final prefix in ['s/', 'b/']) {
    scanAll(idx, prefix, (k, v) {
      final id = k.substring(2);
      if (tx.get('o/$id') != null) tx.set(k, v);
    });
  }
  tx.set('rebuilding', null);
  tx.raw({'op': 'shadowSwap'});
  tx.commit();
}

/// Marks (or clears) the live state as rebuilding.
void markRebuilding(AnyIndexApi idx, int? since) =>
    (Tx(idx)..set('rebuilding', since == null ? null : '$since')).commit();
