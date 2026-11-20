// An in-memory AnyNative for the unit tests: a network of devices with
// replicated spaces (objects with leaf-merged properties, records with
// $addToSet revs, deletes, a change feed per replica) and an any-store-like
// local index (generations, CAS, vector slots, exact kNN, a BM25-ish text
// search, Mongo-style filters on `f.*`).
//
// Every job and every result goes through a port, as on the real isolates,
// so a job that captures something that cannot cross an isolate (the store,
// a Completer) fails here first.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/src/native/any_native.dart';

AnyShimException _err(String op, AnyShimStatus s, String msg) =>
    AnyShimException(op, s.code, msg);

Future<T> _roundTrip<T>(T value) async {
  final port = ReceivePort();
  port.sendPort.send(value);
  return await port.first as T;
}

// ================================================================= network

/// The world: devices, their replicas, the links between them, and the
/// index "file system".
final class FakeNetwork {
  final devices = <String, FakeDevice>{};
  final _links = <(String, String)>{};
  final files = <String, FakeIndexFile>{};
  var _objectCounter = 0;
  var _spaceCounter = 0;

  /// Every runtime started on this network.
  final runtimes = <FakeRuntime>[];

  FakeNative native() => FakeNative(this);

  void link(FakeDevice a, FakeDevice b) =>
      _links.add(_pair(a.dataDir, b.dataDir));
  void unlink(FakeDevice a, FakeDevice b) =>
      _links.remove(_pair(a.dataDir, b.dataDir));

  (String, String) _pair(String a, String b) =>
      a.compareTo(b) < 0 ? (a, b) : (b, a);

  Iterable<FakeDevice> peersOf(FakeDevice d) => devices.values.where(
    (o) =>
        o != d &&
        o.isOpen &&
        o.mnemonic == d.mnemonic &&
        _links.contains(_pair(d.dataDir, o.dataDir)),
  );

  FakeDevice device(String dataDir) => devices[dataDir]!;

  String newObjectId() => 'obj${(++_objectCounter).toString().padLeft(8, '0')}';

  String newSpaceId() => 'space${++_spaceCounter}.fake';

  /// Delivers everything between [a] and [b] in both directions, for every
  /// space either has (the same account).
  void sync(FakeDevice a, FakeDevice b) {
    for (final id in {...a.spaces.keys, ...b.spaces.keys}) {
      final sa = a.spaces.putIfAbsent(
        id,
        () => FakeSpace(id, a, name: b.spaces[id]?.name ?? ''),
      );
      final sb = b.spaces.putIfAbsent(
        id,
        () => FakeSpace(id, b, name: a.spaces[id]?.name ?? ''),
      );
      sa.mergeFrom(sb);
      sb.mergeFrom(sa);
      for (final s in [sa, sb]) {
        s.everPeerSynced = true;
        s.lastSyncedAt = DateTime.now();
        for (final o in s.objects.values) {
          o.syncState = 'synced';
        }
      }
    }
  }

  /// Syncs [d] with every linked peer; whether one answered.
  bool syncLinked(FakeDevice d) {
    final peers = peersOf(d).toList();
    for (final p in peers) {
      sync(d, p);
    }
    return peers.isNotEmpty;
  }
}

final class FakeDevice {
  FakeDevice(this.network, this.dataDir, this.mnemonic, this.ownerToken);

  final FakeNetwork network;
  final String dataDir;
  final String mnemonic;
  String ownerToken;
  bool isOpen = true;
  bool closing = false;
  bool readOnly = false;

  /// The native close of a previous instance failed: opens are refused.
  bool poisoned = false;
  final spaces = <String, FakeSpace>{};
  final events = StreamController<Map<String, Object?>>.broadcast();

  /// Spaces with a change watch: only they get change events, as natively
  /// (lost when the account closes).
  final watched = <String>{};

  /// Set to make space_status report a failed account-state save.
  String? stateSaveError;

  /// Spaces whose resolve stays pending until the test removes them.
  final loading = <String>{};

  FakeSpace space(String id) {
    final s = spaces[id];
    if (s == null) {
      throw _err('fake', AnyShimStatus.notFound, 'space $id is not known');
    }
    return s;
  }

  void emit(Map<String, Object?> e) {
    if (e['kind'] == 'change' && !watched.contains(e['spaceId'])) return;
    if (!events.isClosed) events.add(e);
  }
}

/// A stored property write: the value and the write's order, for merges.
final class FakeVal {
  FakeVal(this.value) : t = ++_clock;
  final Object? value;
  final int t;
}

var _clock = 0;

final class FakeObject {
  FakeObject(this.id, this.typeId, {this.derived = false});
  final String id;
  final String typeId;
  final bool derived;
  bool deleted = false;
  String syncState = 'syncing';

  /// xkey -> value, or xkey -> (leaf -> value) for object-kind properties.
  final scalars = <String, FakeVal>{};
  final leaves = <String, Map<String, FakeVal>>{};
  String? body;

  Map<String, Object?> props(List<String>? xkeys) {
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in scalars.entries) {
      if (xkeys == null || xkeys.contains(key)) out[key] = value.value;
    }
    for (final MapEntry(:key, :value) in leaves.entries) {
      if (xkeys == null || xkeys.contains(key)) {
        out[key] = {for (final l in value.entries) l.key: l.value.value};
      }
    }
    return out;
  }

  bool get hasProps => scalars.isNotEmpty || leaves.isNotEmpty;
}

final class FakeRecord {
  FakeRecord(this.id);
  final String id;
  FakeVal? key;
  final revs = <Object?>{};
  int applySeq = 0;
}

final class FakeSpace {
  FakeSpace(this.id, this.device, {required this.name});

