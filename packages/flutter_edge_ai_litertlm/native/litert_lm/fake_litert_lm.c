// A stand-in for libLiteRtLm, for stream_proxy_test.c: exports the control
// symbol and, depending on the build, the v0.15 chunk accessors.
//
//   cc -shared -fPIC -o libfake_ok.so       fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_NO_ACCESSORS -o libfake_none.so    fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_PARTIAL      -o libfake_partial.so fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_NO_CONTROL   -o libfake_nocontrol.so fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_SHADOW       -o libfake_shadow.so    fake_litert_lm.c
#include <stddef.h>

typedef struct {
  const char* text;
  const char* error;
  _Bool is_final;
} FakeChunk;

#ifndef FAKE_NO_CONTROL
void* litert_lm_engine_create(void* settings) { return settings; }
#else
void* fake_unrelated(void* p) { return p; }
#endif

#ifndef FAKE_NO_ACCESSORS
const char* litert_lm_stream_chunk_get_text(const void* chunk) {
#ifdef FAKE_SHADOW
  (void)chunk;
  return "shadow";  // a different library answering the same symbol names
#else
  return ((const FakeChunk*)chunk)->text;
#endif
}
#ifndef FAKE_PARTIAL
const char* litert_lm_stream_chunk_get_error(const void* chunk) {
  return ((const FakeChunk*)chunk)->error;
}
_Bool litert_lm_stream_chunk_is_final(const void* chunk) {
  return ((const FakeChunk*)chunk)->is_final;
}
#endif
#endif
