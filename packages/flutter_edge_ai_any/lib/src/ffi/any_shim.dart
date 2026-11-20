// A thin, internal Dart wrapper over the raw bindings: it owns the C memory
// of each call (arguments in an Arena, returned strings freed with
// any_shim_free), decodes the JSON results and turns a status into an
// AnyShimException. No policy lives here: what a call does is any_shim.h's.
//
// Every call blocks the calling isolate until the native call returns. ABI 2
// keeps that short: a call that may wait on the network or on a close is
// split into *_start, which returns an op handle, and opWait, which waits
// at most 250 ms per call. Handles are plain ints, so an AnyShimAccount or
// AnyShimIndex can be rebuilt on another isolate with fromHandle.
//
// Every call checks the ABI once per isolate before its first binding call
// (@Native binds lazily, per isolate): a mismatched library would otherwise
// misread arguments.
//
// Not exported: the provider uses it through the AnyNative seam.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../native/any_status.dart';
import 'any_shim_bindings.dart' as b;

export '../native/any_status.dart';

String? _take(Pointer<Utf8> p) {
  if (p == nullptr) return null;
  try {
    // allowMalformed: a Go error can carry raw bytes of a path, and a
    // FormatException here would hide the AnyShimException it belongs to.
    return utf8.decode(
      p.cast<Uint8>().asTypedList(p.length),
      allowMalformed: true,
    );
  } finally {
    b.any_shim_free(p.cast());
  }
}

/// Runs one native call with an Arena and an error out-parameter, and
/// throws when it fails. [call] gets the arena and the error slot.
T _call<T>(
  String op,
  int Function(Arena arena, b.OutStr err) call,
  T Function(Arena arena) result,
) {
  AnyShim.ensureAbi();
  return using((arena) {
    final err = arena<Pointer<Utf8>>()..value = nullptr;
    final status = call(arena, err);
    if (status != AnyShimStatus.ok.code) {
      throw AnyShimException(op, status, _take(err.value) ?? '(no message)');
    }
    // A misbehaving library could set a message on success; never leak it.
    _take(err.value);
    return result(arena);
  });
}

/// A call with one string out-parameter, decoded as JSON (null when the
/// library wrote none, which index_get does for an absent row).
Object? _json(
  String op,
  int Function(Arena arena, b.OutStr out, b.OutStr err) call,
) {
  late Pointer<Pointer<Utf8>> out;
  return _call(
    op,
    (arena, err) {
      out = arena<Pointer<Utf8>>()..value = nullptr;
      return call(arena, out, err);
    },
    (_) {
      final s = _take(out.value);
      return s == null ? null : jsonDecode(s);
    },
  );
}

Map<String, Object?> _jsonMap(
  String op,
  int Function(Arena arena, b.OutStr out, b.OutStr err) call,
) => _map(_json(op, call));

int _check(String op, int Function(Arena arena, b.OutStr err) call) =>
    _call(op, call, (_) => 0);

/// A call that starts an op and returns its handle.
int _start(
  String op,
  int Function(Arena arena, Pointer<Uint64> out, b.OutStr err) call,
) {
  late Pointer<Uint64> out;
  return _call(op, (arena, err) {
    out = arena<Uint64>();
    return call(arena, out, err);
  }, (_) => out.value);
}

Pointer<Utf8> _s(Arena arena, String? s) {
  if (s == null) return nullptr;
  // C reads up to the first NUL: 'a\u0000b' would arrive as 'a'.
  if (s.contains('\u0000')) {
    throw ArgumentError.value(s, 'string', 'contains a NUL character');
  }
  return s.toNativeUtf8(allocator: arena);
}

/// JSON text for C. jsonEncode escapes a NUL inside a string as \u0000,
/// so JSON never carries a raw one and [_s] cannot refuse it.
Pointer<Utf8> _j(Arena arena, Object? v) => _s(arena, jsonEncode(v));

const _int32Max = 0x7fffffff;

/// An int32 argument, refused instead of wrapping in the C call.
int _i32(int v, String name) {
  if (v < 0 || v > _int32Max) {
    throw RangeError.range(v, 0, _int32Max, name);
  }
  return v;
}

