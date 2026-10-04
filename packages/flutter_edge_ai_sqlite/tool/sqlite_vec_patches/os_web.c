// Drop-in replacement for sqlite3.dart's `sqlite3_wasm_build/src/os_web.c`.
//
// The only change vs upstream is auto-registering the statically-linked
// sqlite-vec extension so vec0 is available to every connection without a
// runtime load_extension call. sqlite-vec is compiled into the wasm with
// -DSQLITE_CORE (see build_vec0_wasm.sh + CMakeLists patch), which makes its
// init symbol `sqlite3_vec_init` a normal extern — we hand it to
// sqlite3_auto_extension at os-init time.
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bridge.h"
#include "sqlite3.h"

// sqlite-vec, statically compiled in (SQLITE_CORE). Auto-register so vec0 is
// available to every connection.
extern int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                            const sqlite3_api_routines *pApi);

int sqlite3_os_init(void) {
  sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
  return SQLITE_OK;
}

int sqlite3_os_end(void) { return SQLITE_OK; }

struct tm* localtime_r(const time_t* restrict timep,
                       struct tm* restrict result) {
  // This is not implemented by the WASI libc, but we can easily implement it
  // with a Dart hook.
  static_assert(sizeof(time_t) == sizeof(int64_t));
  if (dartLocalTime(*timep, result)) {
    return 0;
  } else {
    return result;
  }
}
