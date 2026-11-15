// A stand-in for libLiteRtLm, for stream_proxy_test.c: the three stream chunk
// accessors in their C API 1.0 shape (a LiteRtLmStatusCode, the value through
// an out-parameter). A chunk can make each accessor fail.
//
//   cc -shared -fPIC -o libfake_ok.so                  fake_litert_lm.c
//   cc -shared -fPIC -DFAKE_SHADOW -o libfake_shadow.so fake_litert_lm.c
#include <stddef.h>

typedef struct {
  const char* text;
  const char* error;
  _Bool is_final;
  int text_status;   // returned by get_text when non-zero
  int error_status;  // returned by get_error when non-zero
  int final_status;  // returned by is_final when non-zero
} FakeChunk;

int litert_lm_stream_chunk_get_text(const void* chunk, const char** out_text) {
  const FakeChunk* c = (const FakeChunk*)chunk;
  if (c->text_status) return c->text_status;
#ifdef FAKE_SHADOW
  *out_text = "shadow";  // a different library answering the same names
#else
  *out_text = c->text;
#endif
  return 0;
}

int litert_lm_stream_chunk_get_error(const void* chunk,
                                     const char** out_error) {
  const FakeChunk* c = (const FakeChunk*)chunk;
  if (c->error_status) return c->error_status;
  *out_error = c->error;
  return 0;
}

int litert_lm_stream_chunk_is_final(const void* chunk, _Bool* out_is_final) {
  const FakeChunk* c = (const FakeChunk*)chunk;
  if (c->final_status) return c->final_status;
  *out_is_final = c->is_final;
  return 0;
}
