// LiteRT-LM C API 1.0 probes for the v0.19.0 migration (phase 1).
//
// Loads libLiteRtLm at run time, so one source builds on macOS, Linux and
// Windows without an import library:
//
//   cc  -O2 -o litertlm_probe litertlm_probe.c -ldl          (Linux)
//   cc  -O2 -o litertlm_probe litertlm_probe.c               (macOS)
//   cl  /O2 litertlm_probe.c                                 (Windows)
//
//   litertlm_probe <lib> <command> <model> <backend> [args]
//
// Commands print one line per result, `RESULT <name> <PASS|FAIL|INFO> ...`,
// so a run log can be grepped into the phase-1 table. Nothing here is
// shipped; the Dart client is the product.

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
typedef HMODULE LibHandle;
static LibHandle OpenLib(const char* path) { return LoadLibraryA(path); }
static void* Sym(LibHandle h, const char* name) {
  return (void*)GetProcAddress(h, name);
}
#else
#include <dlfcn.h>
typedef void* LibHandle;
static LibHandle OpenLib(const char* path) {
  return dlopen(path, RTLD_NOW | RTLD_GLOBAL);
}
static void* Sym(LibHandle h, const char* name) { return dlsym(h, name); }
#endif

typedef int Status;  // LiteRtLmStatusCode, 0 = OK
typedef void* P;

// ---- the C API, as v0.19.0 declares it ----
#define API(ret, name, args) typedef ret(*name##_t) args; static name##_t name;
API(Status, litert_lm_get_api_version, (int*, int*, int*))
API(const char*, litert_lm_get_last_error_message, (void))
API(Status, litert_lm_set_min_log_level, (int))
API(Status, litert_lm_engine_settings_create,
    (const char*, const char*, const char*, const char*, P*))
API(Status, litert_lm_engine_settings_set_max_num_tokens, (P, int))
API(Status, litert_lm_engine_settings_set_num_threads, (P, int))
API(Status, litert_lm_engine_settings_set_cache_dir, (P, const char*))
API(Status, litert_lm_engine_settings_set_litert_dispatch_lib_dir,
    (P, const char*))
API(Status, litert_lm_engine_settings_enable_benchmark, (P))
API(Status, litert_lm_engine_settings_set_speculative_decoding_config, (P, P))
API(void, litert_lm_engine_settings_delete, (P))
API(Status, litert_lm_engine_create, (P, P*))
API(void, litert_lm_engine_delete, (P))
API(Status, litert_lm_session_config_create, (P*))
API(Status, litert_lm_session_config_set_sampler_params, (P, P))
API(Status, litert_lm_session_config_set_apply_prompt_template, (P, bool))
API(Status, litert_lm_session_config_set_max_output_tokens, (P, int))
API(void, litert_lm_session_config_delete, (P))
API(Status, litert_lm_sampler_params_create, (int, P*))
API(Status, litert_lm_sampler_params_set_top_k, (P, int32_t))
API(Status, litert_lm_sampler_params_set_top_p, (P, float))
API(Status, litert_lm_sampler_params_set_temperature, (P, float))
API(void, litert_lm_sampler_params_delete, (P))
API(Status, litert_lm_engine_create_session, (P, P, P*))
API(void, litert_lm_session_delete, (P))
API(Status, litert_lm_input_data_create, (int, const void*, size_t, P*))
API(void, litert_lm_input_data_delete, (P))
API(Status, litert_lm_session_run_prefill, (P, const P*, size_t))
API(Status, litert_lm_session_save_checkpoint, (P, const char*))
API(Status, litert_lm_session_rewind_to_checkpoint, (P, const char*))
API(Status, litert_lm_session_run_text_scoring,
    (P, const char**, size_t, bool, P*))
API(Status, litert_lm_responses_get_num_token_scores_at, (P, size_t, size_t*))
API(Status, litert_lm_responses_get_token_scores_at,
    (P, size_t, const float**))
API(void, litert_lm_responses_delete, (P))
API(Status, litert_lm_conversation_config_create, (P*))
API(Status, litert_lm_conversation_config_set_session_config, (P, P))
API(Status, litert_lm_conversation_config_set_tools, (P, const char*))
API(Status, litert_lm_conversation_config_set_enable_constrained_decoding,
    (P, bool))
API(Status, litert_lm_conversation_config_set_constraint_provider, (P, int))
API(void, litert_lm_conversation_config_delete, (P))
API(Status, litert_lm_conversation_create, (P, P, P*))
API(void, litert_lm_conversation_delete, (P))
API(Status, litert_lm_conversation_send_message,
    (P, const char*, const char*, P, P*))
API(Status, litert_lm_json_response_get_string, (P, const char**))
API(void, litert_lm_json_response_delete, (P))
API(Status, litert_lm_conversation_optional_args_create, (P*))
API(Status, litert_lm_conversation_optional_args_set_constraint,
    (P, int, const char*))
