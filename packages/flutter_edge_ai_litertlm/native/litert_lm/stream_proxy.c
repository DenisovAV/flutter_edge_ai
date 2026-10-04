// _GNU_SOURCE must precede every include: on glibc, RTLD_DEFAULT (used by the
// ABI probe below) is a GNU extension that <dlfcn.h> only exposes under it.
// Apple's libc declares RTLD_DEFAULT unconditionally, so a macOS build compiles
// happily without this and Linux fails with "RTLD_DEFAULT undeclared".
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#endif

#ifdef _WIN32
#define STREAM_PROXY_EXPORT __declspec(dllexport)
#else
#define STREAM_PROXY_EXPORT __attribute__((visibility("default")))
#endif

// Callback type matching LiteRtLmStreamCallback up to and including v0.14.0.
// This is also the shape our Dart NativeCallable expects, in both ABI modes —
// adapting the newer upstream shape to it is exactly this file's job.
typedef void (*LiteRtLmStreamCallback)(void* callback_data, const char* chunk,
                                       _Bool is_final, const char* error_msg);

// ── v0.15.0 streaming ABI ────────────────────────────────────────────────
// LiteRT-LM v0.15.0 replaced the 4-arg stream callback with a 2-arg one that
// hands over an opaque chunk object read through accessors:
//
//   v0.13.1 / v0.14.0: void(void*, const char* chunk, bool final, const char* err)
//   v0.15.0:           void(void*, const LiteRtLmStreamChunk* chunk)
//
// Upstream kept no compatibility overload, and the C API carries no version
// symbol, so a build-time switch would pin us to one native release. Probe the
// loaded libLiteRtLm at runtime instead and hand LiteRT-LM whichever callback
// it actually calls — that keeps one binary working against both.
//
// Registering the wrong shape is not a graceful failure: args 3 and 4 come from
// whatever the registers happen to hold, and strdup() on that garbage pointer
// faults outright on Windows and yields malformed text on macOS.
typedef void (*StreamCallbackV15)(void* callback_data, const void* chunk);
typedef const char* (*ChunkGetTextFn)(const void* chunk);
typedef const char* (*ChunkGetErrorFn)(const void* chunk);
typedef _Bool (*ChunkIsFinalFn)(const void* chunk);

static ChunkGetTextFn stream_chunk_get_text = NULL;
static ChunkGetErrorFn stream_chunk_get_error = NULL;
static ChunkIsFinalFn stream_chunk_is_final = NULL;
static int stream_abi_probed = 0;

static void* stream_proxy_resolve(const char* name) {
#ifdef _WIN32
  // The bundle ships the lib under both names depending on platform packaging.
  static const char* modules[] = {"LiteRtLm.dll", "libLiteRtLm.dll", NULL};
  for (int i = 0; modules[i] != NULL; i++) {
    HMODULE mod = GetModuleHandleA(modules[i]);
    if (mod != NULL) {
      FARPROC sym = GetProcAddress(mod, name);
      if (sym != NULL) return (void*)sym;
    }
  }
  return NULL;
#else
  // Dart preloads libLiteRtLm with RTLD_GLOBAL (stream_proxy_load_global), so
  // its exports are reachable from the default search scope.
  return dlsym(RTLD_DEFAULT, name);
#endif
}

// Resolve the v0.15.0 chunk accessors once. Their presence *is* the version
// probe: they simply do not exist in v0.14.0 and earlier.
static void stream_proxy_probe_abi(void) {
  if (stream_abi_probed) return;
  stream_abi_probed = 1;
  stream_chunk_get_text =
      (ChunkGetTextFn)stream_proxy_resolve("litert_lm_stream_chunk_get_text");
  stream_chunk_get_error =
      (ChunkGetErrorFn)stream_proxy_resolve("litert_lm_stream_chunk_get_error");
  stream_chunk_is_final =
      (ChunkIsFinalFn)stream_proxy_resolve("litert_lm_stream_chunk_is_final");
}

// Proxy callback data: holds the Dart callback and memory to free
typedef struct {
  LiteRtLmStreamCallback dart_callback;
  void* dart_data;
} ProxyData;

// This is the C callback given to LiteRT-LM.
// It copies chunk/error strings to heap (strdup) so they survive
// until Dart's NativeCallable.listener processes them.
static void stream_proxy_callback(void* callback_data, const char* chunk,
                                  _Bool is_final, const char* error_msg) {
  ProxyData* proxy = (ProxyData*)callback_data;

  // Copy strings to heap — Dart callback will free them
  char* chunk_copy = chunk ? strdup(chunk) : NULL;
  char* error_copy = error_msg ? strdup(error_msg) : NULL;

  proxy->dart_callback(proxy->dart_data, chunk_copy, is_final, error_copy);

  // If final, free the proxy struct itself
  if (is_final) {
    free(proxy);
  }
}

