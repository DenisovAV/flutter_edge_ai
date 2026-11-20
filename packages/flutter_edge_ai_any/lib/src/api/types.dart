part of 'any_sync.dart';

/// Peer-to-peer settings of an account. Global p2p (relays) is always off.
@experimental
final class AnySyncP2p {
  /// LAN p2p: mDNS discovery and QUIC between devices on one network.
  /// [serviceName] overrides the mDNS service type (tests use a random one,
  /// so nothing else on the network pairs with them).
  const AnySyncP2p.lan({this.serviceName}) : enabled = true;

  /// No p2p at all: the account syncs only through its nodes.
  const AnySyncP2p.disabled() : enabled = false, serviceName = null;

  final bool enabled;
  final String? serviceName;

  Map<String, Object?> _toJson() => {
    'enabled': enabled,
    'localDiscovery': enabled,
    'serviceName': ?serviceName,
  };
}

/// A space this account created or knows.
@experimental
final class AnySyncSpace {
  AnySyncSpace._(this.id, this.name);
  final String id;
  final String name;

  @override
  String toString() => 'AnySyncSpace($id, $name)';
}

/// The spaces this account knows, and how asking peers went.
@experimental
final class AnySyncSpaceList {
  AnySyncSpaceList._(this.spaces, this.syncError, this.timedOut);
  final List<AnySyncSpace> spaces;

  /// The failed peer request's message (the local list is still returned).
  final String? syncError;
  final bool timedOut;
}

/// The sync state of a space, as the SDK reports it.
@experimental
enum AnySyncSpaceState { synced, syncing, offline, error, loading, unknown }

/// One space's sync status.
@experimental
final class AnySyncStatus {
  AnySyncStatus._({
    required this.spaceId,
    required this.state,
    required this.rawState,
    required this.p2p,
    required this.localPeers,
    required this.networkPeers,
    required this.globalPeers,
    required this.lastSyncedAt,
    required this.everPeerSynced,
    required this.createdHere,
    this.stateSaveError,
  }) : followerError = null,
       followerErrorAt = null,
       location = null;

  /// A location's follower failed (or recovered: [followerError] null).
  AnySyncStatus._follower(
    AnySyncLocation this.location,
    this.followerError,
    this.followerErrorAt,
  ) : spaceId = location.spaceId,
      state = AnySyncSpaceState.unknown,
      rawState = 'follower',
      p2p = null,
      localPeers = 0,
      networkPeers = 0,
      globalPeers = 0,
      lastSyncedAt = null,
      everPeerSynced = false,
      createdHere = false,
      stateSaveError = null;

  final String spaceId;
  final AnySyncSpaceState state;

  /// The SDK's word for [state], also when [state] is `unknown`.
  final String rawState;
  final String? p2p;
  final int localPeers;
  final int networkPeers;
  final int globalPeers;

  /// The last completed peer sync in this process; null after open until
  /// one completes (the SDK keeps it in memory).
  final DateTime? lastSyncedAt;

  /// Whether a peer sync of this space ever completed on this device.
  final bool everPeerSynced;
  final bool createdHere;

  /// The account state (everPeerSynced, the creator mark) failed to save.
  final String? stateSaveError;

  /// Set on a status a location's follower reports: its last background
  /// failure, null once a pull succeeded again. The space fields are then
  /// not meaningful ([rawState] is `follower`).
  final String? followerError;
  final DateTime? followerErrorAt;

  /// The location a follower status is about.
  final AnySyncLocation? location;

  static AnySyncStatus _fromJson(Map<String, Object?> j) {
    final loading = j['loading'] == true;
    final raw = (j['state'] as String?) ?? 'unknown';
    final last = j['lastSyncedAt'];
    return AnySyncStatus._(
      spaceId: (j['spaceId'] as String?) ?? '',
      state: loading
          ? AnySyncSpaceState.loading
          : AnySyncSpaceState.values.firstWhere(
              (s) => s.name == raw,
              orElse: () => AnySyncSpaceState.unknown,
            ),
      rawState: loading ? 'loading' : raw,
      p2p: j['p2p']?.toString(),
      localPeers: _int(j['localPeers']),
      networkPeers: _int(j['networkPeers']),
      globalPeers: _int(j['globalPeers']),
      lastSyncedAt: last is String ? DateTime.tryParse(last) : null,
      everPeerSynced: j['everPeerSynced'] == true,
      createdHere: j['createdHere'] == true,
      stateSaveError: j['stateSaveError'] as String?,
    );
  }

  @override
  String toString() =>
      'AnySyncStatus($spaceId, ${state.name}, peers: $localPeers/'
      '$networkPeers, lastSyncedAt: $lastSyncedAt)';
}

