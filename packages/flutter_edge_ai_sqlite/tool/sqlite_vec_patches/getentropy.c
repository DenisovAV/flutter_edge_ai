// Drop-in replacement for sqlite3.dart's `sqlite3_wasm_build/src/getentropy.c`.
//
// vs upstream this adds ONE function: the WASI `random_get` import stub.
// sqlite-vec (via wasi-libc) pulls `random_get` in. Left undefined it becomes a
// real WASI import on the module, which our reactor-model, no-WASI wasm must not
// have (the Dart loader provides no WASI imports). We resolve it locally,
// backed by Dart's secure randomness — exactly how getentropy is already
// stubbed below — so the linker satisfies it and zero WASI imports remain.
#include <stdlib.h>

#include "bridge.h"

// sqlite3mc calls getentropy on initialization. That call pulls a bunch of WASI
// imports in when using the default WASI libc, which we're trying to avoid
// here. Instead, we use a local implementation backed by `Random.secure()` in
// Dart.
int getentropy(void* buf, size_t n) {
  return xRandomness(__builtin_wasm_ref_null_extern(), (int)n, (char*)buf);
}

// sqlite-vec (via wasi-libc) pulls the WASI `random_get` import in as
// `__imported_wasi_snapshot_preview1_random_get`. Define that exact symbol
// locally, backed by Dart's secure randomness, so the linker resolves it and
// no WASI import remains (matching how getentropy is stubbed above).
int __imported_wasi_snapshot_preview1_random_get(int buf, int len) {
  xRandomness(__builtin_wasm_ref_null_extern(), len, (char*)(long)buf);
  return 0;  // __WASI_ERRNO_SUCCESS
}
