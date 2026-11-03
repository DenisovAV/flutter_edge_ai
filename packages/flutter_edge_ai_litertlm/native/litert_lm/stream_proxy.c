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

// The callback shape our Dart NativeCallable expects. LiteRT-LM hands its
// callback an opaque chunk read through accessors; adapting that to this shape
// is this file's job.
typedef void (*LiteRtLmStreamCallback)(void* callback_data, const char* chunk,
                                       _Bool is_final, const char* error_msg);

// LiteRT-LM C API 1.0 (v0.19.0 on): the stream callback LiteRT-LM calls, and
// the chunk accessors. Each accessor returns a LiteRtLmStatusCode (0 = OK) and
// writes its value through an out-parameter.
typedef void (*LiteRtLmChunkCallback)(void* callback_data, const void* chunk);
typedef int (*ChunkGetTextFn)(const void* chunk, const char** out_text);
typedef int (*ChunkGetErrorFn)(const void* chunk, const char** out_error);
typedef int (*ChunkIsFinalFn)(const void* chunk, _Bool* out_is_final);

// ── stream_proxy_create_v1 ───────────────────────────────────────────────
// One proxy per stream. The caller (Dart) resolves the three accessors with
// `lookup` on the libLiteRtLm it drives and passes them in, so the shim keeps
// nothing process-global and cannot hold another library's symbols. The Dart
// client refuses a library whose C API is not 1.x before it gets here, so
// there is no other accessor shape to choose from.
//
// A chunk an accessor cannot read (a non-OK status) ends the stream for Dart:
// one final chunk with an error naming the accessor and the status. LiteRT-LM
// may still deliver chunks after it; they are dropped, and the proxy is freed
// at the chunk that reads as final. When it is is_final that failed, that end
// cannot be seen and the proxy (a few words) is not freed: freeing it there
// would hand LiteRT-LM's next callback freed memory.
typedef struct {
  LiteRtLmStreamCallback dart_callback;
  void* dart_data;
  ChunkGetTextFn get_text;
  ChunkGetErrorFn get_error;
  ChunkIsFinalFn is_final;
  int ended;  // Dart has had its final chunk
} ProxyDataV1;

static char* proxy_dup(const char* s) { return s ? strdup(s) : NULL; }

static void stream_proxy_fail(ProxyDataV1* proxy, const char* accessor,
                              int status) {
  char message[160];
  snprintf(message, sizeof message,
           "stream_proxy: %s failed with LiteRtLmStatusCode %d", accessor,
           status);
  proxy->ended = 1;
  proxy->dart_callback(proxy->dart_data, NULL, 1, proxy_dup(message));
}

static void stream_proxy_callback_v1(void* callback_data, const void* chunk) {
  ProxyDataV1* proxy = (ProxyDataV1*)callback_data;

  _Bool is_final = 0;
  int status = proxy->is_final(chunk, &is_final);
  if (status != 0) {
    if (!proxy->ended) stream_proxy_fail(proxy, "litert_lm_stream_chunk_is_final", status);
    return;  // the end of the stream cannot be seen: see above
  }
  if (proxy->ended) {
    if (is_final) free(proxy);
    return;
  }

  const char* text = NULL;
  status = proxy->get_text(chunk, &text);
  if (status != 0) {
    stream_proxy_fail(proxy, "litert_lm_stream_chunk_get_text", status);
    if (is_final) free(proxy);
    return;
  }
  const char* error_msg = NULL;
  status = proxy->get_error(chunk, &error_msg);
  if (status != 0) {
    stream_proxy_fail(proxy, "litert_lm_stream_chunk_get_error", status);
    if (is_final) free(proxy);
    return;
  }

  // "No error" is an EMPTY string, and Dart treats any non-NULL error pointer
  // as a failed stream.
  proxy->dart_callback(proxy->dart_data, proxy_dup(text), is_final,
                       (error_msg && error_msg[0]) ? strdup(error_msg) : NULL);
  if (is_final) free(proxy);
}

// Returns the proxy to pass as LiteRT-LM's callback_data and, through
// out_proxy_fn, the callback to pass with it. Returns NULL, with
// *out_proxy_fn NULL too, for a missing argument or an allocation failure.
STREAM_PROXY_EXPORT
void* stream_proxy_create_v1(LiteRtLmStreamCallback dart_callback,
                             void* dart_data, ChunkGetTextFn get_text,
                             ChunkGetErrorFn get_error,
                             ChunkIsFinalFn is_final,
                             LiteRtLmChunkCallback* out_proxy_fn) {
  if (out_proxy_fn == NULL) return NULL;
  *out_proxy_fn = NULL;
  if (dart_callback == NULL || get_text == NULL || get_error == NULL ||
      is_final == NULL) {
    return NULL;
  }
  ProxyDataV1* proxy = (ProxyDataV1*)calloc(1, sizeof(ProxyDataV1));
  if (proxy == NULL) return NULL;
  proxy->dart_callback = dart_callback;
  proxy->dart_data = dart_data;
  proxy->get_text = get_text;
  proxy->get_error = get_error;
  proxy->is_final = is_final;
  *out_proxy_fn = stream_proxy_callback_v1;
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