int _int(Object? v) => v is int ? v : 0;

/// What one pull applied: deltas, never totals.
@experimental
final class AnySyncPull {
  AnySyncPull._({
    this.applied = 0,
    this.removed = 0,
    this.pendingAdded = 0,
    this.pendingCleared = 0,
    this.unindexableAdded = 0,
    this.duplicatesResolved = 0,
    this.rebuilt = false,
  });

  final int applied;
  final int removed;
  final int pendingAdded;
  final int pendingCleared;
  final int unindexableAdded;
  final int duplicatesResolved;

  /// Whether the pull rebuilt the local index.
  final bool rebuilt;

  AnySyncPull _plus(PageOutcome o) => AnySyncPull._(
    applied: applied + o.applied,
    removed: removed + o.removed,
    pendingAdded: pendingAdded + o.pendingAdded,
    pendingCleared: pendingCleared + o.pendingCleared,
    unindexableAdded: unindexableAdded + o.unindexableAdded,
    duplicatesResolved: duplicatesResolved + o.duplicatesResolved,
    rebuilt: rebuilt,
  );

  AnySyncPull _rebuilt() => AnySyncPull._(
    applied: applied,
    removed: removed,
    pendingAdded: pendingAdded,
    pendingCleared: pendingCleared,
    unindexableAdded: unindexableAdded,
    duplicatesResolved: duplicatesResolved,
    rebuilt: true,
  );

  @override
  String toString() =>
      'AnySyncPull(applied: $applied, removed: $removed, pending: '
      '+$pendingAdded/-$pendingCleared, unindexable: +$unindexableAdded, '
      'duplicates: $duplicatesResolved, rebuilt: $rebuilt)';
}

/// What `syncNow` did. An empty [pull] after a timeout is never "up to date".
@experimental
final class AnySyncSyncResult {
  AnySyncSyncResult._(this.reachedPeer, this.timedOut, this.error, this.pull);
  final bool reachedPeer;
  final bool timedOut;
  final String? error;
  final AnySyncPull pull;
}

/// One document whose row has no vector for this device's profile.
@experimental
final class AnySyncMissingVector {
  AnySyncMissingVector._({
    required this.key,
    required this.content,
    required this.meta,
    required this.contentHash,
    required this.modality,
    required this._objectId,
  });

  /// The document id (the `id` of `RagIndex.add`).
  final String key;
  final String content;
  final String? meta;

  /// `sha256(content)`, hex.
  final String contentHash;
  final EmbeddingModality modality;
  final String _objectId;
}

/// A page of [AnySyncMissingVector]s; pass [next] as `after`.
@experimental
final class AnySyncMissingVectors {
  AnySyncMissingVectors._(this.items, this.next);
  final List<AnySyncMissingVector> items;
  final String? next;
}

/// A vector for one missing item.
@experimental
final class AnySyncVectorItem {
  AnySyncVectorItem(this.item, this.vector);
  final AnySyncMissingVector item;
  final Float32List vector;
}

/// Why one vector was not written.
@experimental
final class AnySyncVectorFailure {
  AnySyncVectorFailure._(this.key, this.reason);
  final String key;
  final String reason;

  @override
  String toString() => 'AnySyncVectorFailure($key: $reason)';
}

/// What `writeMissingVectors` did.
@experimental
final class AnySyncVectorWrite {
  AnySyncVectorWrite._({
    required this.written,
    required this.skippedChanged,
    required this.skippedGone,
    required this.skippedNewerFormat,
    required this.failed,
  });

  final int written;

  /// The document moved on (another object won, or its content changed).
  final int skippedChanged;

  /// The object was deleted.
  final int skippedGone;

  /// The object carries this profile's leaf in a newer format.
  final int skippedNewerFormat;
  final List<AnySyncVectorFailure> failed;
}

/// What `backfillVectors` did; pass [next] as `after` for the next page.
@experimental
final class AnySyncBackfill {
  AnySyncBackfill._({
    required this.written,
    required this.skippedChanged,
    required this.skippedGone,
    required this.skippedNewerFormat,
    required this.failed,
    required this.next,
  });

  final int written;
  final int skippedChanged;
  final int skippedGone;
  final int skippedNewerFormat;
  final List<AnySyncVectorFailure> failed;
  final String? next;
}

/// Why a document is not indexed.
@experimental
enum AnySyncUnindexableReason {
  malformed,
  newerFormat,
  badVector,
  wrongDimension,
  conflictingBinding,
  revOutOfRange,
  unknown,
}

/// One profile a location's manifest names.
@experimental
final class AnySyncManifestProfile {
  AnySyncManifestProfile._(this.id, this.dimension, this.documents);
  final String id;
  final int dimension;
  final EmbeddingModality? documents;
}