API(void, litert_lm_conversation_optional_args_delete, (P))
API(Status, litert_lm_conversation_get_benchmark_info, (P, P*))
API(Status, litert_lm_benchmark_info_get_num_decode_turns, (P, size_t*))
API(Status, litert_lm_benchmark_info_get_decode_tokens_per_sec_at,
    (P, size_t, double*))
API(Status, litert_lm_benchmark_info_get_decode_token_count_at,
    (P, size_t, size_t*))
API(Status, litert_lm_benchmark_info_get_max_num_tokens, (P, int*))
API(void, litert_lm_benchmark_info_delete, (P))
API(Status, litert_lm_speculative_decoding_config_create, (P*))
API(Status, litert_lm_speculative_decoding_config_set_mode, (P, int))
API(void, litert_lm_speculative_decoding_config_delete, (P))
API(Status, litert_lm_embedding_engine_settings_create,
    (const char*, const char*, const char*, const char*, P*))
API(Status, litert_lm_embedding_engine_settings_set_max_input_length, (P, int))
API(Status, litert_lm_embedding_engine_settings_set_cache_dir,
    (P, const char*))
API(void, litert_lm_embedding_engine_settings_delete, (P))
API(Status, litert_lm_embedding_engine_create, (P, P*))
API(void, litert_lm_embedding_engine_delete, (P))
API(Status, litert_lm_embedding_options_create, (P*))
API(Status, litert_lm_embedding_options_set_input_overflow_strategy, (P, int))
API(void, litert_lm_embedding_options_delete, (P))
API(Status, litert_lm_embedding_engine_compute_embedding,
    (P, const P*, size_t, P, P*))
API(Status, litert_lm_embedding_response_get_size, (P, size_t*))
API(Status, litert_lm_embedding_response_get_values, (P, const float**))
API(Status, litert_lm_embedding_response_get_input_length, (P, int*))
API(Status, litert_lm_embedding_response_get_truncated_length, (P, int*))
API(void, litert_lm_embedding_response_delete, (P))