/// A uint64 argument (a cursor, an applySeq): never negative, which would
/// reach C as a huge value.
int _u64(int v, String name) {
  if (v < 0) throw RangeError.range(v, 0, null, name);
  return v;
}

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();

Pointer<Float> _floats(Arena arena, Float32List v) {
  final p = arena<Float>(v.isEmpty ? 1 : v.length);
  p.asTypedList(v.length).setAll(0, v);
  return p;
}

/// Process-wide calls.
abstract final class AnyShim {
  static bool _abiChecked = false;

  /// Throws [AnyShimAbiException] unless the loaded library implements the
  /// ABI these bindings were written for.
  static void checkAbi() {
    final found = b.any_shim_abi_version();
    if (found != b.anyShimAbiVersion) {
      throw AnyShimAbiException(found, b.anyShimAbiVersion);
    }
  }

  /// [checkAbi] once per isolate. Every wrapper call runs it first, so an
  /// isolate entry point that only goes through this wrapper is covered.
  static void ensureAbi() {
    if (_abiChecked) return;
    checkAbi();
    _abiChecked = true;
  }

  /// `{abi, shim, go, modules: {path: version}}`.
  static Map<String, Object?> version() => _jsonMap(
    'any_shim_version',
    (_, out, err) => b.any_shim_version(out, err),
  );

  static String newMnemonic() => _string(
    'any_shim_new_mnemonic',
    (_, out, err) => b.any_shim_new_mnemonic(out, err),
  );

  static String newDeviceKey() => _string(
    'any_shim_new_device_key',
    (_, out, err) => b.any_shim_new_device_key(out, err),
  );

  static String _string(
    String op,
    int Function(Arena arena, b.OutStr out, b.OutStr err) call,
  ) {
    late Pointer<Pointer<Utf8>> out;
    return _call(op, (arena, err) {
      out = arena<Pointer<Utf8>>()..value = nullptr;
      return call(arena, out, err);
    }, (_) => _take(out.value)!);
  }

  /// One wait slice of [op], at most [waitMs] (clamped natively to
  /// 0..250). Pending is a result here, not an error; the op's own failure
  /// is thrown as its status.
  static OpPoll opWait(int op, int waitMs) {
    AnyShim.ensureAbi();
    return using((arena) {
      final out = arena<Pointer<Utf8>>()..value = nullptr;
      final err = arena<Pointer<Utf8>>()..value = nullptr;
      final status = b.any_shim_op_wait(
        _u64(op, 'op'),
        _i32(waitMs, 'waitMs'),
        out,
        err,
      );
      if (status == AnyShimStatus.pending.code) {
        _take(err.value);
        _take(out.value);
        return const OpPoll.pending();
      }
      if (status != AnyShimStatus.ok.code) {
        _take(out.value);
        throw AnyShimException(
          'any_shim_op_wait',
          status,
          _take(err.value) ?? '(no message)',
        );
      }
      _take(err.value);
      final s = _take(out.value);
      return OpPoll.done(s == null ? const {} : _map(jsonDecode(s)));
    });
  }

  static void opCancel(int op) =>
      _check('any_shim_op_cancel', (_, err) => b.any_shim_op_cancel(op, err));

  /// Finalizer-shaped release; never throws, never blocks.
  static void accountRelease(int handle) {
    ensureAbi();
    b.any_shim_account_release(handle);
  }

  static void indexRelease(int handle) {
    ensureAbi();
    b.any_shim_index_release(handle);
  }
}

/// An open any-sync account (one SDK instance).
final class AnyShimAccount {
  AnyShimAccount._(this.handle);

  /// Rebuilds the wrapper for a handle opened on another isolate.
  AnyShimAccount.fromHandle(this.handle);

  /// The native handle; valid until the close starts.
  final int handle;

  /// Opens an account; [options] as any_shim_account_open documents.
  static AnyShimAccount open(Map<String, Object?> options) {
    late Pointer<Uint64> out;
    return _call('any_shim_account_open', (arena, err) {
      out = arena<Uint64>();
      return b.any_shim_account_open(_j(arena, options), out, err);
    }, (_) => AnyShimAccount._(out.value));
  }

