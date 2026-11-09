// EmbeddingGemma 2 text vectors from one libLiteRtLm, for a drift comparison
// between LiteRT-LM releases. One text per line in, one float32 vector per
// line out, with the options the Dart pass sets (normalize, special tokens,
// truncate). The C API changed shape at 1.0 (status codes, out-parameters),
// so this builds against either: -DC_API_018 for native-v0.18.x, nothing for
// 1.0.
//
// A line "image:<path>" or "audio:<path>" embeds that file as one part
// instead; EG2_VISION=1 / EG2_AUDIO=1 declare the towers (on the CPU, 140
// vision tokens per image), as the Dart pass does.
//
//   cc -O1 [-DC_API_018] -o eg2_text eg2_text.c -ldl
//   eg2_text <lib> <model.litertlm> <cpu|gpu> <texts.txt> <out.f32> [<cache dir>]
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char* ReadWholeFile(const char* path, size_t* size) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* data = malloc((size_t)n);
  *size = fread(data, 1, (size_t)n, f);
  fclose(f);
  return data;
}

typedef void* P;
static void* g_lib;
static void* Sym(const char* name) {
  void* f = dlsym(g_lib, name);
  if (!f) {
    fprintf(stderr, "missing export %s\n", name);
    exit(4);
  }
  return f;
}
#define S(type, name) ((type)Sym(name))

int main(int argc, char** argv) {
  if (argc < 6) {
    fprintf(stderr, "usage: %s <lib> <model> <cpu|gpu> <texts> <out> [cache]\n",
            argv[0]);
    return 64;
  }
  g_lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!g_lib) {
    fprintf(stderr, "cannot load %s: %s\n", argv[1], dlerror());
    return 3;
  }
  P settings = NULL, engine = NULL, opts = NULL;
#ifdef C_API_018
  const char* vb = getenv("EG2_VISION") ? "cpu" : NULL;
  const char* ab = getenv("EG2_AUDIO") ? "cpu" : NULL;
  settings = S(P (*)(const char*, const char*, const char*, const char*),
               "litert_lm_embedding_engine_settings_create")(argv[2], argv[3],
                                                             vb, ab);
  if (vb)
    S(void (*)(P, int),
      "litert_lm_embedding_engine_settings_set_vision_tokens_per_image")(
        settings, 140);
  S(void (*)(P, int), "litert_lm_embedding_engine_settings_set_max_input_length")(
      settings, 1024);
  if (argc > 6)
    S(void (*)(P, const char*), "litert_lm_embedding_engine_settings_set_cache_dir")(
        settings, argv[6]);
  engine = S(P (*)(P), "litert_lm_embedding_engine_create")(settings);
  opts = S(P (*)(void), "litert_lm_embedding_options_create")();
  S(void (*)(P, bool), "litert_lm_embedding_options_set_normalize")(opts, true);
  S(void (*)(P, bool), "litert_lm_embedding_options_set_insert_special_tokens")(
      opts, true);
  S(void (*)(P, int), "litert_lm_embedding_options_set_input_overflow_strategy")(
      opts, 1);
#else
  int (*settings_create)(const char*, const char*, const char*, const char*,
                         P*) =
      S(int (*)(const char*, const char*, const char*, const char*, P*),
        "litert_lm_embedding_engine_settings_create");
  const char* vb = getenv("EG2_VISION") ? "cpu" : NULL;
  const char* ab = getenv("EG2_AUDIO") ? "cpu" : NULL;
  settings_create(argv[2], argv[3], vb, ab, &settings);
  // EG2_AUDIO_THREADS / EG2_THREADS: the audio tower's and the engine's CPU
  // thread counts (to see whether a result depends on them).
  if (getenv("EG2_AUDIO_THREADS"))
    S(int (*)(P, int), "litert_lm_embedding_engine_settings_set_audio_num_threads")(
        settings, atoi(getenv("EG2_AUDIO_THREADS")));
  if (getenv("EG2_THREADS"))
    S(int (*)(P, int), "litert_lm_embedding_engine_settings_set_num_threads")(
        settings, atoi(getenv("EG2_THREADS")));
  if (vb)
    S(int (*)(P, int),
      "litert_lm_embedding_engine_settings_set_vision_tokens_per_image")(
        settings, 140);
  S(int (*)(P, int), "litert_lm_embedding_engine_settings_set_max_input_length")(
      settings, 1024);
  if (argc > 6)
    S(int (*)(P, const char*), "litert_lm_embedding_engine_settings_set_cache_dir")(
        settings, argv[6]);
  S(int (*)(P, P*), "litert_lm_embedding_engine_create")(settings, &engine);
  S(int (*)(P*), "litert_lm_embedding_options_create")(&opts);
  S(int (*)(P, bool), "litert_lm_embedding_options_set_normalize")(opts, true);
  S(int (*)(P, bool), "litert_lm_embedding_options_set_insert_special_tokens")(
      opts, true);
  S(int (*)(P, int), "litert_lm_embedding_options_set_input_overflow_strategy")(
      opts, 1);
#endif
  if (!engine) {
    printf("RESULT eg2_text FAIL engine create\n");
    return 1;
  }
  FILE* in = fopen(argv[4], "r");
  FILE* out = fopen(argv[5], "wb");
  char line[16384];
  int n = 0;
  size_t dim = 0;
  while (fgets(line, sizeof line, in)) {
    line[strcspn(line, "\n")] = 0;
    if (!line[0]) continue;
    P input = NULL, resp = NULL;
    const float* v = NULL;
    int type = 0;
    const char* data = line;
    size_t size = strlen(line);
    char* blob = NULL;
    if (!strncmp(line, "image:", 6) || !strncmp(line, "audio:", 6)) {
      type = line[0] == 'i' ? 1 : 3;
      blob = ReadWholeFile(line + 6, &size);
      if (!blob) {
        printf("RESULT eg2_text FAIL cannot read %s\n", line + 6);
        return 1;
      }
      data = blob;
    }
#ifdef C_API_018
    input = S(P (*)(int, const void*, size_t), "litert_lm_input_data_create")(
        type, data, size);
    resp = S(P (*)(P, const P*, size_t, P),
             "litert_lm_embedding_engine_compute_embedding")(engine, &input, 1,
                                                             opts);
    if (resp) {
      dim = S(size_t (*)(P), "litert_lm_embedding_response_get_size")(resp);
      v = S(const float* (*)(P), "litert_lm_embedding_response_get_values")(resp);
    }
#else
    S(int (*)(int, const void*, size_t, P*), "litert_lm_input_data_create")(
        type, data, size, &input);
    S(int (*)(P, const P*, size_t, P, P*),
      "litert_lm_embedding_engine_compute_embedding")(engine, &input, 1, opts,
                                                      &resp);
    if (resp) {
      S(int (*)(P, size_t*), "litert_lm_embedding_response_get_size")(resp, &dim);
      S(int (*)(P, const float**), "litert_lm_embedding_response_get_values")(
          resp, &v);
    }
#endif
    if (!v) {
      printf("RESULT eg2_text FAIL line %d\n", n);
      return 1;
    }
    fwrite(v, sizeof(float), dim, out);
    S(void (*)(P), "litert_lm_embedding_response_delete")(resp);
    S(void (*)(P), "litert_lm_input_data_delete")(input);
    free(blob);
    n++;
  }
  fclose(in);
  fclose(out);
  printf("RESULT eg2_text PASS embedded=%d dim=%zu\n", n, dim);
  return 0;
}
