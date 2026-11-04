// Host test for stream_proxy.c (POSIX only; the Windows branch is not covered).
//
// stream_proxy_create_v1 takes the three C API 1.0 chunk accessors from the
// caller, which resolves them on the library it drives; these scenarios open
// fakes the way Dart does (RTLD_LOCAL), check the proxy uses exactly the
// accessors it was given, reads values through the out-parameters (a status 0
// is OK, not a NULL text), and hands Dart exactly one terminal chunk, on the
// chunk native marks final: a failed accessor, a failed copy, or a native error
// on a chunk that is not final is held until then. Allocations go through
// counting hooks (STREAM_PROXY_TEST_HOOKS); every scenario ends with none
// live, and a hook can fail the next allocation.
//
//   run_stream_proxy_test.sh builds the fakes and runs every scenario (CI does this); by hand:
//   D=/tmp/sp; mkdir -p $D
//   cc -shared -fPIC -o $D/libfake_ok.so         fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_SHADOW -o $D/libfake_shadow.so fake_litert_lm.c
//   cc -g -fsanitize=thread -pthread -o $D/stream_proxy_test stream_proxy_test.c -ldl
//   for s in $($D/stream_proxy_test list); do $D/stream_proxy_test $s $D || echo "FAIL $s"; done
//
// On a kernel whose mmap randomization ThreadSanitizer rejects ("unexpected
// memory mapping"), run it as `setarch $(uname -m) -R $D/stream_proxy_test …`.
//
// It includes stream_proxy.c so each scenario starts from a clean process.
#define STREAM_PROXY_TEST_HOOKS 1
#include <stdlib.h>
#include <string.h>
void* stream_proxy_test_malloc(size_t size);
void stream_proxy_test_free(void* ptr);
#include "stream_proxy.c"

static int g_live;        // allocations made through the hooks, not freed
static int g_fail_after;  // >0: the g_fail_after-th allocation from now fails
void* stream_proxy_test_malloc(size_t size) {
  if (g_fail_after > 0 && --g_fail_after == 0) return NULL;
  void* p = malloc(size);
  if (p != NULL) __atomic_add_fetch(&g_live, 1, __ATOMIC_RELAXED);
  return p;
}
void stream_proxy_test_free(void* ptr) {
  if (ptr == NULL) return;
  __atomic_sub_fetch(&g_live, 1, __ATOMIC_RELAXED);
  free(ptr);
}

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  const char* text;
  const char* error;
  _Bool is_final;
  int text_status;
  int error_status;
  int final_status;
} FakeChunk;

static int g_calls;
static char g_last_text[64];
static char g_last_error[160];
static int g_last_error_null;
static _Bool g_last_final;

static void dart_cb(void* data, const char* chunk, _Bool is_final,
                    const char* error_msg) {
  (void)data;
  g_calls++;
  snprintf(g_last_text, sizeof g_last_text, "%s", chunk ? chunk : "<null>");
  snprintf(g_last_error, sizeof g_last_error, "%s",
           error_msg ? error_msg : "<null>");
  g_last_error_null = error_msg == NULL;
  g_last_final = is_final;
  stream_proxy_free_string((char*)chunk);
  stream_proxy_free_string((char*)error_msg);
}

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      fprintf(stderr, "CHECK failed %s:%d: %s\n", __FILE__, __LINE__,     \
              #cond);                                                     \
      return 1;                                                           \
    }                                                                     \
  } while (0)

// Opens [name] the way Dart's DynamicLibrary.open does (RTLD_LOCAL, or
// RTLD_GLOBAL when [global]) and resolves the accessors on that handle only.
typedef struct {
  void* handle;
  ChunkGetTextFn get_text;
  ChunkGetErrorFn get_error;
  ChunkIsFinalFn is_final;
} Fake;

static int open_fake(const char* dir, const char* name, int global, Fake* f) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  f->handle = dlopen(path, RTLD_LAZY | (global ? RTLD_GLOBAL : RTLD_LOCAL));
  if (f->handle == NULL) return 0;
  f->get_text = (ChunkGetTextFn)dlsym(f->handle, "litert_lm_stream_chunk_get_text");
  f->get_error = (ChunkGetErrorFn)dlsym(f->handle, "litert_lm_stream_chunk_get_error");
  f->is_final = (ChunkIsFinalFn)dlsym(f->handle, "litert_lm_stream_chunk_is_final");
  return f->get_text && f->get_error && f->is_final;
}