  void cancel() => _check(
    'any_shim_account_cancel',
    (_, err) => b.any_shim_account_cancel(handle, err),
  );

  /// Starts the close; the handle is invalid at once. Returns the op.
  int closeStart() => _start(
    'any_shim_account_close_start',
    (_, out, err) => b.any_shim_account_close_start(handle, out, err),
  );

  Map<String, Object?> info() => _jsonMap(
    'any_shim_account_info',
    (_, out, err) => b.any_shim_account_info(handle, out, err),
  );

  void setLocalDiscovery(bool enabled) => _check(
    'any_shim_set_local_discovery',
    (_, err) => b.any_shim_set_local_discovery(handle, enabled ? 1 : 0, err),
  );

  /// `{id}`.
  Map<String, Object?> spaceCreate(String name) => _jsonMap(
    'any_shim_space_create',
    (arena, out, err) =>
        b.any_shim_space_create(handle, _s(arena, name), out, err),
  );

  /// `{spaces: [{id, name, status}]}`, local only.
  Map<String, Object?> spaceList() => _jsonMap(
    'any_shim_space_list',
    (_, out, err) => b.any_shim_space_list(handle, out, err),
  );

  int spaceListSyncStart(int timeoutMs) => _start(
    'any_shim_space_list_sync_start',
    (_, out, err) => b.any_shim_space_list_sync_start(
      handle,
      _i32(timeoutMs, 'timeoutMs'),
      out,
      err,
    ),
  );

  int spaceResolveStart(String spaceId) => _start(
    'any_shim_space_resolve_start',
    (arena, out, err) =>
        b.any_shim_space_resolve_start(handle, _s(arena, spaceId), out, err),
  );

  Map<String, Object?> spaceStatus(String spaceId) => _jsonMap(
    'any_shim_space_status',
    (arena, out, err) =>
        b.any_shim_space_status(handle, _s(arena, spaceId), out, err),
  );

  int syncHeadsStart(String spaceId, int timeoutMs) => _start(
    'any_shim_space_sync_heads_start',
    (arena, out, err) => b.any_shim_space_sync_heads_start(
      handle,
      _s(arena, spaceId),
      _i32(timeoutMs, 'timeoutMs'),
      out,
      err,
    ),
  );

  Map<String, Object?> ragBundles(String spaceId, {required bool ensure}) =>
      _jsonMap(
        'any_shim_rag_bundles',
        (arena, out, err) => b.any_shim_rag_bundles(
          handle,
          _s(arena, spaceId),
          ensure ? 1 : 0,
          out,
          err,
        ),
      );

  /// `{id, created}`.
  Map<String, Object?> objectPatch(
    String spaceId,
    Map<String, Object?> target,
    List<Object?> ops,
  ) => _jsonMap(
    'any_shim_object_patch',
    (arena, out, err) => b.any_shim_object_patch(
      handle,
      _s(arena, spaceId),
      _j(arena, target),
      _j(arena, ops),
      out,
      err,
    ),
  );

  void objectSetBody(String spaceId, String objectId, String text) => _check(
    'any_shim_object_set_body',
    (arena, err) => b.any_shim_object_set_body(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      // The body is display only: a NUL would end it early in C, so it is
      // dropped rather than refused.
      _s(arena, text.replaceAll('\u0000', '')),
      err,
    ),
  );

  Map<String, Object?> objectRead(
    String spaceId,
    Map<String, Object?> request,
  ) => _jsonMap(
    'any_shim_object_read',
    (arena, out, err) => b.any_shim_object_read(
      handle,
      _s(arena, spaceId),
      _j(arena, request),
      out,
      err,
    ),
  );

  void objectDelete(String spaceId, String objectId) => _check(
    'any_shim_object_delete',
    (arena, err) => b.any_shim_object_delete(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      err,
    ),
  );