  final String id;
  final FakeDevice device;
  final String name;
  bool createdHere = false;
  bool everPeerSynced = false;
  DateTime? lastSyncedAt;
  bool definitions = false;
  String generation = 'g1';
  int seq = 0;
  final objects = <String, FakeObject>{};
  final log = <({String objectId, int applySeq, bool deleted})>[];

  /// (objectId, collection) -> record id -> record.
  final records = <(String, String), Map<String, FakeRecord>>{};

  /// Objects an id read answers `missing` for (a type page still lists
  /// them).
  final hiddenFromIdReads = <String>{};

  /// Called after each type page of object_read is read; tests insert
  /// there.
  void Function(String? after)? onTypePage;

  int change(String objectId, {bool deleted = false}) {
    seq++;
    log.add((objectId: objectId, applySeq: seq, deleted: deleted));
    device.emit({
      'kind': 'change',
      'spaceId': id,
      'objectId': objectId,
      'applySeq': seq,
      'deleted': deleted,
    });
    return seq;
  }

  /// The SDK's own database was rebuilt: a new generation, the feed
  /// renumbered from 1.
  void rebuildSdkDb() {
    generation = 'g${int.parse(generation.substring(1)) + 1}';
    seq = 0;
    log.clear();
    for (final o in objects.values) {
      if (!o.deleted) change(o.id);
    }
    for (final MapEntry(:key, :value) in records.entries) {
      for (final r in value.values) {
        r.applySeq = seq;
      }
      if (value.isNotEmpty && !objects[key.$1]!.deleted) change(key.$1);
    }
  }

  void mergeFrom(FakeSpace other) {
    if (other.definitions) definitions = true;
    for (final o in other.objects.values) {
      final mine = objects[o.id];
      var changed = false;
      final target =
          mine ??
          (objects[o.id] = FakeObject(o.id, o.typeId, derived: o.derived));
      if (mine == null) changed = true;
      if (o.deleted && !target.deleted) {
        target.deleted = true;
        change(o.id, deleted: true);
        continue;
      }
      if (target.deleted) continue;
      for (final MapEntry(:key, :value) in o.scalars.entries) {
        final cur = target.scalars[key];
        if (cur == null || cur.t < value.t) {
          target.scalars[key] = value;
          changed = true;
        }
      }
      for (final MapEntry(:key, :value) in o.leaves.entries) {
        final mineLeaves = target.leaves.putIfAbsent(key, () => {});
        for (final l in value.entries) {
          final cur = mineLeaves[l.key];
          if (cur == null || cur.t < l.value.t) {
            mineLeaves[l.key] = l.value;
            changed = true;
          }
        }
      }
      target.body ??= o.body;
      if (changed) change(o.id);
    }
    for (final MapEntry(:key, :value) in other.records.entries) {
      final mine = records.putIfAbsent(key, () => {});
      var changed = false;
      for (final r in value.values) {
        final m = mine.putIfAbsent(r.id, () {
          changed = true;
          return FakeRecord(r.id);
        });
        if (r.key != null && (m.key == null || m.key!.t < r.key!.t)) {
          m.key = r.key;
          changed = true;
        }
        final before = m.revs.length;
        m.revs.addAll(r.revs);
        if (m.revs.length != before) changed = true;
        if (changed) m.applySeq = seq + 1;
      }
      if (changed) change(key.$1);
    }
  }
}

// =============================================================== runtime

final class FakeNative implements AnyNative {
  FakeNative(this.network);
  final FakeNetwork network;
  var _keys = 0;

  @override
  bool get supported => true;

  @override
  Future<String> newMnemonic() async =>
      'test mnemonic ${++_keys} ${math.Random().nextInt(1 << 30)}';

  @override
  Future<String> newDeviceKey() async =>
      'device${++_keys}${math.Random().nextInt(1 << 30)}';

  @override
  Future<AnyRuntime> start() async {
    final rt = FakeRuntime(network);
    network.runtimes.add(rt);
    return rt;
  }
}

final class FakeRuntime implements AnyRuntime {
  FakeRuntime(this.network) {
    sdkImpl = FakeSdk(this);
    indexHost = FakeIndexHost(network);
  }

  final FakeNetwork network;
  late final FakeSdk sdkImpl;
  late final FakeIndexHost indexHost;
  bool disposed = false;
  final attachedAccounts = <Object>{};
  final attachedIndexes = <Object>{};

  /// Throws from the next index job whose name (the job's runtime type is
  /// opaque, so the test names the state key) matches; set by tests.
  bool Function()? failIndexJob;

  @override
  Future<T> sdk<T>(SdkJob<T> job) async {
    if (disposed) throw StateError('runtime stopped');
    final j = await _roundTrip(job);
    return _roundTrip(await j(sdkImpl));
  }

  @override
  Future<T> index<T>(IndexJob<T> job) async {
    if (disposed) throw StateError('runtime stopped');
    final j = await _roundTrip(job);
    final fail = failIndexJob;
    if (fail != null && fail()) {
      throw _err('any_shim_index_apply', AnyShimStatus.io, 'injected');
    }
    return _roundTrip(await j(indexHost));
  }

  @override
  void cancelAccount(int handle) => sdkImpl.cancelAll();

  @override
  Stream<Map<String, Object?>> events(int handle) {
    final d = sdkImpl.device;
    if (d == null) return const Stream.empty();
    final c = StreamController<Map<String, Object?>>();
    final sub = d.events.stream.listen(c.add);
    c.onCancel = sub.cancel;
    _pollers.add(c);
    pollersStarted++;
    // As the FFI poller after its first successful poll.
    if (pollerReady) scheduleMicrotask(() => c.add(pollerReadyEvent));
    return c.stream;
  }

  /// Whether a new poller reports ready (a successful first poll).
  bool pollerReady = true;

  final _pollers = <StreamController<Map<String, Object?>>>[];
  int pollersStarted = 0;

