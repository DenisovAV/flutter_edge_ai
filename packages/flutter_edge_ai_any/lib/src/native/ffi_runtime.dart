// The FFI runtime behind the AnyNative seam: per account, an SDK isolate
// (every call that touches any-sync), an index isolate (every index_* call)
// and an events isolate (any_shim_events_poll). No native call runs on the
// caller's isolate except any_shim_account_cancel, which never blocks.
//
// Jobs are closures sent to the worker isolates (same isolate group), run
// there against the isolate's AnySdk / AnyIndexHost, and answered through a
// one-shot port. A worker runs jobs concurrently on its event loop: every
// native call returns within ~250 ms, and an op is awaited in slices that
// yield between them (awaitOp), so a 20 s syncNow does not queue another
// location's writes behind it.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io' show sleep;
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/any_shim.dart';
import '../ffi/any_shim_bindings.dart' as b;
import 'any_native.dart';

AnyNative createAnyNative() => const _FfiNative();

final class _FfiNative implements AnyNative {
  const _FfiNative();

  @override
  bool get supported => true;

  @override
  Future<String> newMnemonic() => Isolate.run(AnyShim.newMnemonic);

  @override
  Future<String> newDeviceKey() => Isolate.run(AnyShim.newDeviceKey);

  @override
  Future<AnyRuntime> start() async {
    final sdk = await _Worker.spawn('sdk');
    final _Worker index;
    try {
      index = await _Worker.spawn('index');
    } catch (_) {
      sdk.stop();
      rethrow;
    }
    sdk.send(_IndexPort(index.port));
    // The SDK isolate waits for index answers (toIndex); when the index
    // isolate goes, those waits fail instead of hanging.
    index.onExit = () => sdk.send(const _IndexGone());
    return _FfiRuntime(sdk, index);
  }
}

final class _FfiRuntime implements AnyRuntime {
  _FfiRuntime(this._sdk, this._index);

  final _Worker _sdk;
  final _Worker _index;
  final _events = <_EventsPoller>{};

  static final _accountFinalizer = NativeFinalizer(
    b.anyShimAccountReleaseAddress,
  );
  static final _indexFinalizer = NativeFinalizer(b.anyShimIndexReleaseAddress);

  @override
  Future<T> sdk<T>(SdkJob<T> job) => _sdk.run<T>(_sdkJob(job));

  @override
  Future<T> index<T>(IndexJob<T> job) => _index.run<T>(_indexJob(job));

  @override
  void cancelAccount(int handle) {
    try {
      AnyShimAccount.fromHandle(handle).cancel();
    } on AnyShimException {
      // Already closed: nothing in flight to cancel.
    }
  }

  @override
  Stream<Map<String, Object?>> events(int handle) {
    final poller = _EventsPoller(handle);
    _events.add(poller);
    poller.done.whenComplete(() => _events.remove(poller));
    return poller.stream;
  }

  /// The owner keeps its token alive; when the owner goes (or the isolate
  /// group does, at a hot restart) the token goes and the release runs.
  static final _tokens = Expando<_Token>('flutter_edge_ai_any handle');

  void _attach(NativeFinalizer f, Object owner, int handle) {
    final token = _Token();
    _tokens[owner] = token;
    f.attach(token, Pointer<Void>.fromAddress(handle), detach: token);
  }

  void _detach(NativeFinalizer f, Object owner) {
    final token = _tokens[owner];
    if (token == null) return;
    f.detach(token);
    _tokens[owner] = null;
  }

  @override
  void attachAccount(Object owner, int handle) =>
      _attach(_accountFinalizer, owner, handle);

  @override
  void detachAccount(Object owner) => _detach(_accountFinalizer, owner);

  @override
  void attachIndex(Object owner, int handle) =>
      _attach(_indexFinalizer, owner, handle);

  @override
  void detachIndex(Object owner) => _detach(_indexFinalizer, owner);

  @override
  Future<void> dispose() async {
    for (final p in [..._events]) {
      p.stop();
    }
    _sdk.stop();
    _index.stop();
  }
}

final class _Token implements Finalizable {}

// The closures sent to a worker are built here, at top level: a closure
// literal inside a method shares that method's context with every other
// closure there (a reply port, a Completer), and would drag them along.
FutureOr<Object?> Function(Object) _sdkJob<T>(SdkJob<T> job) =>
    (ctx) => job(ctx as AnySdk);

FutureOr<Object?> Function(Object) _indexJob<T>(IndexJob<T> job) =>
    (ctx) => runIndexJob(job, ctx as AnyIndexHost);

// ------------------------------------------------------------ the workers

final class _IndexPort {
  _IndexPort(this.port);
  final SendPort port;
}

final class _IndexGone {
  const _IndexGone();
}