static void* create(const Fake* f, LiteRtLmChunkCallback* fn) {
  return stream_proxy_create_v1(dart_cb, NULL, f->get_text, f->get_error,
                                f->is_final, fn);
}

static int s_ok(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL && fn != NULL);
  FakeChunk token = {"hi", "", 0, 0, 0, 0};
  fn(proxy, &token);
  // The text comes through the out-parameter, not the status (0) read as a
  // pointer: with the pre-1.0 accessor types every reply would be empty.
  CHECK(g_calls == 1 && strcmp(g_last_text, "hi") == 0);
  CHECK(g_last_error_null);  // "" is no error
  CHECK(!g_last_final);
  FakeChunk last = {NULL, "boom", 1, 0, 0, 0};
  fn(proxy, &last);  // frees proxy
  CHECK(g_calls == 2 && g_last_final && !g_last_error_null);
  CHECK(strcmp(g_last_error, "boom") == 0);
  CHECK(strcmp(g_last_text, "<null>") == 0);
  CHECK(g_live == 0);
  return 0;
}

static int s_bad_args(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn = (LiteRtLmChunkCallback)(void*)1;
  CHECK(stream_proxy_create_v1(dart_cb, NULL, NULL, f.get_error, f.is_final, &fn) == NULL);
  CHECK(fn == NULL);  // the out-param is cleared on failure
  fn = (LiteRtLmChunkCallback)(void*)1;
  CHECK(stream_proxy_create_v1(dart_cb, NULL, f.get_text, NULL, f.is_final, &fn) == NULL);
  CHECK(fn == NULL);
  fn = (LiteRtLmChunkCallback)(void*)1;
  CHECK(stream_proxy_create_v1(dart_cb, NULL, f.get_text, f.get_error, NULL, &fn) == NULL);
  CHECK(fn == NULL);
  fn = (LiteRtLmChunkCallback)(void*)1;
  CHECK(stream_proxy_create_v1(NULL, NULL, f.get_text, f.get_error, f.is_final, &fn) == NULL);
  CHECK(fn == NULL);
  CHECK(stream_proxy_create_v1(dart_cb, NULL, f.get_text, f.get_error, f.is_final, NULL) == NULL);
  return 0;
}

// A different library answers the same names in the ambient scope. The proxy
// must use the accessors it was given, not whatever the scope offers.
static int s_shadowed(const char* dir) {
  Fake shadow, good;
  CHECK(open_fake(dir, "libfake_shadow.so", 1, &shadow));
  CHECK(open_fake(dir, "libfake_ok.so", 0, &good));
  CHECK(dlsym(RTLD_DEFAULT, "litert_lm_stream_chunk_get_text") ==
        (void*)shadow.get_text);
  LiteRtLmChunkCallback fn;
  void* proxy = create(&good, &fn);
  CHECK(proxy != NULL);
  FakeChunk token = {"hi", "", 0, 0, 0, 0};
  fn(proxy, &token);
  CHECK(strcmp(g_last_text, "hi") == 0);
  stream_proxy_destroy_v1(proxy);
  CHECK(g_live == 0);
  return 0;
}

static int s_empty_error_is_null(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk token = {"x", "", 0, 0, 0, 0};
  fn(proxy, &token);
  CHECK(g_last_error_null);
  stream_proxy_destroy_v1(proxy);
  CHECK(g_live == 0);
  return 0;
}

// A failed accessor ends the stream for Dart once, with an error that names
// it, and only at the chunk native marks final: Dart ends the turn (releasing
// the engine) and closes its callback on that chunk, so it must not come while
// native still decodes. Chunks in between reach Dart no more.
static int failed_accessor(const char* dir, int which) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk bad = {"lost", "", 0, which == 0 ? 7 : 0, which == 1 ? 7 : 0, 0};
  fn(proxy, &bad);
  CHECK(g_calls == 0);  // native is still decoding: no end yet
  FakeChunk later = {"late", "", 0, 0, 0, 0};
  fn(proxy, &later);
  CHECK(g_calls == 0);
  FakeChunk last = {NULL, "", 1, 0, 0, 0};
  fn(proxy, &last);  // frees proxy
  CHECK(g_calls == 1 && g_last_final && !g_last_error_null);
  CHECK(strstr(g_last_error, which == 0 ? "get_text" : "get_error") != NULL);
  CHECK(strstr(g_last_error, "7") != NULL);
  CHECK(strcmp(g_last_text, "<null>") == 0);
  CHECK(g_live == 0);
  return 0;
}
static int s_failed_text(const char* dir) { return failed_accessor(dir, 0); }
static int s_failed_error(const char* dir) { return failed_accessor(dir, 1); }