#define LOAD(name)                                                 \
  do {                                                             \
    name = (name##_t)Sym(lib, #name);                              \
    if (!name) {                                                   \
      fprintf(stderr, "missing export %s\n", #name);               \
      missing++;                                                   \
    }                                                              \
  } while (0)

static int LoadAll(LibHandle lib) {
  int missing = 0;
  LOAD(litert_lm_get_api_version);
  LOAD(litert_lm_get_last_error_message);
  LOAD(litert_lm_set_min_log_level);
  LOAD(litert_lm_engine_settings_create);
  LOAD(litert_lm_engine_settings_set_max_num_tokens);
  LOAD(litert_lm_engine_settings_set_num_threads);
  LOAD(litert_lm_engine_settings_set_cache_dir);
  LOAD(litert_lm_engine_settings_set_litert_dispatch_lib_dir);
  LOAD(litert_lm_engine_settings_enable_benchmark);
  LOAD(litert_lm_engine_settings_set_speculative_decoding_config);
  LOAD(litert_lm_engine_settings_delete);
  LOAD(litert_lm_engine_create);
  LOAD(litert_lm_engine_delete);
  LOAD(litert_lm_session_config_create);
  LOAD(litert_lm_session_config_set_sampler_params);
  LOAD(litert_lm_session_config_set_apply_prompt_template);
  LOAD(litert_lm_session_config_set_max_output_tokens);
  LOAD(litert_lm_session_config_delete);
  LOAD(litert_lm_sampler_params_create);
  LOAD(litert_lm_sampler_params_set_top_k);
  LOAD(litert_lm_sampler_params_set_top_p);
  LOAD(litert_lm_sampler_params_set_temperature);
  LOAD(litert_lm_sampler_params_delete);
  LOAD(litert_lm_engine_create_session);
  LOAD(litert_lm_session_delete);
  LOAD(litert_lm_input_data_create);
  LOAD(litert_lm_input_data_delete);
  LOAD(litert_lm_session_run_prefill);
  LOAD(litert_lm_session_save_checkpoint);
  LOAD(litert_lm_session_rewind_to_checkpoint);
  LOAD(litert_lm_session_run_text_scoring);
  LOAD(litert_lm_responses_get_num_token_scores_at);
  LOAD(litert_lm_responses_get_token_scores_at);
  LOAD(litert_lm_responses_delete);
  LOAD(litert_lm_conversation_config_create);
  LOAD(litert_lm_conversation_config_set_session_config);
  LOAD(litert_lm_conversation_config_set_tools);
  LOAD(litert_lm_conversation_config_set_enable_constrained_decoding);
  LOAD(litert_lm_conversation_config_set_constraint_provider);
  LOAD(litert_lm_conversation_config_delete);
  LOAD(litert_lm_conversation_create);
  LOAD(litert_lm_conversation_delete);
  LOAD(litert_lm_conversation_send_message);
  LOAD(litert_lm_json_response_get_string);
  LOAD(litert_lm_json_response_delete);
  LOAD(litert_lm_conversation_optional_args_create);
  LOAD(litert_lm_conversation_optional_args_set_constraint);
  LOAD(litert_lm_conversation_optional_args_delete);
  LOAD(litert_lm_conversation_get_benchmark_info);
  LOAD(litert_lm_benchmark_info_get_num_decode_turns);
  LOAD(litert_lm_benchmark_info_get_decode_tokens_per_sec_at);
  LOAD(litert_lm_benchmark_info_get_decode_token_count_at);
  LOAD(litert_lm_benchmark_info_get_max_num_tokens);
  LOAD(litert_lm_benchmark_info_delete);
  LOAD(litert_lm_speculative_decoding_config_create);
  LOAD(litert_lm_speculative_decoding_config_set_mode);
  LOAD(litert_lm_speculative_decoding_config_delete);
  LOAD(litert_lm_embedding_engine_settings_create);
  LOAD(litert_lm_embedding_engine_settings_set_max_input_length);
  LOAD(litert_lm_embedding_engine_settings_set_cache_dir);
  LOAD(litert_lm_embedding_engine_settings_delete);
  LOAD(litert_lm_embedding_engine_create);
  LOAD(litert_lm_embedding_engine_delete);
  LOAD(litert_lm_embedding_options_create);
  LOAD(litert_lm_embedding_options_set_input_overflow_strategy);
  LOAD(litert_lm_embedding_options_delete);
  LOAD(litert_lm_embedding_engine_compute_embedding);
  LOAD(litert_lm_embedding_response_get_size);
  LOAD(litert_lm_embedding_response_get_values);
  LOAD(litert_lm_embedding_response_get_input_length);
  LOAD(litert_lm_embedding_response_get_truncated_length);
  LOAD(litert_lm_embedding_response_delete);
  return missing;
}

// ---- helpers ----
static void Die(const char* what, Status s) {
  const char* e = litert_lm_get_last_error_message
                      ? litert_lm_get_last_error_message()
                      : NULL;
  printf("RESULT error FAIL %s status=%d last_error=%s\n", what, s,
         e ? e : "(none)");
  fflush(stdout);
  exit(2);
}
#define CHECK(call)                       \
  do {                                    \
    Status _s = (call);                   \
    if (_s != 0) Die(#call, _s);          \
  } while (0)

static double Now(void) {
  struct timespec ts;
  timespec_get(&ts, TIME_UTC);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char* g_cache_dir = NULL;
static const char* g_dispatch_dir = NULL;
static int g_max_tokens = 1024;

static P NewEngine(const char* model, const char* backend, int mtp_mode) {
  P settings = NULL, engine = NULL;
  CHECK(litert_lm_engine_settings_create(model, backend, NULL, NULL,
                                         &settings));
  CHECK(litert_lm_engine_settings_set_max_num_tokens(settings, g_max_tokens));
  if (g_cache_dir) {
    CHECK(litert_lm_engine_settings_set_cache_dir(settings, g_cache_dir));
  }
  if (getenv("PROBE_THREADS")) {
    CHECK(litert_lm_engine_settings_set_num_threads(
        settings, atoi(getenv("PROBE_THREADS"))));
  }
  if (g_dispatch_dir) {
    CHECK(litert_lm_engine_settings_set_litert_dispatch_lib_dir(
        settings, g_dispatch_dir));
  }
  CHECK(litert_lm_engine_settings_enable_benchmark(settings));
  if (mtp_mode >= 0) {
    P spec = NULL;
    CHECK(litert_lm_speculative_decoding_config_create(&spec));
    CHECK(litert_lm_speculative_decoding_config_set_mode(spec, mtp_mode));
    CHECK(litert_lm_engine_settings_set_speculative_decoding_config(settings,
                                                                    spec));
    litert_lm_speculative_decoding_config_delete(spec);
  }
  double t0 = Now();
  CHECK(litert_lm_engine_create(settings, &engine));
  printf("INFO engine_create %.2fs backend=%s\n", Now() - t0, backend);
  litert_lm_engine_settings_delete(settings);
  return engine;
}

// Greedy: TOP_P (2), k 1, p 1, temperature 1 — the sampler litetune scores with.
static P GreedySessionConfig(bool apply_template, int max_output) {
  P config = NULL, sampler = NULL;
  CHECK(litert_lm_session_config_create(&config));
  CHECK(litert_lm_sampler_params_create(2, &sampler));
  CHECK(litert_lm_sampler_params_set_top_k(sampler, 1));
  CHECK(litert_lm_sampler_params_set_top_p(sampler, 1.0f));
  CHECK(litert_lm_sampler_params_set_temperature(
      sampler, getenv("PROBE_TEMP") ? (float)atof(getenv("PROBE_TEMP")) : 1.0f));
  CHECK(litert_lm_session_config_set_sampler_params(config, sampler));
  litert_lm_sampler_params_delete(sampler);
  if (!apply_template) {
    CHECK(litert_lm_session_config_set_apply_prompt_template(config, false));
  }
  if (max_output > 0) {
    CHECK(litert_lm_session_config_set_max_output_tokens(config, max_output));
  }
  return config;
}

static P NewConversation(P engine, const char* tools, bool constrained,
                         bool llguidance, int max_output) {
  P cfg = NULL, conv = NULL;
  P sc = GreedySessionConfig(true, max_output);
  CHECK(litert_lm_conversation_config_create(&cfg));
  CHECK(litert_lm_conversation_config_set_session_config(cfg, sc));
  if (tools) CHECK(litert_lm_conversation_config_set_tools(cfg, tools));
  if (constrained) {
    CHECK(litert_lm_conversation_config_set_enable_constrained_decoding(cfg,
                                                                        true));
  }
  if (llguidance) {
    CHECK(litert_lm_conversation_config_set_constraint_provider(cfg, 1));
  }
  CHECK(litert_lm_conversation_create(engine, cfg, &conv));
  litert_lm_conversation_config_delete(cfg);
  litert_lm_session_config_delete(sc);
  return conv;
}

// Sends one user message; returns a malloc'd copy of the response JSON.
static char* Send(P conv, const char* text, P optional_args, Status* status) {
  char msg[4096];
  // `text` is ASCII without quotes or backslashes in every probe.
  snprintf(msg, sizeof msg, "{\"role\":\"user\",\"content\":\"%s\"}", text);
  P resp = NULL;
  *status = litert_lm_conversation_send_message(conv, msg, NULL, optional_args,
                                                &resp);
  if (*status != 0) return NULL;
  const char* json = NULL;
  CHECK(litert_lm_json_response_get_string(resp, &json));
  char* copy = strdup(json ? json : "");
  litert_lm_json_response_delete(resp);
  return copy;
}

// The first "text":"…" value of a response, unescaped minimally (\" \\ \n).
static void TextOf(const char* json, char* out, size_t cap) {
  out[0] = 0;
  const char* p = strstr(json, "\"text\":\"");
  if (!p) return;
  p += 8;
  size_t n = 0;
  while (*p && n + 1 < cap) {
    if (*p == '\\' && p[1]) {
      p++;
      out[n++] = (*p == 'n') ? '\n' : *p;
      p++;
      continue;
    }
    if (*p == '"') break;
    out[n++] = *p++;
  }
  out[n] = 0;
}

static void DecodeStats(P conv, double* tok_s, size_t* tokens, int* max_nt) {
  P info = NULL;
  *tok_s = -1;
  *tokens = 0;
  *max_nt = -1;
  if (litert_lm_conversation_get_benchmark_info(conv, &info) != 0) return;
  size_t turns = 0;
  litert_lm_benchmark_info_get_num_decode_turns(info, &turns);
  if (turns > 0) {
    litert_lm_benchmark_info_get_decode_tokens_per_sec_at(info, turns - 1,
                                                          tok_s);
    litert_lm_benchmark_info_get_decode_token_count_at(info, turns - 1,
                                                       tokens);
  }
  litert_lm_benchmark_info_get_max_num_tokens(info, max_nt);
  litert_lm_benchmark_info_delete(info);
}

static uint64_t Fnv(const char* s) {
  uint64_t h = 1469598103934665603ull;
  for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ull;
  return h;
}

// ---- session helpers (scoring / rewind) ----
static void Prefill(P session, const char* text) {
  P input = NULL;
  CHECK(litert_lm_input_data_create(0, text, strlen(text), &input));
  const P inputs[1] = {input};
  CHECK(litert_lm_session_run_prefill(session, inputs, 1));
  litert_lm_input_data_delete(input);
}

static int Score(P session, const char* target, float* out, int cap) {
  P resp = NULL;
  const char* targets[1] = {target};
  CHECK(litert_lm_session_run_text_scoring(session, targets, 1, true, &resp));
  size_t n = 0;
  const float* scores = NULL;
  CHECK(litert_lm_responses_get_num_token_scores_at(resp, 0, &n));
  CHECK(litert_lm_responses_get_token_scores_at(resp, 0, &scores));
  int k = (int)n < cap ? (int)n : cap;
  for (int i = 0; i < k; i++) out[i] = scores[i];
  litert_lm_responses_delete(resp);
  return k;
}

static P NewSession(P engine) {
  P sc = GreedySessionConfig(false, 0);
  P session = NULL;
  CHECK(litert_lm_engine_create_session(engine, sc, &session));
  litert_lm_session_config_delete(sc);
  return session;
}

static double MaxDiff(const float* a, int na, const float* b, int nb) {
  if (na != nb) return INFINITY;
  double m = 0;
  for (int i = 0; i < na; i++) {
    double d = fabs((double)a[i] - b[i]);
    if (d > m) m = d;
  }
  return m;
}

// Prompts in the model's own turn markers (Gemma 4 or Gemma 3 style).
static bool g_gemma4 = false;
static void User(char* out, size_t cap, const char* text) {
  if (g_gemma4) {
    snprintf(out, cap, "<|turn>user\n%s<turn|>\n<|turn>model\n", text);
  } else {
    snprintf(out, cap,
             "<start_of_turn>user\n%s<end_of_turn>\n<start_of_turn>model\n",
             text);
  }
}

// ---- commands ----

// Several live conversations on one engine (LiteRT-LM #966): each keeps its
// own history while the others run turns in between.
static int CmdMulticonv(P engine) {
  const char* names[3] = {"Alice", "Bruno", "Chen"};
  P conv[3];
  Status s;
  for (int i = 0; i < 3; i++) {
    conv[i] = NewConversation(engine, NULL, false, false, 32);
    printf("INFO conversation %d created\n", i);
  }
  for (int i = 0; i < 3; i++) {
    char msg[256];
    snprintf(msg, sizeof msg,
             "My name is %s. Reply with the single word OK.", names[i]);
    char* r = Send(conv[i], msg, NULL, &s);
    if (!r) {
      printf("RESULT multiconv_turn1_conv%d FAIL status=%d err=%s\n", i, s,
             litert_lm_get_last_error_message());
      return 1;
    }
    free(r);
  }
  int ok = 0;
  for (int i = 2; i >= 0; i--) {
    char* r = Send(conv[i], "What is my name? Reply with the name only.",
                   NULL, &s);
    if (!r) {
      printf("RESULT multiconv_turn2_conv%d FAIL status=%d err=%s\n", i, s,
             litert_lm_get_last_error_message());
      return 1;
    }
    char text[512];
    TextOf(r, text, sizeof text);
    bool good = strstr(text, names[i]) != NULL;
    ok += good;
    printf("RESULT multiconv_conv%d %s answer=\"%s\"\n", i,
           good ? "PASS" : "FAIL", text);
    free(r);
  }
  for (int i = 0; i < 3; i++) litert_lm_conversation_delete(conv[i]);
  printf("RESULT multiconv %s %d/3 conversations kept their own history\n",
         ok == 3 ? "PASS" : "FAIL", ok);
  return ok == 3 ? 0 : 1;
}

// LLGuidance constraints through the C API: a JSON schema with an enum and a
// regex, then the same prompt unconstrained for tok/s.
static int CmdConstrained(P engine) {
  const char* schema =
      "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\","
      "\"enum\":[\"red\",\"green\",\"blue\"]}},\"required\":[\"color\"],"
      "\"additionalProperties\":false}";
  const char* prompt =
      "Which color is a clear sky at noon? Answer in JSON with a color key.";
  int failures = 0;
  Status s;
  for (int kind = 0; kind < 3; kind++) {
    // 0: unconstrained, 1: JSON schema, 2: regex
    P conv = NewConversation(engine, NULL, false, kind != 0, 64);
    P args = NULL;
    if (kind != 0) {
      CHECK(litert_lm_conversation_optional_args_create(&args));
      if (kind == 1) {
        CHECK(litert_lm_conversation_optional_args_set_constraint(args, 2,
                                                                  schema));
      } else {
        CHECK(litert_lm_conversation_optional_args_set_constraint(
            args, 1, "(red|green|blue)"));
      }
    }
    double t0 = Now();
    char* r = Send(conv, prompt, args, &s);
    double dt = Now() - t0;
    const char* name = kind == 0 ? "constrained_none"
                       : kind == 1 ? "constrained_json_schema"
                                   : "constrained_regex";
    if (!r) {
      printf("RESULT %s FAIL status=%d err=%s\n", name, s,
             litert_lm_get_last_error_message());
      failures++;
    } else {
      char text[2048];
      TextOf(r, text, sizeof text);
      double tok_s;
      size_t tokens;
      int max_nt;
      DecodeStats(conv, &tok_s, &tokens, &max_nt);
      bool valid = true;
      if (kind == 1) {
        valid = text[0] == '{' &&
                (strstr(text, "\"red\"") || strstr(text, "\"green\"") ||
                 strstr(text, "\"blue\"")) &&
                strstr(text, "\"color\"");
      } else if (kind == 2) {
        valid = !strcmp(text, "red") || !strcmp(text, "green") ||
                !strcmp(text, "blue");
      }
      if (!valid) failures++;
      printf("RESULT %s %s decode_tok_s=%.1f tokens=%zu wall=%.2fs "
             "text=\"%s\"\n",
             name, kind == 0 ? "INFO" : (valid ? "PASS" : "FAIL"), tok_s,
             tokens, dt, text);
      free(r);
    }
    if (args) litert_lm_conversation_optional_args_delete(args);
    litert_lm_conversation_delete(conv);
  }
  return failures ? 1 : 0;
}

// §16 + #3947/#4197: checkpoint, prefill, rewind, prefill, score — against the
// same prefills without the rewind (session-level, as on 2026-10-28).
static int CmdRewind(P engine) {
  char a[512], c[512];
  User(a, sizeof a, "Name one fruit. Answer with one word.");
  char next[256];
  User(next, sizeof next, "And one color?");
  snprintf(c, sizeof c, "Banana%s%s", g_gemma4 ? "<turn|>\n" : "<end_of_turn>\n",
           next);
  const char* b = "Apple is a red";
  const char* t = "Red";
  float s1[64], s2[64], s3[64], s4[64];
  int n1, n2, n3, n4;
  P x = NewSession(engine);
  Prefill(x, a);
  Prefill(x, c);
  n1 = Score(x, t, s1, 64);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, a);
  CHECK(litert_lm_session_save_checkpoint(x, "probe"));
  Prefill(x, b);
  CHECK(litert_lm_session_rewind_to_checkpoint(x, "probe"));
  Prefill(x, c);
  n2 = Score(x, t, s2, 64);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, a);
  CHECK(litert_lm_session_save_checkpoint(x, "probe"));
  CHECK(litert_lm_session_rewind_to_checkpoint(x, "probe"));
  Prefill(x, c);
  n3 = Score(x, t, s3, 64);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, a);
  Prefill(x, c);
  n4 = Score(x, t, s4, 64);
  litert_lm_session_delete(x);
  double d = MaxDiff(s1, n1, s2, n2);
  printf("RESULT rewind_exact %s max_diff=%g no_rewind=%f rewound=%f\n",
         d == 0 ? "PASS" : "FAIL", d, n1 ? s1[0] : NAN, n2 ? s2[0] : NAN);
  printf("RESULT rewind_control %s max_diff=%g (nothing to roll back)\n",
         MaxDiff(s1, n1, s3, n3) == 0 ? "PASS" : "FAIL",
         MaxDiff(s1, n1, s3, n3));
  printf("RESULT rewind_repeatable %s max_diff=%g\n",
         MaxDiff(s1, n1, s4, n4) == 0 ? "PASS" : "FAIL",
         MaxDiff(s1, n1, s4, n4));
  return d == 0 ? 0 : 1;
}

// #3561 (fixed by #3702): the self-check's pair must now differ (mode plain),
// and in plain mode a target scored after a rewind equals one scored alone.
static int CmdScoring(P engine) {
  const char* a =
      "<start_of_turn>user\nAnswer with one word.<end_of_turn>\n"
      "<start_of_turn>model\n";
  const char* b =
      "<start_of_turn>user\nAnswer with one word.<end_of_turn>\n"
      "<start_of_turn>user\n";
  const char* t = "Yes";
  const char* t2 = "No";
  float sa[8], sb[8], sa2[8], alone[8], after[8];
  int na, nb, na2, nalone, nafter;
  P x = NewSession(engine);
  Prefill(x, a);
  na = Score(x, t, sa, 8);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, b);
  nb = Score(x, t, sb, 8);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, a);
  na2 = Score(x, t, sa2, 8);
  litert_lm_session_delete(x);
  printf("RESULT scoring_repeatable %s max_diff=%g\n",
         MaxDiff(sa, na, sa2, na2) == 0 ? "PASS" : "FAIL",
         MaxDiff(sa, na, sa2, na2));
  double pair = MaxDiff(sa, na, sb, nb);
  printf("RESULT scoring_mode %s pair_diff=%g -> self-check picks %s\n",
         pair > 0 ? "PASS" : "FAIL", pair, pair > 0 ? "plain" : "once");
  x = NewSession(engine);
  Prefill(x, a);
  nalone = Score(x, t, alone, 8);
  litert_lm_session_delete(x);
  x = NewSession(engine);
  Prefill(x, a);
  CHECK(litert_lm_session_save_checkpoint(x, "probe"));
  float tmp[8];
  Score(x, t2, tmp, 8);
  CHECK(litert_lm_session_rewind_to_checkpoint(x, "probe"));
  nafter = Score(x, t, after, 8);
  litert_lm_session_delete(x);
  double d = MaxDiff(alone, nalone, after, nafter);
  printf("RESULT scoring_plain_after_rewind %s max_diff=%g alone=%f "
         "after=%f\n",
         d == 0 ? "PASS" : "FAIL", d, alone[0], after[0]);
  return (pair > 0 && d == 0) ? 0 : 1;
}