/// A location's manifest (design §2.1).
@experimental
final class AnySyncManifest {
  AnySyncManifest._({
    required this.documents,
    required this.profiles,
    required this.fields,
    required this.textSearch,
    required this.ignoredLeaves,
  });

  /// Null when the manifest names a modality this version does not know.
  final EmbeddingModality? documents;
  final List<AnySyncManifestProfile> profiles;

  /// The schema union; a name may appear with two types (a conflict).
  final List<({String name, String type})> fields;
  final bool textSearch;

  /// Leaves whose value did not hash to their key: ignored.
  final int ignoredLeaves;

  static AnySyncManifest? _fromJson(Object? json) {
    if (json is! Map || json['present'] != true) return null;
    final m = ManifestRead.fromJson(json.cast());
    return AnySyncManifest._(
      documents: _modality(m.documents),
      profiles: [
        for (final p in m.profiles)
          AnySyncManifestProfile._(p.id, p.dimension, _modality(p.documents)),
      ],
      fields: [for (final f in m.fields) (name: f.name, type: f.type)],
      textSearch: m.textSearch,
      ignoredLeaves: m.ignoredLeaves,
    );
  }
}

EmbeddingModality? _modality(String? name) => switch (name) {
  'text' => EmbeddingModality.text,
  'image' => EmbeddingModality.image,
  'audio' => EmbeddingModality.audio,
  _ => null,
};

/// The manifest refuses this device's binding.
@experimental
final class AnySyncConflict {
  AnySyncConflict._(this.manifest, this.reasons, this.conflictingDocuments);
  final AnySyncManifest? manifest;

  /// What disagrees: `documents`, `field:<name>`, `profile:<id>`,
  /// `newerFormat`.
  final List<String> reasons;

  /// Documents written under a binding the manifest does not have.
  final int conflictingDocuments;
}

/// Totals of one location on this device.
@experimental
final class AnySyncLocationStatus {
  AnySyncLocationStatus._({
    required this.documents,
    required this.vectors,
    required this.textOnly,
    required this.pending,
    required this.oldestPendingAge,
    required this.unindexable,
    required this.rawUnindexable,
    required this.tombstones,
    required this.lastPull,
    required this.cursor,
    required this.revsAheadOfClock,
    required this.largestClockLead,
    required this.blankBodies,
    required this.dominatedObjects,
    required this.pendingSupersedeDeletes,
    required this.rebuilding,
    required this.rebuildingSince,
    required this.manifest,
    required this.conflict,
    required this.firstPullPending,
    required this.ignoredTombstones,
    required this.droppedFilterValues,
    required this.lastFollowerError,
    required this.lastFollowerErrorAt,
  });

  /// Rows in the local index.
  final int documents;

  /// Rows with a vector of this device's profile.
  final int vectors;

  /// Rows without one (listed by `missingVectors`).
  final int textOnly;
  final int pending;
  final Duration? oldestPendingAge;
  final Map<AnySyncUnindexableReason, int> unindexable;

  /// [unindexable] by the stored word, also for reasons this version does
  /// not know.
  final Map<String, int> rawUnindexable;

  /// Keys with a tombstone.
  final int tombstones;
  final DateTime? lastPull;
  final int cursor;

  /// Revs read more than 5 min ahead of this device's clock.
  final int revsAheadOfClock;
  final Duration largestClockLead;

  /// Objects whose editor body could not be written (`compact` repairs).
  final int blankBodies;

  /// Superseded objects not deleted yet (≈32 KB each).
  final int dominatedObjects;

  /// This device's superseded objects, waiting for their successor to sync.
  final int pendingSupersedeDeletes;
  final bool rebuilding;
  final DateTime? rebuildingSince;
  final AnySyncManifest? manifest;
  final AnySyncConflict? conflict;

  /// Writes wait for the first full pull of this file.
  final bool firstPullPending;

  /// Tombstone records whose id is not sha256(key), and revs out of range:
  /// ignored.
  final int ignoredTombstones;

  /// Rows whose metadata carried a declared filter field with a value of
  /// another type (or was not a JSON object): those values match no
  /// filter.
  final int droppedFilterValues;

  /// The follower's last background failure, until a pull succeeds.
  final String? lastFollowerError;
  final DateTime? lastFollowerErrorAt;

