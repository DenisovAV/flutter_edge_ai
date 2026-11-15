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
// Dart treats a chunk with an error, and a final chunk, as the end of the
// turn: it ends the turn (which releases the engine for the next one) and
// closes the callback. So the proxy hands Dart exactly one terminal chunk,
// and only on the chunk LiteRT-LM marks final, when native has stopped:
// - an accessor that fails, or a copy that runs out of memory, is recorded,
//   later text is dropped, and the recorded error is delivered with the final
//   chunk;
// - an error LiteRT-LM reports on a chunk that is not final is held the same
//   way.
// Nothing on a failure path allocates: the error message buffer is allocated
// when the proxy is created. When is_final itself cannot be read, the end of
// the stream cannot be seen: the chunk is dropped, and if that was the final
// chunk the proxy (a few words) is never freed and Dart never gets its end;
// freeing it then would hand LiteRT-LM's next callback freed memory.
//
// A send that LiteRT-LM refuses (send_message_stream returns non-OK) never
// calls back; the caller frees that proxy with stream_proxy_destroy_v1.

#ifdef STREAM_PROXY_TEST_HOOKS
// The host test counts and fails allocations (stream_proxy_test.c).
void* stream_proxy_test_malloc(size_t size);
void stream_proxy_test_free(void* ptr);
#define PROXY_MALLOC stream_proxy_test_malloc
#define PROXY_FREE stream_proxy_test_free
#else
#define PROXY_MALLOC malloc
#define PROXY_FREE free
#endif

enum { kProxyMessageSize = 192 };

typedef struct {
  LiteRtLmStreamCallback dart_callback;
  void* dart_data;
  ChunkGetTextFn get_text;
  ChunkGetErrorFn get_error;
  ChunkIsFinalFn is_final;
  // The first failure, delivered with the final chunk: `message` (the
  // preallocated buffer) or a copy of LiteRT-LM's own error. NULL while the
  // stream is fine.
  char* pending_error;
  // Preallocated, kProxyMessageSize bytes; handed to Dart as the error, or
  // freed with the proxy.
  char* message;
} ProxyDataV1;

static char* proxy_dup(const char* s) {
  size_t n = strlen(s) + 1;
  char* copy = (char*)PROXY_MALLOC(n);
  if (copy != NULL) memcpy(copy, s, n);
  return copy;
}

static void proxy_free(ProxyDataV1* proxy) {
  if (proxy->pending_error != NULL && proxy->pending_error != proxy->message) {
    PROXY_FREE(proxy->pending_error);
  }
  PROXY_FREE(proxy->message);
  PROXY_FREE(proxy);
}

// Records the first failure; `status` 0 means an allocation failure.
static void proxy_note_failure(ProxyDataV1* proxy, const char* what,
                               int status) {
  if (proxy->pending_error != NULL) return;
  if (status != 0) {
    snprintf(proxy->message, kProxyMessageSize,
             "stream_proxy: %s failed with LiteRtLmStatusCode %d", what,
             status);
  } else {
    snprintf(proxy->message, kProxyMessageSize, "stream_proxy: %s", what);
  }
  proxy->pending_error = proxy->message;
}

// The final chunk of a stream that failed: the recorded error, ownership to
// Dart, then the proxy is freed.
static void proxy_end_failed(ProxyDataV1* proxy) {
  char* error = proxy->pending_error;
  if (error == proxy->message) proxy->message = NULL;
  proxy->pending_error = NULL;
  proxy->dart_callback(proxy->dart_data, NULL, 1, error);
  proxy_free(proxy);
}

static void stream_proxy_callback_v1(void* callback_data, const void* chunk) {
  ProxyDataV1* proxy = (ProxyDataV1*)callback_data;

  _Bool is_final = 0;
  int status = proxy->is_final(chunk, &is_final);
  if (status != 0) {
    // The end of the stream cannot be seen: see above.
    proxy_note_failure(proxy, "litert_lm_stream_chunk_is_final", status);
    return;
  }
  if (proxy->pending_error == NULL) {
    const char* text = NULL;
    status = proxy->get_text(chunk, &text);
    if (status != 0) {
      proxy_note_failure(proxy, "litert_lm_stream_chunk_get_text", status);
    }
    const char* error_msg = NULL;
    if (status == 0) {
      status = proxy->get_error(chunk, &error_msg);
      if (status != 0) {
        proxy_note_failure(proxy, "litert_lm_stream_chunk_get_error", status);
      }
    }
    if (status == 0) {
      // "No error" is an EMPTY string, and Dart treats any non-NULL error
      // pointer as a failed stream.
      int has_error = error_msg != NULL && error_msg[0] != 0;
      char* text_copy = text != NULL ? proxy_dup(text) : NULL;
      char* error_copy = has_error ? proxy_dup(error_msg) : NULL;
      if ((text != NULL && text_copy == NULL) ||
          (has_error && error_copy == NULL)) {
        PROXY_FREE(text_copy);
        PROXY_FREE(error_copy);
        proxy_note_failure(proxy, "out of memory copying a stream chunk", 0);
      } else if (has_error && !is_final) {
        // LiteRT-LM reported an error but has not ended the stream: hold it
        // until it does.
        PROXY_FREE(text_copy);
        proxy->pending_error = error_copy;
      } else {
        proxy->dart_callback(proxy->dart_data, text_copy, is_final, error_copy);
        if (is_final) proxy_free(proxy);
        return;
      }
    }
  }
  // The stream has failed: drop the chunk, end it for Dart at the final one.
  if (is_final) proxy_end_failed(proxy);
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
  ProxyDataV1* proxy = (ProxyDataV1*)PROXY_MALLOC(sizeof(ProxyDataV1));
  if (proxy == NULL) return NULL;
  memset(proxy, 0, sizeof *proxy);
  proxy->message = (char*)PROXY_MALLOC(kProxyMessageSize);
  if (proxy->message == NULL) {
    PROXY_FREE(proxy);
    return NULL;
  }
  proxy->dart_callback = dart_callback;
  proxy->dart_data = dart_data;
  proxy->get_text = get_text;
  proxy->get_error = get_error;
  proxy->is_final = is_final;
  *out_proxy_fn = stream_proxy_callback_v1;
  return proxy;
}

// Frees a proxy LiteRT-LM never called back: the send it was made for was
// refused (send_message_stream returned non-OK). Never call it for a started
// send; that proxy is freed with its final chunk.
STREAM_PROXY_EXPORT
void stream_proxy_destroy_v1(void* proxy) {
  if (proxy != NULL) proxy_free((ProxyDataV1*)proxy);
}

// Free a chunk or error string that was copied by the proxy.
STREAM_PROXY_EXPORT
void stream_proxy_free_string(char* str) {
  PROXY_FREE(str);
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