  /// The events poller gives up (as the FFI one does after 20 failures).
  void failEvents(String why) {
    for (final c in [..._pollers]) {
      if (!c.isClosed) {
        c.addError(StateError(why));
        c.close();
      }
    }
    _pollers.clear();
  }

  @override
  void attachAccount(Object owner, int handle) => attachedAccounts.add(owner);
  @override
  void detachAccount(Object owner) => attachedAccounts.remove(owner);
  @override
  void attachIndex(Object owner, int handle) => attachedIndexes.add(owner);
  @override
  void detachIndex(Object owner) => attachedIndexes.remove(owner);

  @override
  Future<void> dispose() async => disposed = true;
}

// =================================================================== SDK

const _docXkeys = {'doc': false, 'vecs': true};
const _locXkeys = {
  'core': true,
  'fields': true,
  'profiles': true,
  'textSearch': true,
};
const locRoot = 'locroot';
const docRoot = 'docroot';
const tombColl = 'locroot_tombstones';

final class _Op {
  _Op(this.run);
  final FutureOr<Map<String, Object?>> Function() run;
  Map<String, Object?>? result;
  Object? error;
  bool done = false;
  bool cancelled = false;

  /// Completes the op when the test says so (null = at the first wait).
  bool Function()? ready;
}

final class FakeSdk implements AnySdk {
  FakeSdk(this.rt);
  final FakeRuntime rt;
  FakeDevice? device;
  int? _handle;
  static var _handles = 100;
  final _ops = <int, _Op>{};
  static var _opIds = 1;

  FakeNetwork get network => rt.network;

  FakeDevice get _d {
    final d = device;
    if (d == null || _handle == null || !d.isOpen) {
      throw _err('fake', AnyShimStatus.closed, 'account closed');
    }
    return d;
  }

  void cancelAll() {
    for (final op in _ops.values) {
      op.cancelled = true;
    }
  }

  @override
  int? get accountHandle => _handle;

  /// The claim is taken in the start (REFUSED for the same token, BUSY for
  /// another or a close in progress, as natively); the op opens.
  @override
  int openAccountStart(Map<String, Object?> options) {
    const op = 'any_shim_account_open_start';
    final dir = options['dataDir']! as String;
    final token = options['ownerToken']! as String;
    final existing = network.devices[dir];
    if (existing != null) {
      if (existing.poisoned) {
        throw _err(
          op,
          AnyShimStatus.refused,
          'the previous instance failed to close; restart the app',
        );
      }
      if (existing.closing ||
          (existing.isOpen && existing.ownerToken != token)) {
        throw _err(op, AnyShimStatus.busy, 'held by a previous owner');
      }
      if (existing.isOpen) {
        throw _err(op, AnyShimStatus.refused, 'already open in this process');
      }
      existing.isOpen = true;
      existing.ownerToken = token;
    } else {
      network.devices[dir] = FakeDevice(
        network,
        dir,
        options['mnemonic']! as String,
        token,
      );
    }
    final h = ++_handles;
    return _start(
      () => {'account': h, '_dir': dir},
      ready: openReadyOnLastPoll ? () => _lastPollWait == 0 : null,
    );
  }

  @override
  int adoptAccount(Map<String, Object?> openResult) {
    device = network.devices[openResult['_dir']! as String];
    _handle = openResult['account']! as int;
    return _handle!;
  }

  /// Ends the account; with [waitLoadsMs] the op waits for space loads in
  /// flight (the test's `loading` set) first, and a load is not cancelled.
  int? lastCloseWaitLoadsMs;

  @override
  int closeAccountStart({int waitLoadsMs = 0}) {
    final d = _d;
    _handle = null;
    lastCloseWaitLoadsMs = waitLoadsMs;
    d.closing = true;
    if (waitLoadsMs == 0) cancelAll();
    return _start(() {
      d.isOpen = false;
      d.closing = false;
      d.watched.clear();
      if (failClose) {
        throw _err('any_shim_op_wait', AnyShimStatus.internal, 'sdk close');
      }
      return {};
    }, ready: () => waitLoadsMs == 0 || d.loading.isEmpty);
  }

  /// Computed: it needs no loaded space (D-R12), only the account.
  @override
  Map<String, Object?> objectDeriveId(String spaceId, String seed) {
    _d;
    return {'id': derivedId(seed)};
  }

  static String derivedId(String seed) =>
      'derived${seed.hashCode.toUnsigned(32)}';

  int _start(
    FutureOr<Map<String, Object?>> Function() run, {
    bool Function()? ready,
  }) {
    final id = _opIds++;
    _ops[id] = _Op(run)..ready = ready;
    return id;
  }

  int _lastPollWait = -1;

  @override
  OpPoll opWait(int op, int waitMs) {
    _lastPollWait = waitMs;
    final o = _ops[op];
    if (o == null) throw _err('any_shim_op_wait', AnyShimStatus.closed, 'op');
    if (o.cancelled) {
      _ops.remove(op);
      throw _err('any_shim_op_wait', AnyShimStatus.closed, 'cancelled');
    }
    if (o.ready != null && !o.ready!()) return const OpPoll.pending();
    _ops.remove(op);
    final r = o.run();
    return OpPoll.done(r as Map<String, Object?>);
  }

  @override
  void opCancel(int op) => _ops.remove(op);

  @override
  Map<String, Object?> accountInfo() => {
    'accountId': _d.mnemonic,
    'peerId': _d.dataDir,
  };

  @override
  Map<String, Object?> spaceCreate(String name) {
    final d = _d;
    final id = network.newSpaceId();
    d.spaces[id] = FakeSpace(id, d, name: name)..createdHere = true;
    return {'id': id, 'stateSaveError': ?d.stateSaveError};
  }