final class _Job {
  _Job(this.run, this.reply);
  final FutureOr<Object?> Function(Object ctx) run;
  final SendPort reply;
}

final class _Worker {
  _Worker._(this.port, this._isolate, this._exit, this._errors);

  final SendPort port;
  final Isolate _isolate;
  final RawReceivePort _exit;
  final RawReceivePort _errors;
  final _pending = <Completer<Object?>, RawReceivePort>{};
  bool _stopped = false;
  void Function()? onExit;

  static Future<_Worker> spawn(String kind) async {
    final boot = ReceivePort();
    final exit = RawReceivePort();
    final errors = RawReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        [boot.sendPort, kind],
        debugName: 'flutter_edge_ai_any $kind',
        onExit: exit.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: false,
      );
    } catch (_) {
      boot.close();
      exit.close();
      errors.close();
      rethrow;
    }
    final port = await boot.first as SendPort;
    final worker = _Worker._(port, isolate, exit, errors);
    exit.handler = (_) {
      worker._failAll('the $kind isolate exited');
      worker.onExit?.call();
    };
    // An uncaught error in a job's async tail: the isolate lives on (errors
    // are not fatal), so it is logged and the other jobs carry on.
    errors.handler = (Object? e) => developer.log(
      'uncaught error in the $kind isolate: $e',
      name: 'flutter_edge_ai_any',
    );
    return worker;
  }

  void send(Object message) => port.send(message);

  Future<T> run<T>(FutureOr<Object?> Function(Object ctx) job) {
    if (_stopped) {
      return Future.error(StateError('flutter_edge_ai_any: runtime stopped'));
    }
    final done = Completer<Object?>();
    final reply = RawReceivePort();
    _pending[done] = reply;
    reply.handler = (Object? msg) {
      reply.close();
      _pending.remove(done);
      if (done.isCompleted) return;
      final m = msg! as List;
      if (m[0] == true) {
        done.complete(m[1]);
      } else {
        done.completeError(m[1]!, StackTrace.fromString(m[2]! as String));
      }
    };
    port.send(_Job(job, reply.sendPort));
    return done.future.then((v) => v as T);
  }

  void _failAll(String why) {
    for (final MapEntry(key: c, value: reply) in [..._pending.entries]) {
      reply.close();
      if (!c.isCompleted) c.completeError(StateError(why));
    }
    _pending.clear();
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    port.send(const _Stop());
    _failAll('flutter_edge_ai_any: runtime stopped');
    _exit.close();
    _errors.close();
    // The worker closes its port on _Stop and exits once its jobs end; a
    // job blocked in native code ends within its 250 ms slice.
    Future<void>.delayed(const Duration(seconds: 5), () {
      _isolate.kill(priority: Isolate.beforeNextEvent);
    });
  }
}

final class _Stop {
  const _Stop();
}

void _workerMain(List<Object?> args) {
  final boot = args[0]! as SendPort;
  final kind = args[1]! as String;
  final port = RawReceivePort();
  final Object ctx = kind == 'sdk' ? FfiSdk() : FfiIndexHost();
  port.handler = (Object? msg) {
    if (msg is _IndexPort) {
      (ctx as FfiSdk).indexPort = msg.port;
    } else if (msg is _IndexGone) {
      (ctx as FfiSdk).indexGone();
    } else if (msg is _Job) {
      _runJob(ctx, msg);
    } else if (msg is _Stop) {
      port.close();
    }
  };
  boot.send(port.sendPort);
}

Future<void> _runJob(Object ctx, _Job job) async {
  try {
    final r = await job.run(ctx);
    job.reply.send([true, r]);
  } catch (e, st) {
    sendError(job.reply, e, st);
  }
}

/// Sends [e] as is when it can cross isolates, else its text as a
/// [StateError].
void sendError(SendPort reply, Object e, StackTrace st) {
  try {
    reply.send([false, e, '$st']);
  } catch (_) {
    reply.send([false, StateError('$e'), '$st']);
  }
}

// ----------------------------------------------------- the SDK isolate side

/// The SDK isolate's [AnySdk]: the wrapper over the open account's handle.
final class FfiSdk implements AnySdk {
  AnyShimAccount? _account;
  SendPort? indexPort;

  AnyShimAccount get _a {
    final a = _account;
    if (a == null) {
      throw AnyShimException(
        'flutter_edge_ai_any',
        AnyShimStatus.closed.code,
        'the account is not open',
      );
    }
    return a;
  }

  @override
  int? get accountHandle => _account?.handle;

  @override
  int openAccountStart(Map<String, Object?> options) =>
      AnyShimAccount.openStart(options);

  @override
  int adoptAccount(Map<String, Object?> openResult) {
    final a = AnyShimAccount.fromOpenResult(openResult);
    _account = a;
    return a.handle;
  }

