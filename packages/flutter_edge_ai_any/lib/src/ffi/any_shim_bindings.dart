// Raw dart:ffi bindings to libany_shim, one per function of
// native/any_shim/include/any_shim.h (the contract; read it for what each
// call does). Kept by hand: plain C types only, held equal to the header by
// test/bindings_match_header_test.dart.
//
// The library is the Native Assets CodeAsset hook/build.dart registers
// under this file's asset id, so every @Native below resolves without a
// path, on every platform (on iOS and macOS, inside the framework Flutter
// wraps it in). @Native binds lazily, on the first call in each isolate,
// which is why every isolate entry point checks the ABI first
// (AnyShim.ensureAbi in any_shim.dart).
// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:flutter_edge_ai_any/src/ffi/any_shim_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef Status = Int32;
typedef OutStr = Pointer<Pointer<Utf8>>;

/// The `ANY_SHIM_ABI_VERSION` these bindings were written against.
const int anyShimAbiVersion = 2;

// ---------------------------------------------------------------- misc

@Native<Uint32 Function()>()
external int any_shim_abi_version();

@Native<Void Function(Pointer<Void>)>()
external void any_shim_free(Pointer<Void> ptr);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_version(OutStr outJson, OutStr outError);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_new_mnemonic(OutStr outMnemonic, OutStr outError);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_new_device_key(OutStr outHex, OutStr outError);

// ------------------------------------------------------------------ ops

@Native<Status Function(Uint64, Int32, OutStr, OutStr)>()
external int any_shim_op_wait(
  int op,
  int waitMs,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr)>()
external int any_shim_op_cancel(int op, OutStr outError);

// ------------------------------------------------------------- account

