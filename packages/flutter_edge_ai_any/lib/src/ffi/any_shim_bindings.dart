// Raw dart:ffi bindings to libany_shim, one per function of
// native/any_shim/include/any_shim.h (the contract; read it for what each
// call does). Kept by hand: 35 functions of plain C types, held equal to the
// header by test/bindings_match_header_test.dart.
//
// The library is the Native Assets CodeAsset hook/build.dart registers
// under this file's asset id, so every @Native below resolves without a
// path, on every platform (on iOS and macOS, inside the framework Flutter
// wraps it in).
// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:flutter_edge_ai_any/src/ffi/any_shim_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef Status = Int32;
typedef OutStr = Pointer<Pointer<Utf8>>;

/// The `ANY_SHIM_ABI_VERSION` these bindings were written against.
const int anyShimAbiVersion = 1;

// ---------------------------------------------------------------- misc

@Native<Uint32 Function()>(isLeaf: true)
external int any_shim_abi_version();

@Native<Void Function(Pointer<Void>)>(isLeaf: true)
external void any_shim_free(Pointer<Void> ptr);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_version(OutStr outJson, OutStr outError);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_new_mnemonic(OutStr outMnemonic, OutStr outError);

@Native<Status Function(OutStr, OutStr)>()
external int any_shim_new_device_key(OutStr outHex, OutStr outError);

// ------------------------------------------------------------- account

@Native<Status Function(Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_account_open(
  Pointer<Utf8> optsJson,
  Pointer<Uint64> outAccount,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr)>()
external int any_shim_account_close(int account, OutStr outError);

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

@Native<Status Function(Uint64, Int32, OutStr, OutStr)>()
external int any_shim_space_list(
  int account,
  int sync,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_space_status(
  int account,
  Pointer<Utf8> spaceId,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, OutStr)>()
external int any_shim_space_sync_heads(
  int account,
  Pointer<Utf8> spaceId,
  OutStr outError,
);

// ------------------------------------------------------------- objects

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_object_put(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> docJson,
  OutStr outJson,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_object_get(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> objectId,
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

@Native<
  Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, Int32, OutStr, OutStr)
>()
external int any_shim_object_query(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> filterJson,
  int limit,
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
    Pointer<Int64>,
    OutStr,
  )
>()
external int any_shim_file_read(
  int account,
  Pointer<Utf8> spaceId,
  Pointer<Utf8> fileId,
  Pointer<Utf8> outPath,
  int timeoutMs,
  Pointer<Int64> outBytes,
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

// ------------------------------------------------------------ local index

@Native<Status Function(Pointer<Utf8>, Pointer<Uint64>, OutStr)>()
external int any_shim_index_open(
  Pointer<Utf8> optsJson,
  Pointer<Uint64> outIndex,
  OutStr outError,
);

@Native<Status Function(Uint64, OutStr)>()
external int any_shim_index_close(int index, OutStr outError);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Float>, Int32, OutStr)>()
external int any_shim_index_upsert(
  int index,
  Pointer<Utf8> docJson,
  Pointer<Float> vector,
  int dim,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Int32>, OutStr)>()
external int any_shim_index_delete(
  int index,
  Pointer<Utf8> id,
  Pointer<Int32> outFound,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Int64>, OutStr)>()
external int any_shim_index_count(
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

@Native<Status Function(Uint64, Pointer<Utf8>, OutStr, OutStr)>()
external int any_shim_index_state_get(
  int index,
  Pointer<Utf8> key,
  OutStr outValue,
  OutStr outError,
);

@Native<Status Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, OutStr)>()
external int any_shim_index_state_set(
  int index,
  Pointer<Utf8> key,
  Pointer<Utf8> value,
  OutStr outError,
);