// is_final fails on a chunk that is not final: the chunk is dropped, and the
// stream ends for Dart, with that error, at the chunk that reads as final.
static int s_failed_final(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk bad = {"x", "", 0, 0, 0, 9};
  fn(proxy, &bad);
  fn(proxy, &bad);
  FakeChunk later = {"late", "", 0, 0, 0, 0};
  fn(proxy, &later);
  CHECK(g_calls == 0);
  FakeChunk last = {"end", "", 1, 0, 0, 0};
  fn(proxy, &last);  // frees proxy
  CHECK(g_calls == 1 && g_last_final && strstr(g_last_error, "is_final") != NULL);
  CHECK(g_live == 0);
  return 0;
}

// is_final fails on the final chunk itself: the end cannot be seen, so Dart
// gets nothing and the proxy is not freed (freeing it could hand a later
// callback freed memory). The test owns it.
static int s_failed_final_on_last(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk last = {"end", "", 1, 0, 0, 9};
  fn(proxy, &last);
  CHECK(g_calls == 0);
  CHECK(g_live == 2);  // the proxy and its message buffer
  stream_proxy_destroy_v1(proxy);
  CHECK(g_live == 0);
  return 0;
}

// The failure is on the final chunk itself: one error, and the proxy is freed.
static int s_failed_on_final(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk last = {"x", "", 1, 3, 0, 0};
  fn(proxy, &last);  // frees proxy
  CHECK(g_calls == 1 && g_last_final && strstr(g_last_error, "get_text") != NULL);
  CHECK(g_live == 0);
  return 0;
}

// LiteRT-LM reports an error on a chunk it does not mark final: Dart gets
// that error, once, with the final chunk, and no text in between.
static int s_native_error_not_final(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk err = {"x", "INTERNAL: boom", 0, 0, 0, 0};
  fn(proxy, &err);
  FakeChunk later = {"late", "", 0, 0, 0, 0};
  fn(proxy, &later);
  CHECK(g_calls == 0);
  FakeChunk last = {NULL, "", 1, 0, 0, 0};
  fn(proxy, &last);  // frees proxy
  CHECK(g_calls == 1 && g_last_final);
  CHECK(strcmp(g_last_error, "INTERNAL: boom") == 0);
  CHECK(g_live == 0);
  return 0;
}

// A copy that runs out of memory is an error at the end, never a chunk that
// silently lost its text (a NULL chunk with no error reads as nothing).
static int oom_copy(const char* dir, int final_chunk, int copy) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL);
  FakeChunk ok = {"before", "", 0, 0, 0, 0};
  fn(proxy, &ok);
  CHECK(g_calls == 1 && strcmp(g_last_text, "before") == 0);
  g_calls = 0;
  // copy 1 = the text, 2 = the error (the chunk carries both)
  FakeChunk hit = {"t", copy == 2 ? "E" : "", final_chunk, 0, 0, 0};
  g_fail_after = copy;
  fn(proxy, &hit);
  g_fail_after = 0;
  if (!final_chunk) {
    CHECK(g_calls == 0);
    FakeChunk last = {NULL, "", 1, 0, 0, 0};
    fn(proxy, &last);  // frees proxy
  }
  CHECK(g_calls == 1 && g_last_final && !g_last_error_null);
  CHECK(strstr(g_last_error, "out of memory") != NULL);
  CHECK(g_live == 0);
  return 0;
}
static int s_oom_text(const char* dir) { return oom_copy(dir, 0, 1); }
static int s_oom_error_final(const char* dir) { return oom_copy(dir, 1, 2); }