  @override
  int closeAccountStart({int waitLoadsMs = 0}) {
    final a = _a;
    _account = null;
    return a.closeStart(waitLoadsMs: waitLoadsMs);
  }

  @override
  Map<String, Object?> accountInfo() => _a.info();

  @override
  Map<String, Object?> spaceCreate(String name) => _a.spaceCreate(name);

  @override
  Map<String, Object?> spaceList() => _a.spaceList();

  @override
  int spaceListSyncStart(int timeoutMs) => _a.spaceListSyncStart(timeoutMs);

  @override
  int spaceResolveStart(String spaceId) => _a.spaceResolveStart(spaceId);

  @override
  Map<String, Object?> spaceStatus(String spaceId) => _a.spaceStatus(spaceId);

  @override
  int syncHeadsStart(String spaceId, int timeoutMs) =>
      _a.syncHeadsStart(spaceId, timeoutMs);

  @override
  Map<String, Object?> ragBundles(String spaceId, {required bool ensure}) =>
      _a.ragBundles(spaceId, ensure: ensure);

  @override
  Map<String, Object?> objectPatch(
    String spaceId,
    Map<String, Object?> target,
    List<Object?> ops,
  ) => _a.objectPatch(spaceId, target, ops);

  @override
  void objectSetBody(String spaceId, String objectId, String text) =>
      _a.objectSetBody(spaceId, objectId, text);

  @override
  Map<String, Object?> objectRead(
    String spaceId,
    Map<String, Object?> request,
  ) => _a.objectRead(spaceId, request);

  @override
  Map<String, Object?> objectDeriveId(String spaceId, String seed) =>
      _a.objectDeriveId(spaceId, seed);

  @override
  void objectDelete(String spaceId, String objectId) =>
      _a.objectDelete(spaceId, objectId);

  @override
  Map<String, Object?> objectSyncState(String spaceId, String objectId) =>
      _a.objectSyncState(spaceId, objectId);

  @override
  void recordsModify(
    String spaceId,
    String objectId,
    String collection,
    List<Object?> records,
  ) => _a.recordsModify(spaceId, objectId, collection, records);

  @override
  Map<String, Object?> recordsRead(
    String spaceId,
    String objectId,
    String collection, {
    String? after,
    int sinceApplySeq = 0,
    int limit = 0,
  }) => _a.recordsRead(
    spaceId,
    objectId,
    collection,
    after: after,
    sinceApplySeq: sinceApplySeq,
    limit: limit,
  );

  @override
  Map<String, Object?> changesSince(
    String spaceId,
    int since, {
    int limit = 0,
  }) => _a.changesSince(spaceId, since, limit: limit);

  @override
  int watchChanges(String spaceId) => _a.watchChanges(spaceId);

  @override
  int watchSyncStatus() => _a.watchSyncStatus();

  @override
  void unwatch(int watch) => _a.unwatch(watch);

  @override
  OpPoll opWait(int op, int waitMs) => AnyShim.opWait(op, waitMs);

  @override
  void opCancel(int op) => AnyShim.opCancel(op);

  final _toIndex = <Completer<Object?>, RawReceivePort>{};

  /// The index isolate exited: every wait for it fails, later ones too.
  void indexGone() {
    indexPort = null;
    for (final MapEntry(key: c, value: reply) in [..._toIndex.entries]) {
      reply.close();
      if (!c.isCompleted) {
        c.completeError(StateError('flutter_edge_ai_any: index isolate gone'));
      }
    }
    _toIndex.clear();
  }

  @override
  Future<T> toIndex<T>(IndexJob<T> job) {
    final port = indexPort;
    if (port == null) {
      return Future.error(StateError('flutter_edge_ai_any: no index isolate'));
    }
    final done = Completer<Object?>();
    final reply = RawReceivePort();
    _toIndex[done] = reply;
    reply.handler = (Object? msg) {
      reply.close();
      _toIndex.remove(done);
      if (done.isCompleted) return;
      final m = msg! as List;
      if (m[0] == true) {
        done.complete(m[1]);
      } else {
        done.completeError(m[1]!, StackTrace.fromString(m[2]! as String));
      }
    };
    port.send(_Job(_indexJob(job), reply.sendPort));
    return done.future.then((v) => v as T);
  }
}

// --------------------------------------------------- the index isolate side

final class FfiIndexHost implements AnyIndexHost {
  @override
  int open(Map<String, Object?> options) => AnyShimIndex.open(options).handle;

  @override
  OpPoll opWait(int op, int waitMs) => AnyShim.opWait(op, waitMs);

  @override
  void opCancel(int op) => AnyShim.opCancel(op);

  @override
  AnyIndexApi index(int handle) => FfiIndexApi(AnyShimIndex.fromHandle(handle));
}

final class FfiIndexApi implements AnyIndexApi {
  FfiIndexApi(this._x);
  final AnyShimIndex _x;