// Speculative decoding: the engine is created per mode by the caller; one
// greedy turn, its text hash and decode speed.
static int CmdMtp(P engine, const char* mode) {
  Status s;
  P conv = NewConversation(engine, NULL, false, false, 128);
  double t0 = Now();
  char* r = Send(conv,
                 "Write one short paragraph about the ocean, about 80 words.",
                 NULL, &s);
  double dt = Now() - t0;
  if (!r) {
    printf("RESULT mtp_%s FAIL status=%d err=%s\n", mode, s,
           litert_lm_get_last_error_message());
    return 1;
  }
  char text[8192];
  TextOf(r, text, sizeof text);
  double tok_s;
  size_t tokens;
  int max_nt;
  DecodeStats(conv, &tok_s, &tokens, &max_nt);
  printf("RESULT mtp_%s INFO decode_tok_s=%.1f tokens=%zu wall=%.2fs "
         "text_fnv=%016llx max_num_tokens=%d\n",
         mode, tok_s, tokens, dt, (unsigned long long)Fnv(text), max_nt);
  printf("TEXT mtp_%s %s\n", mode, text);
  free(r);
  litert_lm_conversation_delete(conv);
  return 0;
}

// #3508: a fact at the end of a prompt longer than one prefill chunk (128).
// A runtime that drops every chunk after the first answers without it.
static int CmdLongPrompt(P engine) {
  static char prompt[8192];
  size_t n = 0;
  n += snprintf(prompt + n, sizeof prompt - n,
                "Read these notes, then answer the question at the end. ");
  for (int i = 0; i < 40; i++) {
    n += snprintf(prompt + n, sizeof prompt - n,
                  "Note %d: the weather report for district %d says light "
                  "wind and some clouds. ",
                  i + 1, i + 1);
  }
  n += snprintf(prompt + n, sizeof prompt - n,
                "Final note: the secret word is PELICAN. Question: what is "
                "the secret word? Reply with the word only.");
  Status s;
  P conv = NewConversation(engine, NULL, false, false, 16);
  char* r = Send(conv, prompt, NULL, &s);
  if (!r) {
    printf("RESULT longprompt FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    return 1;
  }
  char text[512];
  TextOf(r, text, sizeof text);
  bool ok = strstr(text, "PELICAN") || strstr(text, "Pelican") ||
            strstr(text, "pelican");
  printf("RESULT longprompt %s prompt_chars=%zu answer=\"%s\"\n",
         ok ? "PASS" : "FAIL", n, text);
  free(r);
  litert_lm_conversation_delete(conv);
  return ok ? 0 : 1;
}

// Greedy determinism inside one process: the same prompt in two fresh
// conversations on one engine must give the same text (the 0.18 smoke check
// "greedy run1 == run2").
static int CmdDeterminism(P engine) {
  const char* prompt =
      "Write one short paragraph about the ocean, about 80 words.";
  char texts[2][8192];
  for (int i = 0; i < 2; i++) {
    Status s;
    P conv = NewConversation(engine, NULL, false, false, 96);
    char* r = Send(conv, prompt, NULL, &s);
    if (!r) {
      printf("RESULT determinism FAIL status=%d err=%s\n", s,
             litert_lm_get_last_error_message());
      return 1;
    }
    TextOf(r, texts[i], sizeof texts[i]);
    free(r);
    litert_lm_conversation_delete(conv);
  }
  bool same = !strcmp(texts[0], texts[1]);
  size_t k = 0;
  while (texts[0][k] && texts[0][k] == texts[1][k]) k++;
  printf("RESULT determinism %s first_diff_at_char=%zu fnv=%016llx/%016llx\n",
         same ? "PASS" : "FAIL", same ? (size_t)0 : k,
         (unsigned long long)Fnv(texts[0]), (unsigned long long)Fnv(texts[1]));
  return same ? 0 : 1;
}

// A tool call through the model's own constraint provider (Gemma) — the §12
// bridge on Linux, the prebuilt provider elsewhere.
static int CmdTools(P engine) {
  const char* tools =
      "[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\","
      "\"description\":\"Gets the current weather for a city.\","
      "\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{"
      "\"type\":\"string\",\"description\":\"The city name.\"}},"
      "\"required\":[\"city\"]}}}]";
  Status s;
  P conv = NewConversation(engine, tools, true, false, 64);
  char* r = Send(conv, "What is the weather in Paris right now?", NULL, &s);
  if (!r) {
    printf("RESULT tools FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    return 1;
  }
  bool called = strstr(r, "tool_calls") && strstr(r, "get_weather") &&
                strstr(r, "Paris");
  printf("RESULT tools %s response=%s\n", called ? "PASS" : "FAIL", r);
  free(r);
  litert_lm_conversation_delete(conv);
  return called ? 0 : 1;
}

// EmbeddingGemma 2: one query, its dimension, length and norm.
static int CmdEg2(const char* model, const char* backend) {
  P settings = NULL, engine = NULL, opts = NULL, input = NULL, resp = NULL;
  CHECK(litert_lm_embedding_engine_settings_create(model, backend, NULL, NULL,
                                                   &settings));
  CHECK(litert_lm_embedding_engine_settings_set_max_input_length(settings,
                                                                 1024));
  if (g_cache_dir) {
    CHECK(litert_lm_embedding_engine_settings_set_cache_dir(settings,
                                                            g_cache_dir));
  }
  double t0 = Now();
  Status s = litert_lm_embedding_engine_create(settings, &engine);
  if (s != 0) {
    printf("RESULT eg2_create FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    return 1;
  }
  printf("INFO eg2 create %.2fs\n", Now() - t0);
  CHECK(litert_lm_embedding_options_create(&opts));
  CHECK(litert_lm_embedding_options_set_input_overflow_strategy(opts, 1));
  const char* text = "task: search result | query: how do plants make food";
  CHECK(litert_lm_input_data_create(0, text, strlen(text), &input));
  const P inputs[1] = {input};
  t0 = Now();
  s = litert_lm_embedding_engine_compute_embedding(engine, inputs, 1, opts,
                                                   &resp);
  if (s != 0) {
    printf("RESULT eg2_embed FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    return 1;
  }
  double dt = Now() - t0;
  size_t dim = 0;
  const float* v = NULL;
  int in_len = -1, trunc = -1;
  CHECK(litert_lm_embedding_response_get_size(resp, &dim));
  CHECK(litert_lm_embedding_response_get_values(resp, &v));
  CHECK(litert_lm_embedding_response_get_input_length(resp, &in_len));
  CHECK(litert_lm_embedding_response_get_truncated_length(resp, &trunc));
  double norm = 0;
  bool finite = v != NULL;
  for (size_t i = 0; v && i < dim; i++) {
    if (!isfinite(v[i])) finite = false;
    norm += (double)v[i] * v[i];
  }
  norm = sqrt(norm);
  bool ok = finite && dim > 0 && norm > 0.5 && norm < 2.0;
  printf("RESULT eg2 %s dim=%zu input_length=%d truncated=%d norm=%.4f "
         "first=%.5f,%.5f,%.5f embed=%.3fs\n",
         ok ? "PASS" : "FAIL", dim, in_len, trunc, norm, v ? v[0] : NAN,
         v && dim > 1 ? v[1] : NAN, v && dim > 2 ? v[2] : NAN, dt);
  litert_lm_embedding_response_delete(resp);
  litert_lm_input_data_delete(input);
  litert_lm_embedding_options_delete(opts);
  litert_lm_embedding_engine_delete(engine);
  litert_lm_embedding_engine_settings_delete(settings);
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr,
            "usage: %s <libLiteRtLm> <multiconv|constrained|rewind|scoring|"
            "mtp-off|mtp-on|mtp-adaptive|mtp-default|tools|longprompt|determinism|eg2> "
            "<model> <cpu|gpu|npu>\n  env: PROBE_CACHE_DIR, PROBE_MAX_TOKENS, "
            "PROBE_DISPATCH_DIR\n",
            argv[0]);
    return 64;
  }
  LibHandle lib = OpenLib(argv[1]);
  if (!lib) {
#if defined(_WIN32)
    fprintf(stderr, "cannot load %s (error %lu)\n", argv[1], GetLastError());
#else
    fprintf(stderr, "cannot load %s: %s\n", argv[1], dlerror());
#endif
    return 3;
  }
  int missing = LoadAll(lib);
  int major = -1, minor = -1, patch = -1;
  if (litert_lm_get_api_version) {
    litert_lm_get_api_version(&major, &minor, &patch);
  }
  printf("INFO c_api %d.%d.%d missing_exports=%d\n", major, minor, patch,
         missing);
  if (missing) return 4;
  litert_lm_set_min_log_level(3);
  g_cache_dir = getenv("PROBE_CACHE_DIR");
  g_dispatch_dir = getenv("PROBE_DISPATCH_DIR");
  if (getenv("PROBE_MAX_TOKENS")) g_max_tokens = atoi(getenv("PROBE_MAX_TOKENS"));
  const char* cmd = argv[2];
  const char* model = argv[3];
  const char* backend = argv[4];
  g_gemma4 = strstr(model, "gemma-4") != NULL || strstr(model, "gemma4") != NULL;
  if (!strcmp(cmd, "eg2")) return CmdEg2(model, backend);
  int mtp = -1;
  const char* mode = NULL;
  if (!strncmp(cmd, "mtp-", 4)) {
    mode = cmd + 4;
    mtp = !strcmp(mode, "off") ? 0
          : !strcmp(mode, "on") ? 1
          : !strcmp(mode, "adaptive") ? 2
                                      : -1;  // default: engine's own choice
  }
  // PROBE_MTP=off|on|adaptive sets the speculative mode of any command.
  if (mtp < 0 && getenv("PROBE_MTP")) {
    const char* m = getenv("PROBE_MTP");
    mtp = !strcmp(m, "off") ? 0 : !strcmp(m, "on") ? 1
          : !strcmp(m, "adaptive") ? 2 : -1;
  }
  P engine = NewEngine(model, backend, mtp);
  int rc;
  if (!strcmp(cmd, "multiconv")) rc = CmdMulticonv(engine);
  else if (!strcmp(cmd, "constrained")) rc = CmdConstrained(engine);
  else if (!strcmp(cmd, "rewind")) rc = CmdRewind(engine);
  else if (!strcmp(cmd, "scoring")) rc = CmdScoring(engine);
  else if (mode) rc = CmdMtp(engine, mode);
  else if (!strcmp(cmd, "tools")) rc = CmdTools(engine);
  else if (!strcmp(cmd, "longprompt")) rc = CmdLongPrompt(engine);
  else if (!strcmp(cmd, "determinism")) rc = CmdDeterminism(engine);
  else {
    fprintf(stderr, "unknown command %s\n", cmd);
    rc = 64;
  }
  litert_lm_engine_delete(engine);
  return rc;
}