  @override
  Map<String, Object?> spaceList() => {
    'spaces': [
      for (final s in _d.spaces.values)
        {'id': s.id, 'name': s.name, 'status': 'ok'},
    ],
  };

  /// The peer request never answers (a blackhole).
  bool listSyncHangs = false;

  @override
  int spaceListSyncStart(int timeoutMs) {
    final d = _d;
    return _start(ready: () => !listSyncHangs, () {
      for (final p in network.peersOf(d)) {
        for (final s in p.spaces.values) {
          d.spaces.putIfAbsent(s.id, () => FakeSpace(s.id, d, name: s.name));
        }
      }
      return {...spaceList(), 'syncError': null, 'timedOut': false};
    });
  }

  @override
  int spaceResolveStart(String spaceId) {
    final d = _d;
    final s = d.space(spaceId);
    return _start(() {
      // A first load of a space learned from a peer fetches it from them.
      if (!s.everPeerSynced && !s.createdHere) network.syncLinked(d);
      return {'spaceId': spaceId};
    }, ready: () => !d.loading.contains(spaceId));
  }

  @override
  Map<String, Object?> spaceStatus(String spaceId) {
    final d = _d;
    final s = d.space(spaceId);
    final online = network.peersOf(d).isNotEmpty;
    return {
      'spaceId': spaceId,
      'state': s.everPeerSynced && online ? 'synced' : 'offline',
      'loading': d.loading.contains(spaceId),
      'localPeers': network.peersOf(d).length,
      'networkPeers': 0,
      'globalPeers': 0,
      'lastSyncedAt': s.lastSyncedAt?.toUtc().toIso8601String(),
      'everPeerSynced': s.everPeerSynced,
      'createdHere': s.createdHere,
      'stateSaveError': d.stateSaveError,
    };
  }

  @override
  int syncHeadsStart(String spaceId, int timeoutMs) {
    final d = _d;
    d.space(spaceId);
    return _start(() {
      final reached = network.syncLinked(d);
      return {'reachedPeer': reached, 'timedOut': false, 'error': null};
    });
  }

  @override
  Map<String, Object?> ragBundles(String spaceId, {required bool ensure}) {
    final d = _d;
    final s = d.space(spaceId);
    if (ensure) {
      if (d.readOnly) {
        throw _err('any_shim_rag_bundles', AnyShimStatus.refused, 'read-only');
      }
      s.definitions = true;
    } else if (!s.definitions) {
      throw _err('any_shim_rag_bundles', AnyShimStatus.notFound, 'not synced');
    }
    return {
      'location': {
        'rootId': locRoot,
        'properties': {for (final k in _locXkeys.keys) k: 'p-$k'},
        'tombstones': tombColl,
      },
      'document': {
        'rootId': docRoot,
        'properties': {for (final k in _docXkeys.keys) k: 'p-$k'},
      },
    };
  }

  /// Objects created through [objectPatch] get ids from here; a test can
  /// set the next one (an insert below a rebuild's `after`).
  String? nextObjectId;

  @override
  Map<String, Object?> objectPatch(
    String spaceId,
    Map<String, Object?> target,
    List<Object?> ops,
  ) {
    const op = 'any_shim_object_patch';
    final d = _d;
    final s = d.space(spaceId);
    FakeObject obj;
    var created = false;
    if (target['id'] != null) {
      final o = s.objects[target['id']];
      if (o == null) throw _err(op, AnyShimStatus.notFound, 'no object');
      if (o.deleted) throw _err(op, AnyShimStatus.deleted, 'deleted');
      obj = o;
    } else if (target['create'] != null) {
      final type = (target['create']! as Map)['type'] as String;
      if (!s.definitions) throw _err(op, AnyShimStatus.notFound, 'type');
      final id = nextObjectId ?? network.newObjectId();
      nextObjectId = null;
      obj = FakeObject(id, type);
      created = true;
    } else {
      final dr = target['derive']! as Map;
      final type = dr['type'] as String;
      if (!s.definitions) throw _err(op, AnyShimStatus.notFound, 'type');
      final id = derivedId(dr['seed'] as String);
      final existing = s.objects[id];
      if (existing != null) {
        obj = existing;
      } else {
        obj = FakeObject(id, type, derived: true);
        created = true;
      }
    }
    if (failPatch != null && failPatch!(target, ops)) {
      throw _err(op, failPatchStatus, failPatchMessage);
    }
    if (ops.isNotEmpty && d.readOnly) {
      throw _err(op, AnyShimStatus.refused, 'read-only');
    }
    final decl = obj.typeId == docRoot ? _docXkeys : _locXkeys;
    for (final raw in ops) {
      final m = raw! as Map;
      final xkey = m['xkey'] as String;
      if (!decl.containsKey(xkey)) {
        throw _err(op, AnyShimStatus.invalidArgument, 'undeclared $xkey');
      }
      final leaf = m['leaf'] as String?;
      if ((leaf != null) != decl[xkey]!) {
        throw _err(op, AnyShimStatus.invalidArgument, 'leaf on $xkey');
      }
      if (leaf != null && !RegExp(r'^[0-9a-z-]+$').hasMatch(leaf)) {
        throw _err(op, AnyShimStatus.refused, 'crdt: validation rejected');
      }
    }
    // A create is one change; so is a patch.
    if (created) s.objects[obj.id] = obj;
    for (final raw in ops) {
      final m = raw! as Map;
      final xkey = m['xkey'] as String;
      final leaf = m['leaf'] as String?;
      final v = FakeVal(jsonDecode(jsonEncode(m['value'])));
      if (leaf == null) {
        obj.scalars[xkey] = v;
      } else {
        obj.leaves.putIfAbsent(xkey, () => {})[leaf] = v;
      }
    }
    obj.syncState = network.peersOf(d).isEmpty ? 'syncing' : obj.syncState;
    if (created || ops.isNotEmpty) s.change(obj.id);
    return {'id': obj.id, 'created': created};
  }

