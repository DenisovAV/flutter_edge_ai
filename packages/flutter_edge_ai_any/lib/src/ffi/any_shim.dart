// A thin, internal Dart wrapper over the raw bindings: it owns the C memory
// of each call (arguments in an Arena, returned strings freed with
// any_shim_free), decodes the JSON results and turns a status into an
// AnyShimException. No policy lives here: what a call does is any_shim.h's.
//
// Every call blocks the calling isolate until the native call returns,
// which for network-bound ones (fileRead, spaceList(sync: true), syncHeads)
// can be seconds; run them off the UI isolate. Handles are plain ints, so
// an AnyShimAccount or AnyShimIndex can be rebuilt on another isolate with
// [AnyShimAccount.fromHandle] / [AnyShimIndex.fromHandle].
//
// Not exported: the public API is a separate decision.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'any_shim_bindings.dart' as b;

/// The status codes of any_shim.h, by value.
enum AnyShimStatus {
  ok(0),
  invalidArgument(1),
  notFound(2),
  deleted(3),
  closed(4),
  timeout(5),
  refused(6),
  internal(7),
  panic(8);

  const AnyShimStatus(this.code);
  final int code;

  /// A code this enum does not know (a newer library) maps to [internal]
  /// for branching; the raw value stays on [AnyShimException.code].
  static AnyShimStatus of(int code) => values.firstWhere(
    (s) => s.code == code,
    orElse: () => AnyShimStatus.internal,
  );
}

/// A call that returned a status other than ANY_SHIM_OK.
class AnyShimException implements Exception {
  AnyShimException(this.operation, this.code, this.message);

  /// The C function that failed, e.g. `any_shim_object_get`.
  final String operation;

  /// The raw status code.
  final int code;

  /// The library's message; for people, not for branching.
  final String message;

  AnyShimStatus get status => AnyShimStatus.of(code);

  @override
  String toString() =>
      'AnyShimException($operation: ${status.name} [$code]): $message';
}

/// The library does not implement the ABI these bindings were written for.
class AnyShimAbiException implements Exception {
  AnyShimAbiException(this.found);
  final int found;

  @override
  String toString() =>
      'AnyShimAbiException: libany_shim implements ABI $found, these '
      'bindings need ${b.anyShimAbiVersion}';
}

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

/// A call with one string out-parameter, decoded as JSON.
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

int _check(String op, int Function(Arena arena, b.OutStr err) call) =>
    _call(op, call, (_) => 0);

Pointer<Utf8> _s(Arena arena, String? s) {
  if (s == null) return nullptr;
  // C reads up to the first NUL: 'a\u0000b' would arrive as 'a'.
  if (s.contains('\u0000')) {
    throw ArgumentError.value(s, 'string', 'contains a NUL character');
  }
  return s.toNativeUtf8(allocator: arena);
}

const _int32Max = 0x7fffffff;

/// An int32 argument, refused instead of wrapping in the C call.
int _i32(int v, String name) {
  if (v < 0 || v > _int32Max) {
    throw RangeError.range(v, 0, _int32Max, name);
  }
  return v;
}

/// A timeout in whole milliseconds, rounded up so that a short positive
/// one never becomes 0 ("no deadline" / "return at once").
int _ms(Duration d, String name) {
  if (d.isNegative) throw ArgumentError.value(d, name, 'is negative');
  final ms = (d.inMicroseconds + 999) ~/ 1000;
  return _i32(ms, name);
}

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();
List<Map<String, Object?>> _list(Object? v) =>
    (v as List).map(_map).toList(growable: false);

Pointer<Float> _floats(Arena arena, Float32List v) {
  final p = arena<Float>(v.isEmpty ? 1 : v.length);
  p.asTypedList(v.length).setAll(0, v);
  return p;
}

var _abiChecked = false;

/// Checks the ABI once per isolate before the first account or index.
void _ensureAbi() {
  if (_abiChecked) return;
  AnyShim.checkAbi();
  _abiChecked = true;
}

/// A change-feed cursor: an applySeq, never negative (a negative int
/// would reach C as a huge uint64).
int _cursor(int since) {
  if (since < 0) throw RangeError.range(since, 0, null, 'since');
  return since;
}

/// A file-read deadline: positive (0 would mean "no deadline").
int _readTimeout(Duration d) {
  if (d <= Duration.zero) {
    throw ArgumentError.value(d, 'timeout', 'must be positive; null = none');
  }
  return _ms(d, 'timeout');
}

/// Process-wide calls.
abstract final class AnyShim {
  /// Throws [AnyShimAbiException] unless the loaded library implements the
  /// ABI these bindings were written for. Call it once before anything
  /// else; a mismatched library would otherwise misread arguments.
  static void checkAbi() {
    final found = b.any_shim_abi_version();
    if (found != b.anyShimAbiVersion) throw AnyShimAbiException(found);
  }