// create itself out of memory: NULL, nothing left allocated.
static int s_oom_create(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  for (int n = 1; n <= 2; n++) {
    LiteRtLmChunkCallback fn = (LiteRtLmChunkCallback)(void*)1;
    g_fail_after = n;
    void* proxy = create(&f, &fn);
    g_fail_after = 0;
    CHECK(proxy == NULL && fn == NULL);
    CHECK(g_live == 0);
  }
  return 0;
}

// A refused send never calls back; destroy_v1 frees its proxy.
static int s_refused_send(const char* dir) {
  Fake f;
  CHECK(open_fake(dir, "libfake_ok.so", 0, &f));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&f, &fn);
  CHECK(proxy != NULL && g_live == 2);
  stream_proxy_destroy_v1(proxy);
  CHECK(g_calls == 0 && g_live == 0);
  stream_proxy_destroy_v1(NULL);
  return 0;
}

#ifndef _WIN32
// A stream is running while other isolates create proxies. Under
// -fsanitize=thread this must stay clean: the shim keeps no shared state.
static Fake g_fake;
static int g_stop;  // accessed only through __atomic builtins

static void* hammer_creates(void* arg) {
  (void)arg;
  while (!__atomic_load_n(&g_stop, __ATOMIC_RELAXED)) {
    LiteRtLmChunkCallback fn;
    void* p = create(&g_fake, &fn);
    if (p != NULL) stream_proxy_destroy_v1(p);
  }
  return NULL;
}

static int s_concurrent(const char* dir) {
  CHECK(open_fake(dir, "libfake_ok.so", 0, &g_fake));
  LiteRtLmChunkCallback fn;
  void* proxy = create(&g_fake, &fn);
  CHECK(proxy != NULL);
  pthread_t threads[3];
  for (int i = 0; i < 3; i++) pthread_create(&threads[i], NULL, hammer_creates, NULL);
  FakeChunk token = {"t", "", 0, 0, 0, 0};
  for (int i = 0; i < 200000; i++) fn(proxy, &token);
  __atomic_store_n(&g_stop, 1, __ATOMIC_RELAXED);
  for (int i = 0; i < 3; i++) pthread_join(threads[i], NULL);
  CHECK(g_calls == 200000);
  stream_proxy_destroy_v1(proxy);
  CHECK(g_live == 0);
  return 0;
}
#else
static int s_concurrent(const char* dir) { (void)dir; return 0; }
#endif

static const char* kScenarios =
    "ok bad_args shadowed empty_error_is_null failed_text failed_error "
    "failed_final failed_final_on_last failed_on_final native_error_not_final "
    "oom_text oom_error_final oom_create refused_send concurrent";

int main(int argc, char** argv) {
  if (argc == 2 && !strcmp(argv[1], "list")) {
    printf("%s\n", kScenarios);
    return 0;
  }
  if (argc < 3) return 2;
  const char* s = argv[1];
  const char* dir = argv[2];
  int rc;
  if (!strcmp(s, "ok")) rc = s_ok(dir);
  else if (!strcmp(s, "bad_args")) rc = s_bad_args(dir);
  else if (!strcmp(s, "shadowed")) rc = s_shadowed(dir);
  else if (!strcmp(s, "empty_error_is_null")) rc = s_empty_error_is_null(dir);
  else if (!strcmp(s, "failed_text")) rc = s_failed_text(dir);
  else if (!strcmp(s, "failed_error")) rc = s_failed_error(dir);
  else if (!strcmp(s, "failed_final")) rc = s_failed_final(dir);
  else if (!strcmp(s, "failed_final_on_last")) rc = s_failed_final_on_last(dir);
  else if (!strcmp(s, "failed_on_final")) rc = s_failed_on_final(dir);
  else if (!strcmp(s, "native_error_not_final")) rc = s_native_error_not_final(dir);
  else if (!strcmp(s, "oom_text")) rc = s_oom_text(dir);
  else if (!strcmp(s, "oom_error_final")) rc = s_oom_error_final(dir);
  else if (!strcmp(s, "oom_create")) rc = s_oom_create(dir);
  else if (!strcmp(s, "refused_send")) rc = s_refused_send(dir);
  else if (!strcmp(s, "concurrent")) rc = s_concurrent(dir);
  else return 2;
  printf("%s: %s\n", s, rc == 0 ? "ok" : "FAILED");
  return rc;
}