  /// `{state}`.
  Map<String, Object?> objectSyncState(String spaceId, String objectId) =>
      _jsonMap(
        'any_shim_object_sync_state',
        (arena, out, err) => b.any_shim_object_sync_state(
          handle,
          _s(arena, spaceId),
          _s(arena, objectId),
          out,
          err,
        ),
      );

  void recordsModify(
    String spaceId,
    String objectId,
    String collection,
    List<Object?> records,
  ) => _check(
    'any_shim_records_modify',
    (arena, err) => b.any_shim_records_modify(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      _s(arena, collection),
      _j(arena, records),
      err,
    ),
  );

  /// `{records: [{…, _applySeq}], next}`.
  Map<String, Object?> recordsRead(
    String spaceId,
    String objectId,
    String collection, {
    String? after,
    int sinceApplySeq = 0,
    int limit = 0,
  }) => _jsonMap(
    'any_shim_records_read',
    (arena, out, err) => b.any_shim_records_read(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      _s(arena, collection),
      _s(arena, after),
      _u64(sinceApplySeq, 'sinceApplySeq'),
      _i32(limit, 'limit'),
      out,
      err,
    ),
  );

  /// `{generation, maxApplySeq, changes: [{objectId, applySeq, deleted}]}`.
  Map<String, Object?> changesSince(
    String spaceId,
    int since, {
    int limit = 0,
  }) => _jsonMap(
    'any_shim_changes_since',
    (arena, out, err) => b.any_shim_changes_since(
      handle,
      _s(arena, spaceId),
      _u64(since, 'since'),
      _i32(limit, 'limit'),
      out,
      err,
    ),
  );

  int watchChanges(String spaceId) {
    late Pointer<Int64> w;
    return _call('any_shim_watch_changes', (arena, err) {
      w = arena<Int64>();
      return b.any_shim_watch_changes(handle, _s(arena, spaceId), w, err);
    }, (_) => w.value);
  }

  int watchSyncStatus() {
    late Pointer<Int64> w;
    return _call('any_shim_watch_sync_status', (arena, err) {
      w = arena<Int64>();
      return b.any_shim_watch_sync_status(handle, w, err);
    }, (_) => w.value);
  }

  void unwatch(int watch) => _check(
    'any_shim_unwatch',
    (_, err) => b.any_shim_unwatch(handle, watch, err),
  );

  /// Waits up to [timeoutMs] (clamped natively to 0..250) for events;
  /// throws [AnyShimException] with [AnyShimStatus.closed] once the account
  /// is closed.
  List<Map<String, Object?>> pollEvents({
    int maxEvents = 0,
    int timeoutMs = 0,
  }) {
    final v = _json(
      'any_shim_events_poll',
      (_, out, err) => b.any_shim_events_poll(
        handle,
        _i32(maxEvents, 'maxEvents'),
        _i32(timeoutMs, 'timeoutMs'),
        out,
        err,
      ),
    );
    // ABI 1 answered a bare array; tolerate both shapes.
    final list = v is Map ? v['events'] : v;
    return [for (final e in (list as List? ?? const [])) _map(e)];
  }

  Map<String, Object?> fileAttach(
    String spaceId,
    String objectId,
    String path, {
    String? name,
  }) => _jsonMap(
    'any_shim_file_attach',
    (arena, out, err) => b.any_shim_file_attach(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      _s(arena, path),
      _s(arena, name),
      out,
      err,
    ),
  );

  Object? fileList(String spaceId, {String? objectId}) => _json(
    'any_shim_file_list',
    (arena, out, err) => b.any_shim_file_list(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      out,
      err,
    ),
  );

  Map<String, Object?> fileStatus(String spaceId, String fileId) => _jsonMap(
    'any_shim_file_status',
    (arena, out, err) => b.any_shim_file_status(
      handle,
      _s(arena, spaceId),
      _s(arena, fileId),
      out,
      err,
    ),
  );

  /// Starts copying the file to [outPath]; the op's result is `{bytes}`.
  int fileReadStart(
    String spaceId,
    String fileId,
    String outPath, {
    required int timeoutMs,
  }) => _start(
    'any_shim_file_read_start',
    (arena, out, err) => b.any_shim_file_read_start(
      handle,
      _s(arena, spaceId),
      _s(arena, fileId),
      _s(arena, outPath),
      _i32(timeoutMs, 'timeoutMs'),
      out,
      err,
    ),
  );
}