  /// `{abi, shim, go, modules: {path: version}}`.
  static Map<String, Object?> version() => _map(
    _json('any_shim_version', (_, out, err) => b.any_shim_version(out, err)),
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
}

/// An open any-sync account (one SDK instance).
final class AnyShimAccount {
  AnyShimAccount._(this.handle);

  /// Rebuilds the wrapper for a handle opened on another isolate.
  AnyShimAccount.fromHandle(this.handle);

  /// The native handle; valid until [close].
  final int handle;

  /// Opens an account; [options] as any_shim_account_open documents.
  static AnyShimAccount open(Map<String, Object?> options) {
    _ensureAbi();
    late Pointer<Uint64> out;
    return _call('any_shim_account_open', (arena, err) {
      out = arena<Uint64>();
      return b.any_shim_account_open(_s(arena, jsonEncode(options)), out, err);
    }, (_) => AnyShimAccount._(out.value));
  }

  void close() => _check(
    'any_shim_account_close',
    (_, err) => b.any_shim_account_close(handle, err),
  );

  Map<String, Object?> info() => _map(
    _json(
      'any_shim_account_info',
      (_, out, err) => b.any_shim_account_info(handle, out, err),
    ),
  );

  void setLocalDiscovery(bool enabled) => _check(
    'any_shim_set_local_discovery',
    (_, err) => b.any_shim_set_local_discovery(handle, enabled ? 1 : 0, err),
  );

  /// Returns the new space's id.
  String createSpace(String name) =>
      _map(
            _json(
              'any_shim_space_create',
              (arena, out, err) =>
                  b.any_shim_space_create(handle, _s(arena, name), out, err),
            ),
          )['id']!
          as String;

  /// `{spaces: [{id, name, status}], syncError}`; with [sync], syncError
  /// is the failed sync's message (the local list is still returned).
  Map<String, Object?> listSpaces({bool sync = false}) => _map(
    _json(
      'any_shim_space_list',
      (_, out, err) => b.any_shim_space_list(handle, sync ? 1 : 0, out, err),
    ),
  );

  Map<String, Object?> spaceStatus(String spaceId) => _map(
    _json(
      'any_shim_space_status',
      (arena, out, err) =>
          b.any_shim_space_status(handle, _s(arena, spaceId), out, err),
    ),
  );

  void syncHeads(String spaceId) => _check(
    'any_shim_space_sync_heads',
    (arena, err) =>
        b.any_shim_space_sync_heads(handle, _s(arena, spaceId), err),
  );

  /// Writes a document; [doc] as any_shim_object_put documents. Returns
  /// `{id, created}`.
  Map<String, Object?> putObject(String spaceId, Map<String, Object?> doc) =>
      _map(
        _json(
          'any_shim_object_put',
          (arena, out, err) => b.any_shim_object_put(
            handle,
            _s(arena, spaceId),
            _s(arena, jsonEncode(doc)),
            out,
            err,
          ),
        ),
      );

  Map<String, Object?> getObject(String spaceId, String objectId) => _map(
    _json(
      'any_shim_object_get',
      (arena, out, err) => b.any_shim_object_get(
        handle,
        _s(arena, spaceId),
        _s(arena, objectId),
        out,
        err,
      ),
    ),
  );

  void deleteObject(String spaceId, String objectId) => _check(
    'any_shim_object_delete',
    (arena, err) => b.any_shim_object_delete(
      handle,
      _s(arena, spaceId),
      _s(arena, objectId),
      err,
    ),
  );

  List<Map<String, Object?>> queryObjects(
    String spaceId, {
    Map<String, Object?>? filter,
    int limit = 0,
  }) => _list(
    _json(
      'any_shim_object_query',
      (arena, out, err) => b.any_shim_object_query(
        handle,
        _s(arena, spaceId),
        _s(arena, filter == null ? null : jsonEncode(filter)),
        _i32(limit, 'limit'),
        out,
        err,
      ),
    ),
  );

  Map<String, Object?> attachFile(
    String spaceId,
    String objectId,
    String path, {
    String? name,
  }) => _map(
    _json(
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
    ),
  );

  List<Map<String, Object?>> listFiles(String spaceId, {String? objectId}) =>
      _list(
        _json(
          'any_shim_file_list',
          (arena, out, err) => b.any_shim_file_list(
            handle,
            _s(arena, spaceId),
            _s(arena, objectId),
            out,
            err,
          ),
        ),
      );