  @override
  int closeStart() => _x.closeStart();

  @override
  int bindStart(Map<String, Object?> config) => _x.bindStart(config);

  @override
  Map<String, Object?> gc(int budgetMs) => _x.gc(budgetMs);

  @override
  Map<String, Object?> info() => _x.info();

  @override
  Map<String, Object?> apply(Map<String, Object?> ops, Float32List vectors) =>
      _x.apply(ops, vectors);

  @override
  String? getState(String key, {bool shadow = false}) =>
      stateValue(_x.get(shadow ? 'shadowState' : 'state', key));

  @override
  Map<String, Object?>? getRow(String id, {bool shadow = false}) {
    final v = _x.get(shadow ? 'shadow' : 'docs', id);
    return v == null ? null : (v as Map).cast<String, Object?>();
  }

  @override
  ({List<(String, String)> entries, String? next}) scanState({
    String? prefix,
    String? after,
    int limit = 0,
    bool shadow = false,
  }) {
    final r = _x.scan(
      shadow ? 'shadowState' : 'state',
      prefix: prefix,
      after: after,
      limit: limit,
    );
    final entries = <(String, String)>[];
    for (final item in (r['items'] as List? ?? const [])) {
      final m = (item as Map).cast<String, Object?>();
      final key = (m['key'] ?? m['id'])! as String;
      final value = stateValue(m);
      if (value != null) entries.add((key, value));
    }
    return (entries: entries, next: r['next'] as String?);
  }

  @override
  ({List<Map<String, Object?>> rows, String? next}) scanRows({
    String? after,
    int limit = 0,
  }) {
    final r = _x.scan('docs', after: after, limit: limit);
    return (
      rows: [
        for (final item in (r['items'] as List? ?? const []))
          (item as Map).cast<String, Object?>(),
      ],
      next: r['next'] as String?,
    );
  }

  @override
  int count() => _x.count();

  @override
  int countVectors() => _x.countVectors();

  @override
  Map<String, Object?> knn(
    Float32List query,
    int k,
    Map<String, Object?>? filter,
  ) => _x.knn(query, k, filter: filter);

  @override
  Map<String, Object?> text(
    String query,
    int k,
    Map<String, Object?>? filter,
  ) => _x.text(query, k, filter: filter);

  @override
  void flush(int waitMs) => _x.flush(waitMs);
}

/// A state entry as index_get / index_scan return it. any_shim.h says
/// "a state value" without its JSON shape; accepted: a bare string, or an
/// object carrying it as `value`.
String? stateValue(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is Map) return v['value'] as String?;
  throw FormatException('unexpected state entry: $v');
}

// ------------------------------------------------------------ the events

final class _EventsPoller {
  _EventsPoller(this._handle) {
    _controller = StreamController<Map<String, Object?>>(
      onListen: _start,
      onCancel: stop,
    );
  }

  final int _handle;
  late final StreamController<Map<String, Object?>> _controller;
  final _done = Completer<void>();
  RawReceivePort? _port;
  Isolate? _isolate;

  Stream<Map<String, Object?>> get stream => _controller.stream;
  Future<void> get done => _done.future;

  Future<void> _start() async {
    final port = RawReceivePort();
    _port = port;
    port.handler = (Object? msg) {
      if (msg == null) {
        stop();
        return;
      }
      if (msg is String) {
        _controller.addError(StateError(msg));
        stop();
        return;
      }
      for (final e in (msg as List)) {
        _controller.add((e as Map).cast<String, Object?>());
      }
    };
    _isolate = await Isolate.spawn(
      _eventsMain,
      [port.sendPort, _handle],
      debugName: 'flutter_edge_ai_any events',
      onExit: port.sendPort,
    );
  }

  void stop() {
    if (_done.isCompleted) return;
    _port?.close();
    _isolate?.kill(priority: Isolate.immediate);
    if (!_controller.isClosed) _controller.close();
    _done.complete();
  }
}

void _eventsMain(List<Object?> args) {
  final out = args[0]! as SendPort;
  final account = AnyShimAccount.fromHandle(args[1]! as int);
  var failures = 0;
  while (true) {
    try {
      final events = account.pollEvents(maxEvents: 256, timeoutMs: 250);
      failures = 0;
      if (events.isNotEmpty) out.send(events);
    } on AnyShimException catch (e) {
      if (e.status == AnyShimStatus.closed) {
        out.send(null);
        return;
      }
      // Never a hot loop: wait a slice; after many in a row, give up and
      // say why (the account restarts the poller).
      if (++failures >= _maxPollFailures) {
        out.send('events_poll failed $failures times: ${e.message}');
        return;
      }
      sleep(const Duration(milliseconds: 250));
    }
  }
}

const _maxPollFailures = 20;