  @override
  void objectSetBody(String spaceId, String objectId, String text) {
    final o = _d.space(spaceId).objects[objectId];
    if (o == null) throw _err('body', AnyShimStatus.notFound, 'no object');
    if (o.deleted) throw _err('body', AnyShimStatus.deleted, 'deleted');
    if (failBodies) throw _err('body', AnyShimStatus.internal, 'injected');
    o.body = text;
  }

  bool failBodies = false;

  AnyShimStatus failPatchStatus = AnyShimStatus.internal;
  String failPatchMessage = 'injected';

  /// Refuses a patch the test names.
  bool Function(Map<String, Object?> target, List<Object?> ops)? failPatch;

  @override
  Map<String, Object?> objectRead(
    String spaceId,
    Map<String, Object?> request,
  ) {
    final s = _d.space(spaceId);
    final xkeys = (request['xkeys'] as List?)?.cast<String>();
    Map<String, Object?> item(String id, {bool byId = false}) {
      final o = byId && s.hiddenFromIdReads.contains(id) ? null : s.objects[id];
      if (o == null) {
        return {'id': id, 'typeId': '', 'state': 'missing', 'props': {}};
      }
      return {
        'id': id,
        'typeId': o.typeId,
        'state': o.deleted ? 'deleted' : (o.hasProps ? 'ok' : 'missing'),
        'props': o.deleted ? {} : o.props(xkeys),
      };
    }

    final anchor = {'generation': s.generation, 'maxApplySeq': s.seq};
    if (request['ids'] != null) {
      return {
        'anchor': anchor,
        'items': [
          for (final id in (request['ids']! as List))
            item(id as String, byId: true),
        ],
        'next': null,
      };
    }
    final after = request['after'] as String?;
    final type = request['type'] as String;
    final limit = (request['limit'] as int?) ?? 100;
    final ids =
        s.objects.values
            .where(
              (o) =>
                  o.typeId == type &&
                  !o.deleted &&
                  (after == null || o.id.compareTo(after) > 0),
            )
            .map((o) => o.id)
            .toList()
          ..sort();
    final page = ids.take(limit).toList();
    final out = {
      'anchor': anchor,
      'items': [for (final id in page) item(id)],
      'next': ids.length > limit ? page.last : null,
    };
    // After the page is read: what the hook inserts is not in it.
    s.onTypePage?.call(after);
    return out;
  }

  @override
  void objectDelete(String spaceId, String objectId) {
    final s = _d.space(spaceId);
    final o = s.objects[objectId];
    if (o == null) throw _err('delete', AnyShimStatus.notFound, 'no object');
    if (o.derived) throw _err('delete', AnyShimStatus.refused, 'derived');
    if (_d.readOnly) throw _err('delete', AnyShimStatus.refused, 'read-only');
    if (o.deleted) return;
    o.deleted = true;
    s.change(objectId, deleted: true);
  }

  @override
  Map<String, Object?> objectSyncState(String spaceId, String objectId) {
    final o = _d.space(spaceId).objects[objectId];
    if (o == null) throw _err('sync', AnyShimStatus.notFound, 'no object');
    if (failSyncState) {
      throw _err('any_shim_object_sync_state', AnyShimStatus.internal, 'x');
    }
    return {'state': o.syncState};
  }

  @override
  void recordsModify(
    String spaceId,
    String objectId,
    String collection,
    List<Object?> records,
  ) {
    const op = 'any_shim_records_modify';
    final d = _d;
    final s = d.space(spaceId);
    final o = s.objects[objectId];
    if (o == null) throw _err(op, AnyShimStatus.notFound, 'no object');
    if (collection != tombColl) {
      throw _err(op, AnyShimStatus.invalidArgument, 'collection');
    }
    if (d.readOnly) throw _err(op, AnyShimStatus.refused, 'read-only');
    final seq = s.seq + 1;
    final coll = s.records.putIfAbsent((objectId, collection), () => {});
    for (final raw in records) {
      final m = raw! as Map;
      final r = coll.putIfAbsent(
        m['id'] as String,
        () => FakeRecord(m['id'] as String),
      );
      final set = (m['set'] as Map?) ?? const {};
      if (set.containsKey('key')) r.key = FakeVal(set['key']);
      final add = (m['addToSet'] as Map?) ?? const {};
      final revs = add['revs'];
      if (revs is List) {
        r.revs.addAll(revs);
      } else if (revs != null) {
        r.revs.add(revs);
      }
      r.applySeq = seq;
    }
    s.change(objectId);
  }