// v0.15.0 callback: unpack the chunk object and forward in the 4-arg shape
// Dart already understands.
static void stream_proxy_callback_v15(void* callback_data, const void* chunk) {
  ProxyData* proxy = (ProxyData*)callback_data;

  const char* text =
      stream_chunk_get_text ? stream_chunk_get_text(chunk) : NULL;
  const char* error_msg =
      stream_chunk_get_error ? stream_chunk_get_error(chunk) : NULL;
  _Bool is_final = stream_chunk_is_final ? stream_chunk_is_final(chunk) : 0;

  char* chunk_copy = text ? strdup(text) : NULL;
  // v0.15.0 signals "no error" with an EMPTY string rather than NULL. Dart
  // treats any non-NULL error pointer as a failed stream, so forwarding "" here
  // would abort the stream on every ordinary token.
  char* error_copy = (error_msg && error_msg[0]) ? strdup(error_msg) : NULL;

  proxy->dart_callback(proxy->dart_data, chunk_copy, is_final, error_copy);

  if (is_final) {
    free(proxy);
  }
}

// Create a proxy that wraps a Dart callback.
// Returns: proxy callback function pointer (to pass to LiteRT-LM)
// Out: proxy_data (to pass as callback_data to LiteRT-LM)
STREAM_PROXY_EXPORT
void* stream_proxy_create(LiteRtLmStreamCallback dart_callback,
                          void* dart_data,
                          LiteRtLmStreamCallback* out_proxy_fn) {
  ProxyData* proxy = (ProxyData*)malloc(sizeof(ProxyData));
  proxy->dart_callback = dart_callback;
  proxy->dart_data = dart_data;

  stream_proxy_probe_abi();
  // The out-param is typed as the 4-arg callback because that is what the Dart
  // binding declares; LiteRT-LM only ever consumes the address, so handing back
  // the 2-arg entry point through the same slot is safe.
  *out_proxy_fn = stream_chunk_get_text
                      ? (LiteRtLmStreamCallback)(void*)stream_proxy_callback_v15
                      : stream_proxy_callback;
  return proxy;
}

// Free a chunk or error string that was strdup'd by the proxy.
STREAM_PROXY_EXPORT
void stream_proxy_free_string(char* str) {
  free(str);
}

// Redirect stderr (and stdout) to a file at `path`. Used to capture native
// glog/abseil output on iOS/Android where we can't see process stderr from
// the Flutter test runner. Pass NULL to skip stdout redirect.
// Returns 0 on success, errno on failure.
STREAM_PROXY_EXPORT
int stream_proxy_redirect_stderr(const char* path) {
#ifdef _WIN32
  FILE* f = NULL;
  if (freopen_s(&f, path, "w", stderr) != 0) return 1;
  freopen_s(&f, path, "a", stdout);
  setvbuf(stderr, NULL, _IOLBF, 0);
  setvbuf(stdout, NULL, _IOLBF, 0);
  return 0;
#else
  // Append mode so multi-session test runs accumulate log instead of
  // truncating on every _ensureBindings call (different LiteRtLmFfiClient
  // instances each redirect to the same path).
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) return 1;
  // Redirect both fd 1 (stdout) and fd 2 (stderr).
  dup2(fd, 1);
  dup2(fd, 2);
  close(fd);
  // Disable buffering so writes hit the file immediately.
  setvbuf(stderr, NULL, _IOLBF, 0);
  setvbuf(stdout, NULL, _IOLBF, 0);
  return 0;
#endif
}

// Load a shared library so its exports are visible to subsequent
// dlopen/LoadLibrary calls and to dlsym(RTLD_DEFAULT)-style lookups.
//
// POSIX: Dart's DynamicLibrary.open uses RTLD_LOCAL which hides symbols
// from other modules; we re-open with RTLD_GLOBAL so accelerator plugins
// can resolve LiteRt* symbols against the LiteRt C API at registration.
//
// Windows: there is no RTLD_GLOBAL. PE modules expose exports through
// the Loaded Modules list automatically, so the trick reduces to
// "load the DLL into the process before anyone else needs it" — which
// is what `LoadLibraryExA(LOAD_WITH_ALTERED_SEARCH_PATH)` does when
// given an absolute or bundle-relative path.
#ifdef _WIN32
#include <windows.h>
STREAM_PROXY_EXPORT
void* stream_proxy_load_global(const char* path) {
  // LOAD_WITH_ALTERED_SEARCH_PATH lets the loader resolve dependent DLLs
  // from the directory of `path` (i.e. the bundle dir) instead of just
  // the application directory — same effect as preloading on POSIX with
  // RTLD_GLOBAL: the module is now reachable by name for later loads.
  return (void*)LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
#else
#include <dlfcn.h>
STREAM_PROXY_EXPORT
void* stream_proxy_load_global(const char* path) {
  return dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
}
#endif