  Map<String, Object?> fileStatus(String spaceId, String fileId) => _map(
    _json(
      'any_shim_file_status',
      (arena, out, err) => b.any_shim_file_status(
        handle,
        _s(arena, spaceId),
        _s(arena, fileId),
        out,
        err,
      ),
    ),
  );

  /// Copies the file to [outPath]; returns its size. [timeout] null = no
  /// deadline.
  int readFile(
    String spaceId,
    String fileId,
    String outPath, {
    Duration? timeout,
  }) {
    late Pointer<Int64> n;
    return _call('any_shim_file_read', (arena, err) {
      n = arena<Int64>();
      return b.any_shim_file_read(
        handle,
        _s(arena, spaceId),
        _s(arena, fileId),
        _s(arena, outPath),
        timeout == null ? 0 : _readTimeout(timeout),
        n,
        err,
      );
    }, (_) => n.value);
  }

  /// `{generation, maxApplySeq, changes: [{objectId, applySeq, deleted}]}`.
  Map<String, Object?> changesSince(
    String spaceId,
    int since, {
    int limit = 0,
  }) => _map(
    _json(
      'any_shim_changes_since',
      (arena, out, err) => b.any_shim_changes_since(
        handle,
        _s(arena, spaceId),
        _cursor(since),
        _i32(limit, 'limit'),
        out,
        err,
      ),
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

  /// Blocks up to [timeout] for events; throws [AnyShimException] with
  /// [AnyShimStatus.closed] once the account is closed. Meant for one
  /// dedicated poller isolate.
  List<Map<String, Object?>> pollEvents({
    int maxEvents = 0,
    Duration timeout = Duration.zero,
  }) => _list(
    _json(
      'any_shim_events_poll',
      (_, out, err) => b.any_shim_events_poll(
        handle,
        _i32(maxEvents, 'maxEvents'),
        _ms(timeout, 'timeout'),
        out,
        err,
      ),
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
    _ensureAbi();
    late Pointer<Uint64> out;
    return _call('any_shim_index_open', (arena, err) {
      out = arena<Uint64>();
      return b.any_shim_index_open(_s(arena, jsonEncode(options)), out, err);
    }, (_) => AnyShimIndex._(out.value));
  }

  void close() => _check(
    'any_shim_index_close',
    (_, err) => b.any_shim_index_close(handle, err),
  );

  /// [doc] needs a string `id`; [vector] the index's dimension.
  void upsert(Map<String, Object?> doc, Float32List vector) => _check(
    'any_shim_index_upsert',
    (arena, err) => b.any_shim_index_upsert(
      handle,
      _s(arena, jsonEncode(doc)),
      _floats(arena, vector),
      vector.length,
      err,
    ),
  );

  /// Whether the id was there.
  bool delete(String id) {
    late Pointer<Int32> found;
    return _call('any_shim_index_delete', (arena, err) {
      found = arena<Int32>();
      return b.any_shim_index_delete(handle, _s(arena, id), found, err);
    }, (_) => found.value != 0);
  }

  int count() {
    late Pointer<Int64> n;
    return _call('any_shim_index_count', (arena, err) {
      n = arena<Int64>();
      return b.any_shim_index_count(handle, n, err);
    }, (_) => n.value);
  }

  /// `{results: [{id, name, text, meta, distance}], ef, attempts}`.
  Map<String, Object?> knn(
    Float32List query,
    int k, {
    Map<String, Object?>? filter,
  }) => _map(
    _json(
      'any_shim_index_knn',
      (arena, out, err) => b.any_shim_index_knn(
        handle,
        _floats(arena, query),
        query.length,
        _i32(k, 'k'),
        _s(arena, filter == null ? null : jsonEncode(filter)),
        out,
        err,
      ),
    ),
  );

  /// `{results: [{id, name, text, meta, score}]}`.
  Map<String, Object?> text(
    String query,
    int k, {
    Map<String, Object?>? filter,
  }) => _map(
    _json(
      'any_shim_index_text',
      (arena, out, err) => b.any_shim_index_text(
        handle,
        _s(arena, query),
        _i32(k, 'k'),
        _s(arena, filter == null ? null : jsonEncode(filter)),
        out,
        err,
      ),
    ),
  );

  /// Null when [key] is not set.
  String? getState(String key) {
    late Pointer<Pointer<Utf8>> out;
    return _call('any_shim_index_state_get', (arena, err) {
      out = arena<Pointer<Utf8>>()..value = nullptr;
      return b.any_shim_index_state_get(handle, _s(arena, key), out, err);
    }, (_) => _take(out.value));
  }

  void setState(String key, String value) => _check(
    'any_shim_index_state_set',
    (arena, err) => b.any_shim_index_state_set(
      handle,
      _s(arena, key),
      _s(arena, value),
      err,
    ),
  );
}