  @override
  Map<String, Object?> recordsRead(
    String spaceId,
    String objectId,
    String collection, {
    String? after,
    int sinceApplySeq = 0,
    int limit = 0,
  }) {
    final s = _d.space(spaceId);
    final coll = s.records[(objectId, collection)] ?? const {};
    final n = limit <= 0 ? 500 : limit;
    final all =
        coll.values
            .where(
              (r) =>
                  r.applySeq > sinceApplySeq &&
                  (after == null || after.isEmpty || r.id.compareTo(after) > 0),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final page = all.take(n).toList();
    return {
      'records': [
        for (final r in page)
          {
            'id': r.id,
            if (r.key != null) 'key': r.key!.value,
            'revs': [...r.revs],
            '_applySeq': r.applySeq,
          },
      ],
      'next': all.length > n ? page.last.id : null,
    };
  }

  @override
  Map<String, Object?> changesSince(
    String spaceId,
    int since, {
    int limit = 0,
  }) {
    final s = _d.space(spaceId);
    final n = limit <= 0 ? 500 : limit;
    final out = s.log.where((c) => c.applySeq > since).take(n);
    return {
      'generation': s.generation,
      'maxApplySeq': s.seq,
      'changes': [
        for (final c in out)
          {
            'objectId': c.objectId,
            'applySeq': c.applySeq,
            'deleted': c.deleted,
          },
      ],
    };
  }

  var _watches = 0;

  /// Change watches that fail before one succeeds.
  int failWatches = 0;

  /// The open op finishes only at the poll that does not wait (the last
  /// poll after a deadline).
  bool openReadyOnLastPoll = false;
  bool failSyncState = false;

  @override
  int watchChanges(String spaceId) {
    if (failWatches > 0) {
      failWatches--;
      throw _err('any_shim_watch_changes', AnyShimStatus.internal, 'no watch');
    }
    _d.space(spaceId);
    _d.watched.add(spaceId);
    return ++_watches;
  }

  @override
  int watchSyncStatus() {
    if (failStatusWatches > 0) {
      failStatusWatches--;
      throw _err('any_shim_watch_sync_status', AnyShimStatus.internal, 'no');
    }
    return ++_watches;
  }

  /// Sync status watches that fail before one succeeds.
  int failStatusWatches = 0;

  /// The account's native close answers an error (it still ends).
  bool failClose = false;

  @override
  void unwatch(int watch) {}

  @override
  Future<T> toIndex<T>(IndexJob<T> job) => rt.index(job);
}

// ================================================================ index

final class FakeIndexFile {
  FakeIndexFile(this.path, this.keyHex);
  final String path;
  final String? keyHex;
  String? ownerToken;
  bool open = false;
  bool closing = false;

  /// Op polls a running bind still answers pending; while it runs, every
  /// other call on the index answers PENDING (G-R4).
  int binding = 0;

  /// Orphan generations a swap left behind, dropped by gc.
  int orphans = 0;
  Map<String, Object?>? config;
  var active = <String, FakeRow>{};
  var state = <String, String>{};
  Map<String, FakeRow>? shadow;
  Map<String, String>? shadowState;
}

final class FakeRow {
  FakeRow(this.id, this.text, this.meta, this.f, this.vector);
  final String id;
  final String text;
  final Object? meta;
  final Map<String, Object?> f;
  final Float32List? vector;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'meta': meta,
    'f': f,
  };
}

final class FakeIndexHost implements AnyIndexHost {
  FakeIndexHost(this.network);
  final FakeNetwork network;
  final _open = <int, FakeIndexFile>{};
  static var _handles = 1000;
  final _ops = <int, Map<String, Object?>? Function()>{};
  static var _opIds = 1;

  /// How many op polls a bind takes (0: done at the first wait).
  static int bindSlices = 0;

  /// The bind op answers CONFLICT, as natively under concurrent binds.
  static bool bindConflictInOp = false;

  int start(Map<String, Object?>? Function() run) {
    final id = _opIds++;
    _ops[id] = run;
    return id;
  }

  @override
  OpPoll opWait(int op, int waitMs) {
    final run = _ops[op];
    if (run == null) throw _err('any_shim_op_wait', AnyShimStatus.closed, 'op');
    final r = run();
    if (r == null) return const OpPoll.pending();
    _ops.remove(op);
    return OpPoll.done(r);
  }

  @override
  void opCancel(int op) => _ops.remove(op);

  @override
  int open(Map<String, Object?> options) {
    final path = options['path']! as String;
    final key = options['keyHex'] as String?;
    final token = options['ownerToken'] as String?;
    var f = network.files[path];
    if (f == null) {
      f = network.files[path] = FakeIndexFile(path, key);
    } else {
      if (f.closing || (f.open && f.ownerToken != token)) {
        throw _err('any_shim_index_open', AnyShimStatus.busy, 'held');
      }
      if (f.open) {
        throw _err('any_shim_index_open', AnyShimStatus.refused, 'same owner');
      }
      if (f.keyHex == null && key != null) {
        throw _err('any_shim_index_open', AnyShimStatus.keyMismatch, 'plain');
      }
      if (f.keyHex != null && key == null) {
        throw _err('any_shim_index_open', AnyShimStatus.keyMissing, 'key');
      }
      if (f.keyHex != key) {
        throw _err('any_shim_index_open', AnyShimStatus.keyMismatch, 'key');
      }
    }
    f.open = true;
    f.ownerToken = token;
    f.shadow = null;
    f.shadowState = null;
    final h = ++_handles;
    _open[h] = f;
    return h;
  }

  @override
  AnyIndexApi index(int handle) => FakeIndex(this, handle);
}

final class FakeIndex implements AnyIndexApi {
  FakeIndex(this.host, this.handle);
  final FakeIndexHost host;
  final int handle;

  FakeIndexFile get _f {
    final f = host._open[handle];
    if (f == null) {
      throw _err('any_shim_index_call', AnyShimStatus.closed, 'closed');
    }
    if (f.binding > 0) {
      throw _err('any_shim_index_call', AnyShimStatus.pending, 'index busy');
    }
    return f;
  }

  @override
  int closeStart() {
    final f = _f;
    host._open.remove(handle);
    f.closing = true;
    return host.start(() {
      f.open = false;
      f.closing = false;
      if (FakeIndex.failClose) {
        throw _err('any_shim_op_wait', AnyShimStatus.internal, 'index close');
      }
      return {};
    });
  }

  /// The index's native close answers an error (it still ends).
  static bool failClose = false;

  /// A state scan of this prefix answers IO (or, with [failScanWithError],
  /// throws an Error, as a stopped runtime fails its calls).
  static String? failScanPrefix;
  static bool failScanWithError = false;