/// An open local index (any-store; never synced).
final class AnyShimIndex {
  AnyShimIndex._(this.handle);

  /// Rebuilds the wrapper for a handle opened on another isolate.
  AnyShimIndex.fromHandle(this.handle);

  final int handle;

  /// Opens or creates an index; [options] as any_shim_index_open documents.
  static AnyShimIndex open(Map<String, Object?> options) {
    late Pointer<Uint64> out;
    return _call('any_shim_index_open', (arena, err) {
      out = arena<Uint64>();
      return b.any_shim_index_open(_j(arena, options), out, err);
    }, (_) => AnyShimIndex._(out.value));
  }

  void close() => _check(
    'any_shim_index_close',
    (_, err) => b.any_shim_index_close(handle, err),
  );

  Map<String, Object?> bind(Map<String, Object?> config) => _jsonMap(
    'any_shim_index_bind',
    (arena, out, err) =>
        b.any_shim_index_bind(handle, _j(arena, config), out, err),
  );

  Map<String, Object?> info() => _jsonMap(
    'any_shim_index_info',
    (_, out, err) => b.any_shim_index_info(handle, out, err),
  );

  /// One write transaction; [vectors] holds every vector slot the ops
  /// name, in order. `{applied}`.
  Map<String, Object?> apply(Map<String, Object?> ops, Float32List vectors) =>
      _jsonMap(
        'any_shim_index_apply',
        (arena, out, err) => b.any_shim_index_apply(
          handle,
          _j(arena, ops),
          _floats(arena, vectors),
          vectors.length,
          out,
          err,
        ),
      );

  /// A row or a state entry; null when absent.
  Object? get(String coll, String id) => _json(
    'any_shim_index_get',
    (arena, out, err) =>
        b.any_shim_index_get(handle, _s(arena, coll), _s(arena, id), out, err),
  );

  /// `{items: […], next}`.
  Map<String, Object?> scan(
    String coll, {
    String? prefix,
    String? after,
    int limit = 0,
  }) => _jsonMap(
    'any_shim_index_scan',
    (arena, out, err) => b.any_shim_index_scan(
      handle,
      _s(arena, coll),
      _s(arena, prefix),
      _s(arena, after),
      _i32(limit, 'limit'),
      out,
      err,
    ),
  );

  int count() {
    late Pointer<Int64> n;
    return _call('any_shim_index_count', (arena, err) {
      n = arena<Int64>();
      return b.any_shim_index_count(handle, n, err);
    }, (_) => n.value);
  }

  int countVectors() {
    late Pointer<Int64> n;
    return _call('any_shim_index_count_vectors', (arena, err) {
      n = arena<Int64>();
      return b.any_shim_index_count_vectors(handle, n, err);
    }, (_) => n.value);
  }

  /// `{results: [{id, text, meta, distance}]}`.
  Map<String, Object?> knn(
    Float32List query,
    int k, {
    Map<String, Object?>? filter,
  }) => _jsonMap(
    'any_shim_index_knn',
    (arena, out, err) => b.any_shim_index_knn(
      handle,
      _floats(arena, query),
      _i32(query.length, 'dim'),
      _i32(k, 'k'),
      filter == null ? nullptr : _j(arena, filter),
      out,
      err,
    ),
  );

  /// `{results: [{id, text, meta, score}]}`.
  Map<String, Object?> text(
    String query,
    int k, {
    Map<String, Object?>? filter,
  }) => _jsonMap(
    'any_shim_index_text',
    (arena, out, err) => b.any_shim_index_text(
      handle,
      _s(arena, query),
      _i32(k, 'k'),
      filter == null ? nullptr : _j(arena, filter),
      out,
      err,
    ),
  );

  void flush(int waitMs) => _check(
    'any_shim_index_flush',
    (_, err) => b.any_shim_index_flush(handle, _i32(waitMs, 'waitMs'), err),
  );
}