  static AnySyncLocationStatus _fromJson(
    Map<String, Object?> j,
    int nowMs, {
    String? followerError,
    DateTime? followerErrorAt,
  }) {
    final raw = ((j['unindexable'] as Map?) ?? const {}).cast<String, int>();
    final typed = <AnySyncUnindexableReason, int>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final r = AnySyncUnindexableReason.values.firstWhere(
        (x) => x.name == key,
        orElse: () => AnySyncUnindexableReason.unknown,
      );
      typed[r] = (typed[r] ?? 0) + value;
    }
    final ahead = (j['ahead'] as Map?) ?? const {};
    final oldest = j['oldestPendingAt'] as int?;
    final last = j['lastPull'] as int?;
    final since = j['rebuilding'] as int?;
    final conflict = j['conflict'];
    final fp = j['firstPull'] as String?;
    return AnySyncLocationStatus._(
      documents: j['documents']! as int,
      vectors: j['vectors']! as int,
      textOnly: j['textOnly']! as int,
      pending: j['pending']! as int,
      oldestPendingAge: oldest == null
          ? null
          : Duration(milliseconds: nowMs - oldest),
      unindexable: Map.unmodifiable(typed),
      rawUnindexable: Map.unmodifiable(raw),
      tombstones: j['tombstones']! as int,
      lastPull: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      cursor: j['cursor']! as int,
      revsAheadOfClock: ahead['n'] as int? ?? 0,
      largestClockLead: Duration(milliseconds: ahead['lead'] as int? ?? 0),
      blankBodies: j['blankBodies']! as int,
      dominatedObjects: j['dominated']! as int,
      pendingSupersedeDeletes: j['supersede']! as int,
      rebuilding: since != null,
      rebuildingSince: since == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(since),
      manifest: AnySyncManifest._fromJson(j['manifest']),
      conflict: conflict is Map
          ? AnySyncConflict._(AnySyncManifest._fromJson(conflict), [
              for (final r in (conflict['reasons'] as List)) r as String,
            ], j['conflictingDocuments'] as int? ?? 0)
          : null,
      firstPullPending: fp != null && (jsonDecode(fp) as Map)['d'] != true,
      ignoredTombstones: j['tombIgnored'] as int? ?? 0,
      droppedFilterValues: j['droppedFields'] as int? ?? 0,
      lastFollowerError: followerError,
      lastFollowerErrorAt: followerErrorAt,
    );
  }
}

/// What `compact` did.
@experimental
final class AnySyncCompaction {
  AnySyncCompaction._({
    required this.deleted,
    required this.failed,
    required this.supersedeDeletesRun,
    required this.bodiesRepaired,
  });

  /// Dominated objects deleted.
  final int deleted;
  final int failed;

  /// Waiting supersede deletes run (their successor had synced).
  final int supersedeDeletesRun;
  final int bodiesRepaired;
}

/// An account's lifecycle state.
@experimental
enum AnySyncAccountState { open, suspended, closed }

/// One location: a space and an index name in it.
@experimental
final class AnySyncLocation {
  /// [indexName]: 1–64 characters of `[a-z0-9._-]`; [spaceId]: an any-sync
  /// space id (letters and digits, dot-separated). [ArgumentError]
  /// otherwise.
  AnySyncLocation({required this.spaceId, required this.indexName}) {
    if (!_spacePattern.hasMatch(spaceId)) {
      throw ArgumentError.value(spaceId, 'spaceId', 'is not a space id');
    }
    if (!_indexPattern.hasMatch(indexName)) {
      throw ArgumentError.value(
        indexName,
        'indexName',
        'must be 1-64 characters of [a-z0-9._-]',
      );
    }
  }

  static final _spacePattern = RegExp(
    r'^[A-Za-z0-9]{1,200}(\.[A-Za-z0-9]{1,64})*$',
  );
  static final _indexPattern = RegExp(r'^[a-z0-9._-]{1,64}$');

  final String spaceId;
  final String indexName;

  /// Parses the canonical form `any:<spaceId>/<indexName>` and nothing else
  /// (no normalising): [FormatException] otherwise.
  static AnySyncLocation parse(String value) {
    if (!value.startsWith('any:')) {
      throw FormatException('not an any: location', value);
    }
    final rest = value.substring(4);
    final slash = rest.indexOf('/');
    if (slash < 0) throw FormatException('no index name', value);
    final AnySyncLocation loc;
    try {
      loc = AnySyncLocation(
        spaceId: rest.substring(0, slash),
        indexName: rest.substring(slash + 1),
      );
    } on ArgumentError catch (e) {
      throw FormatException('${e.message}', value);
    }
    if (loc.value != value) throw FormatException('not canonical', value);
    return loc;
  }

  /// What `VectorStoreSpec.location` carries.
  String get value => 'any:$spaceId/$indexName';

  @override
  bool operator ==(Object other) =>
      other is AnySyncLocation &&
      other.spaceId == spaceId &&
      other.indexName == indexName;

  @override
  int get hashCode => Object.hash(spaceId, indexName);

  @override
  String toString() => value;
}