  @override
  int bindStart(Map<String, Object?> config) {
    final r = bind(config);
    final f = _f;
    f.binding = FakeIndexHost.bindSlices;
    return host.start(() {
      if (f.binding > 0) {
        f.binding--;
        return null;
      }
      if (FakeIndexHost.bindConflictInOp) {
        throw _err('any_shim_op_wait', AnyShimStatus.conflict, 'bind race');
      }
      return r;
    });
  }

  /// gc answers this error (an orphan it cannot drop).
  static AnyShimException? gcError;

  @override
  Map<String, Object?> gc(int budgetMs) {
    final f = _f;
    final e = gcError;
    if (e != null) throw e;
    if (f.orphans > 0) f.orphans--;
    return {'done': f.orphans == 0};
  }

  Map<String, Object?> bind(Map<String, Object?> config) {
    final f = _f;
    final have = f.config;
    if (have == null) {
      f.config = jsonDecode(jsonEncode(config)) as Map<String, Object?>;
      return f.config!;
    }
    if (have['dim'] != config['dim'] || have['metric'] != config['metric']) {
      throw _err('any_shim_index_bind', AnyShimStatus.conflict, 'dim');
    }
    final fields = [
      for (final x in (have['fields'] as List))
        (x as Map).cast<String, Object?>(),
    ];
    for (final x in (config['fields'] as List)) {
      final m = (x as Map).cast<String, Object?>();
      final same = fields.where((y) => y['key'] == m['key']);
      if (same.isEmpty) {
        fields.add(m);
      } else if (same.first['type'] != m['type']) {
        throw _err('any_shim_index_bind', AnyShimStatus.conflict, 'type');
      }
    }
    f.config = {
      ...have,
      'fields': fields,
      'textSearch': have['textSearch'] == true || config['textSearch'] == true,
    };
    return f.config!;
  }

  @override
  Map<String, Object?> info() {
    final c = _f.config;
    return c == null ? {} : {...c, 'fileId': 'fake'};
  }

  /// Every apply goes through here; a test may refuse one.
  static bool Function(Map<String, Object?> ops)? failApply;

  /// Refuses (INVALID_ARGUMENT, before the CAS like the shim's validation)
  /// an apply carrying a vector this says no to: a vector the shim checks
  /// differently than Dart.
  static bool Function(Float32List vector)? refuseVector;

  /// The status [failApply] answers with.
  static AnyShimStatus failApplyStatus = AnyShimStatus.io;

  @override
  Map<String, Object?> apply(Map<String, Object?> ops, Float32List vectors) {
    const op = 'any_shim_index_apply';
    final f = _f;
    final list = [
      for (final x in (ops['ops'] as List? ?? const []))
        (x as Map).cast<String, Object?>(),
    ];
    // Validate everything first.
    var at = 0;
    for (final o in list) {
      final v = o['vector'];
      if (o['op'] == 'upsert' && v != null) {
        final slot = (v as Map).cast<String, Object?>();
        if (f.config == null) throw _err(op, AnyShimStatus.refused, 'unbound');
        final offset = slot['offset']! as int;
        final dim = slot['dim']! as int;
        if (offset != at ||
            dim != f.config!['dim'] ||
            offset + dim > vectors.length) {
          throw _err(op, AnyShimStatus.invalidArgument, 'slot');
        }
        for (var i = offset; i < offset + dim; i++) {
          if (!vectors[i].isFinite) {
            throw _err(op, AnyShimStatus.invalidArgument, 'NaN');
          }
        }
        final refuse = refuseVector;
        if (refuse != null &&
            refuse(Float32List.sublistView(vectors, offset, offset + dim))) {
          throw _err(op, AnyShimStatus.invalidArgument, 'vector refused');
        }
        at += dim;
      }
      if ((o['coll'] == 'shadow' || o['coll'] == 'shadowState') &&
          f.shadow == null &&
          !list.any((x) => x['op'] == 'shadowBegin')) {
        throw _err(op, AnyShimStatus.invalidArgument, 'no shadow');
      }
    }
    if (at != vectors.length) {
      throw _err(op, AnyShimStatus.invalidArgument, 'slots do not tile');
    }
    for (final c in (ops['cas'] as List? ?? const [])) {
      final m = (c as Map).cast<String, Object?>();
      if (f.state[m['key']] != m['expect']) {
        throw _err(op, AnyShimStatus.conflict, 'cas ${m['key']}');
      }
    }
    final fail = failApply;
    if (fail != null && fail(ops)) {
      throw _err(op, failApplyStatus, 'injected');
    }

    for (final o in list) {
      Map<String, FakeRow> rows() =>
          o['coll'] == 'shadow' ? f.shadow! : f.active;
      Map<String, String> st() =>
          o['coll'] == 'shadowState' ? f.shadowState! : f.state;
      switch (o['op']) {
        case 'upsert':
          final slot = o['vector'] as Map?;
          Float32List? vec;
          if (slot != null) {
            final off = slot['offset'] as int;
            vec = Float32List.fromList(
              vectors.sublist(off, off + (slot['dim'] as int)),
            );
          }
          rows()[o['id']! as String] = FakeRow(
            o['id']! as String,
            o['text']! as String,
            o['meta'],
            ((o['f'] as Map?) ?? const {}).cast(),
            vec,
          );
        case 'delete':
          rows().remove(o['id']);
        case 'clearDocs':
          rows().clear();
        case 'stateSet':
          final v = o['value'] as String?;
          if (v == null) {
            st().remove(o['key']);
          } else {
            st()[o['key']! as String] = v;
          }
        case 'shadowBegin':
          f.shadow = {};
          f.shadowState = {};
        case 'shadowSwap':
          f.orphans++;
          f.active = f.shadow!;
          f.state = f.shadowState!;
          f.shadow = null;
          f.shadowState = null;
        default:
          throw _err(op, AnyShimStatus.invalidArgument, 'op ${o['op']}');
      }
    }
    return {'applied': list.length};
  }