@Native<Status Function(Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_account_open_start(
  Pointer<Utf8> optsJson,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr)>()
external int any_shim_account_cancel(int account, OutStr outError);

@Native<Status Function(Uint64, Int32, Pointer<Uint64>, OutStr)>()
external int any_shim_account_close_start(
  int account,
  int waitLoadsMs,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Void Function(UintPtr)>()
external void any_shim_account_release(int account);

@Native<Status Function(Uint64, OutStr, OutStr)>()
external int any_shim_account_info(
  int account,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Int32, OutStr)>()
external int any_shim_set_local_discovery(
  int account,
  int enabled,
  OutStr outError,
);

// -------------------------------------------------------------- spaces

@Native<Status Function(Uint64, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_space_create(
  int account,
  Pointer<Utf8> name,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr, OutStr)>()
external int any_shim_space_list(int account, OutStr outJson, OutStr outError);

@Native<Status Function(Uint64, Int32, Pointer<Uint64>, OutStr)>()
external int any_shim_space_list_sync_start(
  int account,
  int timeoutMs,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_space_resolve_start(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_space_status(
  int account,
  Pointer<Utf8> spaceId,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(Uint64, Pointer<Utf8>, Int32, Pointer<Uint64>, OutStr)
>()
external int any_shim_space_sync_heads_start(
  int account,
  Pointer<Utf8> spaceId,
  int timeoutMs,
  Pointer<Uint64> outOp,
  OutStr outError,
);

// --------------------------------------------------------- rag bundles

@Native<Status Function(Uint64, Pointer<Utf8>, Int32, OutStr, OutStr)>()
external int any_shim_rag_bundles(
  int account,
  Pointer<Utf8> spaceId,
  int ensure,
  OutStr outJson,
  OutStr outError,
);

// ------------------------------------------------------------- objects

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    OutStr,
    OutStr,
  )
>()
external int any_shim_object_patch(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> targetJson,
  Pointer<Utf8> opsJson,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, OutStr)
>()
external int any_shim_object_set_body(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  Pointer<Utf8> text,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_object_read(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> requestJson,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_object_derive_id(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> seed,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr)>()
external int any_shim_object_delete(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_object_sync_state(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    OutStr,
  )
>()
external int any_shim_records_modify(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  Pointer<Utf8> collection,
  Pointer<Utf8> recordsJson,
  OutStr outError,
);

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Uint64,
    Int32,
    OutStr,
    OutStr,
  )
>()
external int any_shim_records_read(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  Pointer<Utf8> collection,
  Pointer<Utf8> after,
  int sinceApplySeq,
  int limit,
  OutStr outJson,
  OutStr outError,
);

// --------------------------------------------------- change feed, events

@Native<Status Function(Uint64, Pointer<Utf8>, Uint64, Int32, OutStr, OutStr)>()
external int any_shim_changes_since(
  int account,
  Pointer<Utf8> spaceId,
  int since,
  int limit,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Int64>, OutStr)>()
external int any_shim_watch_changes(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Int64> outWatch,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Int64>, OutStr)>()
external int any_shim_watch_sync_status(
  int account,
  Pointer<Int64> outWatch,
  OutStr outError,
);

@Native<Status Function(Uint64, Int64, OutStr)>()
external int any_shim_unwatch(int account, int watch, OutStr outError);

@Native<Status Function(Uint64, Int32, Int32, OutStr, OutStr)>()
external int any_shim_events_poll(
  int account,
  int maxEvents,
  int timeoutMs,
  OutStr outJson,
  OutStr outError,
);

// --------------------------------------------------------------- files

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    OutStr,
    OutStr,
  )
>()
external int any_shim_file_attach(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  Pointer<Utf8> path,
  Pointer<Utf8> name,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_file_list(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_file_status(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> fileId,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int32,
    Pointer<Uint64>,
    OutStr,
  )
>()
external int any_shim_file_read_start(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> fileId,
  Pointer<Utf8> outPath,
  int timeoutMs,
  Pointer<Uint64> outOp,
  OutStr outError,
);

// --------------------------------------------- local index (never synced)

@Native<Status Function(Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_index_open(
  Pointer<Utf8> optsJson,
  Pointer<Uint64> outIndex,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Uint64>, OutStr)>()
external int any_shim_index_close_start(
  int index,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Void Function(UintPtr)>()
external void any_shim_index_release(int index);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_index_bind_start(
  int index,
  Pointer<Utf8> bindJson,
  Pointer<Uint64> outOp,
  OutStr outError,
);

@Native<Status Function(Uint64, Int32, OutStr, OutStr)>()
external int any_shim_index_gc(
  int index,
  int budgetMs,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr, OutStr)>()
external int any_shim_index_info(int index, OutStr outJson, OutStr outError);

@Native<
  Status Function(Uint64, Pointer<Utf8>, Pointer<Float>, Int64, OutStr, OutStr)
>()
external int any_shim_index_apply(
  int index,
  Pointer<Utf8> opsJson,
  Pointer<Float> vectors,
  int vectorFloats,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_index_get(
  int index,
  Pointer<Utf8> coll,
  Pointer<Utf8> id,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int32,
    OutStr,
    OutStr,
  )
>()
external int any_shim_index_scan(
  int index,
  Pointer<Utf8> coll,
  Pointer<Utf8> prefix,
  Pointer<Utf8> after,
  int limit,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Int64>, OutStr)>()
external int any_shim_index_count(
  int index,
  Pointer<Int64> outCount,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Int64>, OutStr)>()
external int any_shim_index_count_vectors(
  int index,
  Pointer<Int64> outCount,
  OutStr outError,
);

@Native<
  Status Function(
    Uint64,
    Pointer<Float>,
    Int32,
    Int32,
    Pointer<Utf8>,
    OutStr,
    OutStr,
  )
>()
external int any_shim_index_knn(
  int index,
  Pointer<Float> query,
  int dim,
  int k,
  Pointer<Utf8> filterJson,
  OutStr outJson,
  OutStr outError,
);

@Native<
  Status Function(Uint64, Pointer<Utf8>, Int32, Pointer<Utf8>, OutStr, OutStr)
>()
external int any_shim_index_text(
  int index,
  Pointer<Utf8> query,
  int k,
  Pointer<Utf8> filterJson,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Int32, OutStr)>()
external int any_shim_index_flush(int index, int waitMs, OutStr outError);

// ------------------------------------------- finalizer-shaped addresses

/// `any_shim_account_release` as a `void(void*)` for a [NativeFinalizer]
/// (any_shim.h: "compatible with void(void*) on all seven targets").
final Pointer<NativeFunction<Void Function(Pointer<Void>)>>
anyShimAccountReleaseAddress =
    Native.addressOf<NativeFunction<Void Function(UintPtr)>>(
      any_shim_account_release,
    ).cast();

/// `any_shim_index_release` as a `void(void*)` for a [NativeFinalizer].
final Pointer<NativeFunction<Void Function(Pointer<Void>)>>
anyShimIndexReleaseAddress =
    Native.addressOf<NativeFunction<Void Function(UintPtr)>>(
      any_shim_index_release,
    ).cast();