  @override
  String? getState(String key, {bool shadow = false}) =>
      (shadow ? _f.shadowState : _f.state)?[key];

  @override
  Map<String, Object?>? getRow(String id, {bool shadow = false}) =>
      (shadow ? _f.shadow : _f.active)?[id]?.toJson();

  @override
  ({List<(String, String)> entries, String? next}) scanState({
    String? prefix,
    String? after,
    int limit = 0,
    bool shadow = false,
  }) {
    final failing = failScanPrefix;
    if (failing != null && prefix == failing) {
      if (failScanWithError) throw StateError('runtime stopped');
      throw _err('any_shim_index_scan', AnyShimStatus.io, 'scan refused');
    }
    final st = (shadow ? _f.shadowState : _f.state) ?? const {};
    final n = limit <= 0 ? 500 : limit;
    final keys =
        st.keys
            .where(
              (k) =>
                  (prefix == null || k.startsWith(prefix)) &&
                  (after == null || k.compareTo(after) > 0),
            )
            .toList()
          ..sort();
    final page = keys.take(n).toList();
    return (
      entries: [for (final k in page) (k, st[k]!)],
      next: keys.length > n ? page.last : null,
    );
  }

  @override
  ({List<Map<String, Object?>> rows, String? next}) scanRows({
    String? after,
    int limit = 0,
  }) {
    final ids =
        _f.active.keys
            .where((k) => after == null || k.compareTo(after) > 0)
            .toList()
          ..sort();
    final n = limit <= 0 ? 500 : limit;
    final page = ids.take(n).toList();
    return (
      rows: [for (final id in page) _f.active[id]!.toJson()],
      next: ids.length > n ? page.last : null,
    );
  }

  @override
  int count() => _f.active.length;

  @override
  int countVectors() => _f.active.values.where((r) => r.vector != null).length;

  @override
  Map<String, Object?> knn(
    Float32List query,
    int k,
    Map<String, Object?>? filter,
  ) {
    final f = _f;
    if (query.length != f.config?['dim']) {
      throw _err('any_shim_index_knn', AnyShimStatus.invalidArgument, 'dim');
    }
    final hits = <(double, FakeRow)>[];
    for (final r in f.active.values) {
      final v = r.vector;
      if (v == null || (filter != null && !matches(filter, r))) continue;
      hits.add((1 - cosine(query, v), r));
    }
    hits.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.id.compareTo(b.$2.id);
    });
    return {
      'results': [
        for (final (d, r) in hits.take(k))
          {'id': r.id, 'text': r.text, 'meta': r.meta, 'distance': d},
      ],
    };
  }

  static double cosine(Float32List a, Float32List b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  @override
  Map<String, Object?> text(String query, int k, Map<String, Object?>? filter) {
    final f = _f;
    if (f.config?['textSearch'] != true) {
      throw _err('any_shim_index_text', AnyShimStatus.refused, 'no text');
    }
    // `"a" "b"`: quoted phrases, OR'ed.
    final terms = <String>[
      for (final m in RegExp(r'"((?:[^"]|"")*)"').allMatches(query))
        ...(_word
            .allMatches(m.group(1)!.replaceAll('""', '"').toLowerCase())
            .map((w) => w.group(0)!)),
    ];
    final rows = f.active.values.toList();
    final df = <String, int>{};
    final tokens = {
      for (final r in rows)
        r.id: [
          for (final w in _word.allMatches(r.text.toLowerCase())) w.group(0)!,
        ],
    };
    for (final t in terms.toSet()) {
      df[t] = rows.where((r) => tokens[r.id]!.contains(t)).length;
    }
    final hits = <(double, FakeRow)>[];
    for (final r in rows) {
      if (filter != null && !matches(filter, r)) continue;
      var score = 0.0;
      for (final t in terms) {
        final tf = tokens[r.id]!.where((w) => w == t).length;
        if (tf > 0) score += tf * math.log(1 + rows.length / df[t]!);
      }
      if (score > 0) hits.add((score, r));
    }
    hits.sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : a.$2.id.compareTo(b.$2.id);
    });
    return {
      'results': [
        for (final (s, r) in hits.take(k))
          {'id': r.id, 'text': r.text, 'meta': r.meta, 'score': s},
      ],
    };
  }

  @override
  void flush(int waitMs) => _f;

  /// The Mongo subset the provider emits: $and, $or, $nor, and
  /// {$eq, $gte, $lte, $in} on a path.
  static bool matches(Map<String, Object?> q, FakeRow r) {
    for (final MapEntry(:key, :value) in q.entries) {
      switch (key) {
        case r'$and':
          if (!(value! as List).every((x) => matches((x as Map).cast(), r))) {
            return false;
          }
        case r'$or':
          if (!(value! as List).any((x) => matches((x as Map).cast(), r))) {
            return false;
          }
        case r'$nor':
          if ((value! as List).any((x) => matches((x as Map).cast(), r))) {
            return false;
          }
        default:
          final parts = key.split('.');
          Object? v = {'f': r.f, 'id': r.id, 'text': r.text};
          for (final p in parts) {
            v = v is Map ? v[p] : null;
          }
          if (v == null) return false;
          for (final MapEntry(key: opName, value: arg)
              in (value! as Map).entries) {
            final ok = switch (opName) {
              r'$eq' => _eq(v, arg),
              r'$gte' => v is num && v >= (arg as num),
              r'$lte' => v is num && v <= (arg as num),
              r'$in' => (arg as List).any((x) => _eq(v, x)),
              _ => throw StateError('operator $opName'),
            };
            if (!ok) return false;
          }
      }
    }
    return true;
  }

  static bool _eq(Object? a, Object? b) =>
      (a is num && b is num) ? a == b : a == b;
}
