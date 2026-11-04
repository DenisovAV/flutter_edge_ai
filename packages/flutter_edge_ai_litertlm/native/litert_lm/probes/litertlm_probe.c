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
// Dart's DynamicLibrary.open does not ask for RTLD_GLOBAL; neither does this
// unless PROBE_RTLD_GLOBAL is set (an app's own load is what is measured).
static LibHandle OpenLib(const char* path) {
  return dlopen(path, RTLD_NOW | (getenv("PROBE_RTLD_GLOBAL") ? RTLD_GLOBAL
                                                                : RTLD_LOCAL));
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
API(Status, litert_lm_conversation_send_message_stream,
    (P, const char*, const char*, P, void (*)(void*, const void*), void*))
API(Status, litert_lm_conversation_cancel_process, (P))
API(Status, litert_lm_conversation_config_set_messages, (P, const char*))
API(Status, litert_lm_stream_chunk_get_text, (const void*, const char**))
API(Status, litert_lm_stream_chunk_get_error, (const void*, const char**))
API(Status, litert_lm_stream_chunk_is_final, (const void*, bool*))
API(Status, litert_lm_json_response_get_string, (P, const char**))
API(void, litert_lm_json_response_delete, (P))
API(Status, litert_lm_conversation_optional_args_create, (P*))
API(Status, litert_lm_conversation_optional_args_set_constraint,
    (P, int, const char*))
API(void, litert_lm_conversation_optional_args_delete, (P))
API(Status, litert_lm_conversation_get_benchmark_info, (P, P*))
API(Status, litert_lm_conversation_get_token_count, (P, size_t*))
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
API(Status, litert_lm_embedding_engine_settings_set_vision_tokens_per_image,
    (P, int))
API(Status, litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir,
    (P, const char*))
API(Status,
    litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir,
    (P, const char*))
API(Status,
    litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir,
    (P, const char*))
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

// Exports only our patched libraries have (patch_c_api.sh sections 16, 23):
// optional, so the probe still runs on an unpatched library.
typedef Status (*get_last_turn_end_t)(P, int*, int*);
static get_last_turn_end_t litert_lm_conversation_get_last_turn_end;
typedef Status (*rewind_cancelled_turn_t)(P, const char*, const char*, P,
                                          int*);
static rewind_cancelled_turn_t litert_lm_conversation_rewind_cancelled_turn;

static int LoadAll(LibHandle lib) {
  litert_lm_conversation_get_last_turn_end =
      (get_last_turn_end_t)Sym(lib, "litert_lm_conversation_get_last_turn_end");
  litert_lm_conversation_rewind_cancelled_turn = (rewind_cancelled_turn_t)Sym(
      lib, "litert_lm_conversation_rewind_cancelled_turn");
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
  LOAD(litert_lm_conversation_send_message_stream);
  LOAD(litert_lm_conversation_cancel_process);
  LOAD(litert_lm_conversation_config_set_messages);
  LOAD(litert_lm_stream_chunk_get_text);
  LOAD(litert_lm_stream_chunk_get_error);
  LOAD(litert_lm_stream_chunk_is_final);
  LOAD(litert_lm_json_response_get_string);
  LOAD(litert_lm_json_response_delete);
  LOAD(litert_lm_conversation_optional_args_create);
  LOAD(litert_lm_conversation_optional_args_set_constraint);
  LOAD(litert_lm_conversation_optional_args_delete);
  LOAD(litert_lm_conversation_get_benchmark_info);
  LOAD(litert_lm_conversation_get_token_count);
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
  LOAD(litert_lm_embedding_engine_settings_set_vision_tokens_per_image);
  LOAD(litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir);
  LOAD(litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir);
  LOAD(litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir);
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
static void SleepMs(int ms) {
#if defined(_WIN32)
  Sleep(ms);
#else
  struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
#endif
}

static const char* g_cache_dir = NULL;
static const char* g_dispatch_dir = NULL;
static int g_max_tokens = 1024;

static P NewEngine(const char* model, const char* backend, int mtp_mode) {
  P settings = NULL, engine = NULL;
  // PROBE_VISION=cpu|gpu creates the vision executor (images in convrewind).
  CHECK(litert_lm_engine_settings_create(model, backend, getenv("PROBE_VISION"),
                                         NULL, &settings));
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
static char* Send(P conv, const char* text, P optional_args, Status* status);
static void DecodeStats(P conv, double* tok_s, size_t* tokens, int* max_nt);

// The turn-end record (section 23): how each kind of end is reported, and
// that a conversation whose input did not fit stays usable. Run with a small
// context, PROBE_MAX_TOKENS=256, so a long reply reaches it.
static const char* TurnEndName(int e) {
  switch (e) {
    case 0: return "none";
    case 1: return "completed";
    case 2: return "cancelled";
    case 3: return "failed";
    case 4: return "running";
    case 5: return "output_limit";
    case 6: return "context_limit";
    case 7: return "context_full";
    default: return "?";
  }
}
static int CheckTurnEnd(const char* label, P conv, int want) {
  int end = -1, code = -1;
  Status s = litert_lm_conversation_get_last_turn_end(conv, &end, &code);
  bool ok = s == 0 && end == want;
  printf("RESULT turnend_%s %s end=%s code=%d want=%s\n", label,
         ok ? "PASS" : "FAIL", TurnEndName(end), code, TurnEndName(want));
  return ok ? 0 : 1;
}
// Repeats a short sentence into a malloc'd text of about `chars` characters
// (roughly 4.5 characters per token).
static char* Filler(size_t chars) {
  const char* sentence = "The quick brown fox jumps over the dog. ";
  char* text = calloc(chars + 64, 1);
  while (strlen(text) + strlen(sentence) < chars) strcat(text, sentence);
  return text;
}
static int CmdTurnEnd(P engine) {
  if (!litert_lm_conversation_get_last_turn_end) {
    printf("RESULT turnend FAIL library has no "
           "litert_lm_conversation_get_last_turn_end\n");
    return 1;
  }
  int fail = 0;
  Status s;
  char* r;
  // A fresh conversation: nothing sent.
  P a = NewConversation(engine, NULL, false, false, 0);
  fail += CheckTurnEnd("fresh", a, 0);
  // 1. The model ends the reply.
  r = Send(a, "Reply with the single word OK.", NULL, &s);
  free(r);
  fail += CheckTurnEnd("stop_token", a, 1);
  litert_lm_conversation_delete(a);
  // 2. max_output_tokens (8).
  P b = NewConversation(engine, NULL, false, false, 8);
  r = Send(b, "Count from 1 to 60, separated by spaces.", NULL, &s);
  free(r);
  fail += CheckTurnEnd("max_output_tokens", b, 5);
  litert_lm_conversation_delete(b);
  // 3. The decode fills the context window. The prompt takes about 40% of
  // it, so the window ends before a model decides to stop on its own; a
  // model that still stops first is reported, not failed.
  P c = NewConversation(engine, NULL, false, false, 0);
  {
    char* filler = Filler((size_t)g_max_tokens * 18 / 10);
    char* prompt = calloc(strlen(filler) + 128, 1);
    sprintf(prompt, "%sNow write every number from 1 to 2000, separated by "
            "spaces.", filler);
    r = Send(c, prompt, NULL, &s);
    free(r);
    free(prompt);
    free(filler);
  }
  {
    int end = -1, code = -1;
    litert_lm_conversation_get_last_turn_end(c, &end, &code);
    if (end == 1) {
      double tok_s = 0;
      size_t tokens = 0;
      int max_nt = 0;
      DecodeStats(c, &tok_s, &tokens, &max_nt);
      printf("INFO turnend_max_num_tokens the model ended its reply after %zu "
             "tokens of a %d-token window: not a check\n", tokens, max_nt);
    } else {
      fail += CheckTurnEnd("max_num_tokens", c, 6);
    }
  }
  litert_lm_conversation_delete(c);
  // 4a. An input longer than the whole window. Upstream refuses it before its
  // prefill with INVALID_ARGUMENT and leaves the conversation failed; section
  // 23 reports it as the full context window it is (RESOURCE_EXHAUSTED), and
  // rewind_cancelled_turn makes the conversation usable again.
  P d = NewConversation(engine, NULL, false, false, 32);
  char* big = Filler((size_t)g_max_tokens * 6);
  r = Send(d, big, NULL, &s);
  free(r);
  free(big);
  fail += CheckTurnEnd("input_longer_than_window", d, 7);
  if (litert_lm_conversation_rewind_cancelled_turn) {
    int end = -1;
    Status rs =
        litert_lm_conversation_rewind_cancelled_turn(d, NULL, NULL, NULL, &end);
    bool ok = rs == 0 && end == 7;
    printf("RESULT turnend_rewind_after_input_longer_than_window %s status=%d "
           "end=%s\n", ok ? "PASS" : "FAIL", rs, TurnEndName(end));
    fail += !ok;
  }
  r = Send(d, "Reply with the single word OK.", NULL, &s);
  printf("RESULT turnend_usable_after_input_longer_than_window %s status=%d\n",
         r ? "PASS" : "FAIL", s);
  fail += !r;
  free(r);
  litert_lm_conversation_delete(d);

  // 4b. An input that fits the window but not what the history left of it:
  // RESOURCE_EXHAUSTED, the input is not prefilled and the session is left
  // failed (its prefill stays a dependency of the next task, measured on
  // v0.19.0); rewind_cancelled_turn rewinds it to the turn's checkpoint.
  P e = NewConversation(engine, NULL, false, false, 8);
  char* half = Filler((size_t)g_max_tokens * 23 / 10);
  r = Send(e, half, NULL, &s);  // about half of a 256-token window
  printf("INFO turnend_first_half send %s status=%d\n", r ? "ok" : "failed",
         s);
  free(r);
  r = Send(e, half, NULL, &s);  // does not fit what is left
  printf("INFO turnend_second_half send status=%d err=%s\n", s,
         r ? "" : litert_lm_get_last_error_message());
  free(r);
  fail += CheckTurnEnd("context_full", e, 7);
  if (litert_lm_conversation_rewind_cancelled_turn) {
    int end = -1;
    Status rs =
        litert_lm_conversation_rewind_cancelled_turn(e, NULL, NULL, NULL, &end);
    bool ok = rs == 0 && end == 7;
    printf("RESULT turnend_rewind_after_context_full %s status=%d end=%s\n",
           ok ? "PASS" : "FAIL", rs, TurnEndName(end));
    fail += !ok;
  }
  r = Send(e, "Reply with the single word OK.", NULL, &s);
  printf("RESULT turnend_usable_after_context_full %s status=%d\n",
         r ? "PASS" : "FAIL", s);
  fail += !r;
  free(r);
  {
    // The reply is capped at 8 tokens: either normal end is right.
    int end = -1, code = -1;
    litert_lm_conversation_get_last_turn_end(e, &end, &code);
    bool ok = end == 1 || end == 5;
    printf("RESULT turnend_after_context_full %s end=%s code=%d "
           "want=completed|output_limit\n", ok ? "PASS" : "FAIL",
           TurnEndName(end), code);
    fail += !ok;
  }
  free(half);
  litert_lm_conversation_delete(e);
  printf("RESULT turnend %s %d check(s) failed\n", fail ? "FAIL" : "PASS",
         fail);
  return fail ? 1 : 0;
}

// Less room left than the smallest prefill chunk (section 23). A CPU/GPU
// executor erases every prefill signature longer than the positions the
// window has left; when none is left it refuses even a short input that
// tasks.cc's own check lets through. Upstream says FAILED_PRECONDITION and
// the conversation is failed; section 23 says RESOURCE_EXHAUSTED, so the turn
// ends context_full and the rewind applies. The probe fills the window, then
// sends one short message per step until a send is refused, and prints the
// positions left at each step: run it twice to see the threshold repeat.
static int CmdPrefillRoom(P engine) {
  if (!litert_lm_conversation_get_last_turn_end) {
    printf("RESULT prefillroom FAIL library has no "
           "litert_lm_conversation_get_last_turn_end\n");
    return 1;
  }
  const char* shortmsg = "Reply with the single word OK.";
  P c = NewConversation(engine, NULL, false, false, 4);
  Status s;
  char* r;
  // Fill to about 300 positions short of the window.
  {
    char* filler = Filler((size_t)(g_max_tokens - 300) * 4);
    r = Send(c, filler, NULL, &s);
    free(filler);
    free(r);
    if (s != 0) {
      printf("RESULT prefillroom FAIL filler send status=%d err=%s\n", s,
             litert_lm_get_last_error_message());
      return 1;
    }
  }
  int fail = 0;
  size_t count = 0;
  for (int step = 0; step < 64; step++) {
    litert_lm_conversation_get_token_count(c, &count);
    long left = (long)g_max_tokens - (long)count;
    r = Send(c, shortmsg, NULL, &s);
    int end = -1, code = -1;
    litert_lm_conversation_get_last_turn_end(c, &end, &code);
    if (r) {
      size_t after = 0;
      litert_lm_conversation_get_token_count(c, &after);
      printf("INFO prefillroom step=%d left=%ld ok used=%zu end=%s\n", step,
             left, after - count, TurnEndName(end));
      free(r);
      continue;
    }
    const char* err = litert_lm_get_last_error_message();
    bool room = err && strstr(err, "exceeds available state entries");
    printf("INFO prefillroom step=%d left=%ld refused status=%d end=%s "
           "code=%d err=%s\n", step, left, s, TurnEndName(end), code,
           err ? err : "");
    if (!room) {
      // Another refusal (tasks.cc's own check, or a failure): reported, the
      // probe stops here.
      printf("RESULT prefillroom INFO refused by something else at left=%ld\n",
             left);
      break;
    }
    printf("RESULT prefillroom_end %s end=%s code=%d want=context_full\n",
           end == 7 ? "PASS" : "FAIL", TurnEndName(end), code);
    fail += end != 7;
    if (litert_lm_conversation_rewind_cancelled_turn) {
      int rend = -1;
      Status rs = litert_lm_conversation_rewind_cancelled_turn(c, NULL, NULL,
                                                               NULL, &rend);
      size_t back = 0;
      litert_lm_conversation_get_token_count(c, &back);
      bool ok = rs == 0 && back == count;
      printf("RESULT prefillroom_rewind %s status=%d end=%s count=%zu "
             "before=%zu\n", ok ? "PASS" : "FAIL", rs, TurnEndName(rend), back,
             count);
      fail += !ok;
      // The window has no more room for a prefill: the same send is refused
      // the same way, which is the determinism check within one run.
      r = Send(c, shortmsg, NULL, &s);
      litert_lm_conversation_get_last_turn_end(c, &end, &code);
      const char* err2 = litert_lm_get_last_error_message();
      bool same = !r && end == 7 && err2 &&
                  strstr(err2, "exceeds available state entries");
      printf("RESULT prefillroom_again %s left=%ld end=%s status=%d err=%s\n",
             same ? "PASS" : "FAIL", left, TurnEndName(end), s,
             err2 ? err2 : "");
      fail += !same;
      free(r);
    }
    break;
  }
  litert_lm_conversation_delete(c);
  printf("RESULT prefillroom %s %d check(s) failed\n", fail ? "FAIL" : "PASS",
         fail);
  return fail ? 1 : 0;
}

// Pre-tag probe 1: section 16 across conversations. A streamed reply on A is
// cancelled mid-decode, a turn runs on B, then A is rewound with the stopped
// exchange (the user message and the part of the reply produced, as the Dart
// client passes it) and asked a follow-up. The same path without B must give
// the same greedy follow-up, byte for byte: the turn on B left nothing in A.
// Run once without and once with an image (argument 5, PROBE_VISION set).
typedef struct {
  volatile int chunks;
  volatile int final;
  char text[16384];
  size_t len;
} Stream;
static void TextOf(const char* json, char* out, size_t cap);
static void OnChunk(void* data, const void* chunk) {
  Stream* st = (Stream*)data;
  const char* t = NULL;
  bool fin = false;
  if (litert_lm_stream_chunk_get_text(chunk, &t) == 0 && t) {
    char piece[4096];
    TextOf(t, piece, sizeof piece);
    size_t n = strlen(piece);
    if (st->len + n + 1 < sizeof st->text) {
      memcpy(st->text + st->len, piece, n + 1);
      st->len += n;
    }
  }
  st->chunks++;
  if (litert_lm_stream_chunk_is_final(chunk, &fin) == 0 && fin) st->final = 1;
}
// JSON string body of `in` (quotes, backslashes and control characters).
static char* JsonEscape(const char* in) {
  char* out = malloc(strlen(in) * 6 + 1);
  size_t n = 0;
  for (const unsigned char* c = (const unsigned char*)in; *c; c++) {
    if (*c == '"' || *c == '\\') {
      out[n++] = '\\';
      out[n++] = (char)*c;
    } else if (*c < 0x20) {
      n += (size_t)sprintf(out + n, "\\u%04x", *c);
    } else {
      out[n++] = (char)*c;
    }
  }
  out[n] = 0;
  return out;
}
static char* Base64File(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char* bytes = malloc((size_t)size);
  size_t got = fread(bytes, 1, (size_t)size, f);
  fclose(f);
  static const char* abc =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  char* out = malloc(((size_t)got + 2) / 3 * 4 + 1);
  size_t n = 0;
  for (size_t i = 0; i < got; i += 3) {
    unsigned v = bytes[i] << 16;
    if (i + 1 < got) v |= bytes[i + 1] << 8;
    if (i + 2 < got) v |= bytes[i + 2];
    out[n++] = abc[(v >> 18) & 63];
    out[n++] = abc[(v >> 12) & 63];
    out[n++] = i + 1 < got ? abc[(v >> 6) & 63] : '=';
    out[n++] = i + 2 < got ? abc[v & 63] : '=';
  }
  out[n] = 0;
  free(bytes);
  return out;
}
// One run of probe 1. `partial` is the stopped reply to rewind with: NULL to
// take this run's own (returned through `got_partial`).
static char* ConvRewindRun(P engine, const char* user_json, bool with_b,
                           const char* partial, char** got_partial,
                           size_t* decoded_step, int* fail) {
  Status s;
  P a = NewConversation(engine, NULL, false, false, 48);
  P b = with_b ? NewConversation(engine, NULL, false, false, 16) : NULL;
  Stream* st = calloc(1, sizeof(Stream));
  s = litert_lm_conversation_send_message_stream(a, user_json, NULL, NULL,
                                                 OnChunk, st);
  if (s != 0) {
    printf("RESULT convrewind_stream FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    (*fail)++;
    return NULL;
  }
  double t0 = Now();
  while (st->chunks < 6 && !st->final && Now() - t0 < 120) SleepMs(5);
  bool cancelled_mid = !st->final;
  litert_lm_conversation_cancel_process(a);
  if (with_b) {
    char* r = Send(b, "Name one planet. Answer with one word.", NULL, &s);
    char text[256] = "";
    if (r) TextOf(r, text, sizeof text);
    printf("INFO convrewind turn_on_b status=%d answer=\"%s\"\n", s, text);
    if (!r) (*fail)++;
    free(r);
  }
  // The rewind waits until A's stopped send has ended and its callbacks ran.
  const char* use = partial;
  char* esc_user_partial = NULL;
  // The step the cancelled decode reached, read once its final chunk is in:
  // the rewind reuses the KV positions its tokens match (section 24), and on
  // a GPU positions written by a decode are not bit-identical to the same
  // tokens prefilled, so only runs that stopped at the same step compare.
  {
    double t1 = Now();
    while (!st->final && Now() - t1 < 30) SleepMs(5);
    *decoded_step = 0;
    litert_lm_conversation_get_token_count(a, decoded_step);
  }
  if (!use || getenv("PROBE_WAIT_FINAL")) {
    double t1 = Now();
    while (!st->final && Now() - t1 < 30) SleepMs(5);
  }
  if (!use) {
    *got_partial = strdup(st->text);
    use = *got_partial;
  }
  esc_user_partial = JsonEscape(use);
  size_t cap = strlen(user_json) + strlen(esc_user_partial) + 128;
  char* exchange = malloc(cap);
  snprintf(exchange, cap,
           "[%s,{\"role\":\"assistant\",\"content\":[{\"type\":\"text\","
           "\"text\":\"%s\"}]}]",
           user_json, esc_user_partial);
  int end = -1;
  Status rs =
      litert_lm_conversation_rewind_cancelled_turn(a, exchange, NULL, NULL, &end);
  bool rewound = rs == 0 && end == 2;
  size_t count = 0;
  litert_lm_conversation_get_token_count(a, &count);
  printf("RESULT convrewind_rewind%s %s status=%d end=%s cancelled_mid=%d "
         "chunks=%d tokens=%zu\n", with_b ? "_with_b" : "",
         rewound ? "PASS" : "FAIL", rs, TurnEndName(end), cancelled_mid,
         st->chunks, count);
  if (!rewound) (*fail)++;
  free(exchange);
  free(esc_user_partial);
  char* r = Send(a, "In one short sentence, what were you just describing?",
                 NULL, &s);
  char* answer = NULL;
  if (r) {
    char text[2048];
    TextOf(r, text, sizeof text);
    answer = strdup(text);
    free(r);
  } else {
    printf("RESULT convrewind_follow_up FAIL status=%d err=%s\n", s,
           litert_lm_get_last_error_message());
    (*fail)++;
  }
  if (b) litert_lm_conversation_delete(b);
  litert_lm_conversation_delete(a);
  free(st);
  return answer;
}
static int CmdConvRewind(P engine, const char* image) {
  if (!litert_lm_conversation_rewind_cancelled_turn) {
    printf("RESULT convrewind FAIL library has no rewind_cancelled_turn\n");
    return 1;
  }
  const char* prompt =
      image ? "Describe this picture in great detail, object by object."
            : "Write a long story about a lighthouse keeper and a storm.";
  char* blob = image ? Base64File(image) : NULL;
  if (image && !blob) {
    printf("RESULT convrewind FAIL cannot read %s\n", image);
    return 1;
  }
  size_t cap = strlen(prompt) + (blob ? strlen(blob) : 0) + 128;
  char* user = malloc(cap);
  if (blob) {
    snprintf(user, cap,
             "{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"blob\":"
             "\"%s\"},{\"type\":\"text\",\"text\":\"%s\"}]}",
             blob, prompt);
  } else {
    snprintf(user, cap,
             "{\"role\":\"user\",\"content\":[{\"type\":\"text\","
             "\"text\":\"%s\"}]}",
             prompt);
  }
  int fail = 0;
  char* partial = NULL;
  // PROBE_PARTIAL forces the stopped reply every run rewinds with.
  const char* forced = getenv("PROBE_PARTIAL");
  size_t step_b = 0, step = 0, step_again = 0;
  char* with_b =
      ConvRewindRun(engine, user, true, forced, &partial, &step_b, &fail);
  if (forced) partial = strdup(forced);
  // Runs without B until one stops at B's step (at most 6), then one more at
  // that step for the repeat check.
  char* without_b = NULL;
  char* again = NULL;
  for (int i = 0; partial && i < 6 && !again; i++) {
    char* r = ConvRewindRun(engine, user, false, partial, NULL, &step, &fail);
    printf("INFO convrewind no_b_run=%d decoded_step=%zu (b: %zu)\n", i, step,
           step_b);
    if (step != step_b) {
      free(r);
    } else if (!without_b) {
      without_b = r;
    } else {
      again = r;
      step_again = step;
    }
  }
  if (!again) {
    printf("RESULT convrewind_same_step INFO no two runs without B stopped at "
           "B's step %zu\n", step_b);
  }
  (void)step_again;
  printf("INFO convrewind partial=\"%.120s\"\n", partial ? partial : "");
  if (partial) {
    // Control without any rewind: a new conversation whose history is the
    // same exchange, given as its preface. Its follow-up may differ in
    // rendering from a rewound one; reported, not checked.
    char* esc = JsonEscape(partial);
    size_t hcap = strlen(user) + strlen(esc) + 128;
    char* history = malloc(hcap);
    snprintf(history, hcap,
             "[%s,{\"role\":\"assistant\",\"content\":[{\"type\":\"text\","
             "\"text\":\"%s\"}]}]",
             user, esc);
    P cfg = NULL, conv = NULL;
    P sc = GreedySessionConfig(true, 48);
    CHECK(litert_lm_conversation_config_create(&cfg));
    CHECK(litert_lm_conversation_config_set_session_config(cfg, sc));
    CHECK(litert_lm_conversation_config_set_messages(cfg, history));
    CHECK(litert_lm_conversation_create(engine, cfg, &conv));
    litert_lm_conversation_config_delete(cfg);
    litert_lm_session_config_delete(sc);
    size_t pcount = 0;
    litert_lm_conversation_get_token_count(conv, &pcount);
    printf("INFO convrewind preface_control tokens=%zu\n", pcount);
    Status cs;
    char* r = Send(conv,
                   "In one short sentence, what were you just describing?",
                   NULL, &cs);
    char text[2048] = "";
    if (r) TextOf(r, text, sizeof text);
    printf("INFO convrewind preface_control status=%d answer=\"%s\"\n", cs,
           text);
    free(r);
    litert_lm_conversation_delete(conv);
    free(history);
    free(esc);
  }
  bool same = with_b && without_b && !strcmp(with_b, without_b);
  bool repeat = !again || (without_b && !strcmp(without_b, again));
  printf("RESULT convrewind_repeatable %s\n", repeat ? "PASS" : "FAIL");
  printf("RESULT convrewind_b_left_nothing %s with_b=\"%s\" without_b=\"%s\"\n",
         same ? "PASS" : "FAIL", with_b ? with_b : "", without_b ? without_b : "");
  fail += !same + !repeat;
  free(with_b);
  free(without_b);
  free(again);
  free(partial);
  free(user);
  free(blob);
  printf("RESULT convrewind%s %s %d check(s) failed\n", image ? "_image" : "",
         fail ? "FAIL" : "PASS", fail);
  return fail ? 1 : 0;
}

// Pre-tag probe 3: deleting one conversation while another generates. A
// streams a reply; after a few chunks B is deleted: (0) B idle with a
// history, (1) B with its own stream just cancelled and still winding down.
// A's reply must end with a final chunk and no error, equal (greedy) a run in
// which nothing is deleted, and A must answer a follow-up. Repeated
// PROBE_REPEAT times (default 3) per variant, for a crash or a hang.
static char* StreamAll(P conv, const char* text, P b_to_delete, bool b_busy,
                       int* fail) {
  char msg[512];
  snprintf(msg, sizeof msg,
           "{\"role\":\"user\",\"content\":[{\"type\":\"text\","
           "\"text\":\"%s\"}]}",
           text);
  Stream* st = calloc(1, sizeof(Stream));
  Stream* bst = NULL;
  if (b_to_delete && b_busy) {
    bst = calloc(1, sizeof(Stream));
    CHECK(litert_lm_conversation_send_message_stream(
        b_to_delete, msg, NULL, NULL, OnChunk, bst));
    double t0 = Now();
    while (bst->chunks < 2 && !bst->final && Now() - t0 < 60) SleepMs(2);
  }
  Status s = litert_lm_conversation_send_message_stream(conv, msg, NULL, NULL,
                                                        OnChunk, st);
  if (s != 0) {
    printf("RESULT deleteduring_stream FAIL status=%d\n", s);
    (*fail)++;
    free(st);
    free(bst);
    return NULL;
  }
  if (b_to_delete) {
    double t0 = Now();
    while (st->chunks < 4 && !st->final && Now() - t0 < 60) SleepMs(2);
    if (b_busy) litert_lm_conversation_cancel_process(b_to_delete);
    double t1 = Now();
    litert_lm_conversation_delete(b_to_delete);
    printf("INFO deleteduring delete took %.3fs, a at chunk %d final=%d\n",
           Now() - t1, st->chunks, st->final);
  }
  double t2 = Now();
  while (!st->final && Now() - t2 < 120) SleepMs(5);
  int end = -1, code = -1;
  litert_lm_conversation_get_last_turn_end(conv, &end, &code);
  bool ok = st->final && end != 3;
  if (!ok) {
    printf("RESULT deleteduring_a_ended FAIL final=%d end=%s code=%d\n",
           st->final, TurnEndName(end), code);
    (*fail)++;
  }
  char* text_out = strdup(st->text);
  free(st);
  free(bst);  // B's callbacks have ended: delete waits for them
  return text_out;
}
static int CmdDeleteDuring(P engine) {
  if (!litert_lm_conversation_get_last_turn_end) {
    printf("RESULT deleteduring FAIL library has no get_last_turn_end\n");
    return 1;
  }
  const char* prompt = "Count from 1 to 40, separated by commas.";
  int repeat = getenv("PROBE_REPEAT") ? atoi(getenv("PROBE_REPEAT")) : 3;
  int fail = 0;
  P c = NewConversation(engine, NULL, false, false, 64);
  char* control = StreamAll(c, prompt, NULL, false, &fail);
  litert_lm_conversation_delete(c);
  for (int variant = 0; variant < 2; variant++) {
    for (int i = 0; i < repeat; i++) {
      P a = NewConversation(engine, NULL, false, false, 64);
      P b = NewConversation(engine, NULL, false, false, 64);
      Status s;
      if (variant == 0) {
        char* r = Send(b, "My name is Bruno. Reply with the single word OK.",
                       NULL, &s);
        free(r);
      }
      char* got = StreamAll(a, prompt, b, variant == 1, &fail);
      bool same = got && control && !strcmp(got, control);
      char* r = Send(a, "Reply with the single word OK.", NULL, &s);
      printf("RESULT deleteduring_%s_%d %s same_as_control=%d follow_up=%d\n",
             variant == 0 ? "idle_b" : "busy_b", i,
             same && r ? "PASS" : "FAIL", same, r != NULL);
      if (!same || !r) {
        fail++;
        if (!same) {
          printf("INFO deleteduring got=\"%.200s\" control=\"%.200s\"\n",
                 got ? got : "", control ? control : "");
        }
      }
      free(r);
      free(got);
      litert_lm_conversation_delete(a);
    }
  }
  free(control);
  printf("RESULT deleteduring %s %d check(s) failed\n", fail ? "FAIL" : "PASS",
         fail);
  return fail ? 1 : 0;
}

// Sends one user message; returns a malloc'd copy of the response JSON.
static char* Send(P conv, const char* text, P optional_args, Status* status) {
  size_t cap = strlen(text) + 64;
  char* msg = malloc(cap);
  // `text` is ASCII without quotes or backslashes in every probe.
  snprintf(msg, cap, "{\"role\":\"user\",\"content\":\"%s\"}", text);
  P resp = NULL;
  *status = litert_lm_conversation_send_message(conv, msg, NULL, optional_args,
                                                &resp);
  free(msg);
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
// Pre-tag probe 2a: state carried between conversations of one engine. Four
// conversations in a row get the same prompt; then each on its own new
// engine. With no carried state all eight replies are equal (greedy).
static uint64_t OneReply(P engine, const char* prompt, char* out, size_t cap) {
  Status s;
  P conv = NewConversation(engine, NULL, false, false, 96);
  char* r = Send(conv, prompt, NULL, &s);
  out[0] = 0;
  if (r) TextOf(r, out, cap);
  free(r);
  litert_lm_conversation_delete(conv);
  return Fnv(out);
}
static int CmdXSession(P engine, const char* model, const char* backend) {
  const char* prompt =
      "Write one short paragraph about the ocean, about 80 words.";
  char text[8192];
  uint64_t same_engine[4], fresh[4];
  for (int i = 0; i < 4; i++) {
    same_engine[i] = OneReply(engine, prompt, text, sizeof text);
    printf("INFO xsession same_engine run=%d fnv=%016llx text=\"%.60s\"\n", i,
           (unsigned long long)same_engine[i], text);
  }
  for (int i = 0; i < 4; i++) {
    P e = NewEngine(model, backend, -1);
    fresh[i] = OneReply(e, prompt, text, sizeof text);
    litert_lm_engine_delete(e);
    printf("INFO xsession fresh_engine run=%d fnv=%016llx text=\"%.60s\"\n", i,
           (unsigned long long)fresh[i], text);
  }
  int fail = 0;
  for (int i = 1; i < 4; i++) fail += fresh[i] != fresh[0];
  printf("RESULT xsession_fresh_engines %s\n", fail ? "FAIL" : "PASS");
  int carried = 0;
  for (int i = 0; i < 4; i++) carried += same_engine[i] != fresh[0];
  printf("RESULT xsession_same_engine %s %d of 4 differ from a fresh engine\n",
         carried ? "FAIL" : "PASS", carried);
  // Two live conversations interleaved: X's second turn must not see Y's.
  const char* p1 = "Name three colors of the rainbow.";
  const char* p2 = "Now name two more.";
  char control[8192] = "", inter[8192] = "";
  Status s;
  {
    P x = NewConversation(engine, NULL, false, false, 48);
    char* r = Send(x, p1, NULL, &s);
    free(r);
    r = Send(x, p2, NULL, &s);
    if (r) TextOf(r, control, sizeof control);
    free(r);
    litert_lm_conversation_delete(x);
  }
  {
    P x = NewConversation(engine, NULL, false, false, 48);
    P y = NewConversation(engine, NULL, false, false, 48);
    char* r = Send(x, p1, NULL, &s);
    free(r);
    r = Send(y, "Write two sentences about mountains in winter.", NULL, &s);
    free(r);
    r = Send(x, p2, NULL, &s);
    if (r) TextOf(r, inter, sizeof inter);
    free(r);
    litert_lm_conversation_delete(y);
    litert_lm_conversation_delete(x);
  }
  bool same = control[0] && !strcmp(control, inter);
  printf("RESULT xsession_interleaved %s alone=\"%.80s\" interleaved=\"%.80s\"\n",
         same ? "PASS" : "FAIL", control, inter);
  return fail || carried || !same ? 1 : 0;
}

// One greedy turn, optionally with an image (argument 5; PROBE_VISION set),
// printing the reply: the smoke check that a model loads, tokenizes and
// answers. PASS = a non-empty reply.
static int CmdChat(P engine, const char* image) {
  const char* prompt = image ? "Describe this picture in one sentence."
                             : "What is the capital of France? Answer in one "
                               "short sentence.";
  char* blob = image ? Base64File(image) : NULL;
  size_t cap = strlen(prompt) + (blob ? strlen(blob) : 0) + 128;
  char* msg = malloc(cap);
  if (blob) {
    snprintf(msg, cap,
             "{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"blob\":"
             "\"%s\"},{\"type\":\"text\",\"text\":\"%s\"}]}",
             blob, prompt);
  } else {
    snprintf(msg, cap,
             "{\"role\":\"user\",\"content\":[{\"type\":\"text\","
             "\"text\":\"%s\"}]}",
             prompt);
  }
  P conv = NewConversation(engine, NULL, false, false, 64);
  P resp = NULL;
  double t0 = Now();
  Status s = litert_lm_conversation_send_message(conv, msg, NULL, NULL, &resp);
  double dt = Now() - t0;
  char text[4096] = "";
  if (s == 0) {
    const char* json = NULL;
    CHECK(litert_lm_json_response_get_string(resp, &json));
    TextOf(json ? json : "", text, sizeof text);
    if (getenv("PROBE_RAW")) printf("INFO chat raw=%.600s\n", json ? json : "");
    litert_lm_json_response_delete(resp);
  }
  bool ok = s == 0 && text[0];
  printf("RESULT chat%s %s status=%d %.2fs reply=\"%.200s\" err=%s\n",
         image ? "_image" : "", ok ? "PASS" : "FAIL", s, dt, text,
         s ? litert_lm_get_last_error_message() : "");
  litert_lm_conversation_delete(conv);
  free(msg);
  free(blob);
  return ok ? 0 : 1;
}

// NPU check: a conversation longer than the first context group. A states a
// code word, then grows past PROBE_CTX_FILL tokens (default 1100) with filler
// turns; B runs a turn, which makes the engine save A's context and restore
// it (section 22: every KV buffer, every group); A must still recall the
// code word. Prints the token count at each step.
static int CmdCtxGroup(P engine) {
  int fill = getenv("PROBE_CTX_FILL") ? atoi(getenv("PROBE_CTX_FILL")) : 1100;
  Status s;
  char* r;
  P a = NewConversation(engine, NULL, false, false, 16);
  P b = NewConversation(engine, NULL, false, false, 16);
  r = Send(a, "Remember this code word: PELICAN. Reply with the single word OK.",
           NULL, &s);
  free(r);
  size_t count = 0;
  litert_lm_conversation_get_token_count(a, &count);
  printf("INFO ctxgroup a after code word tokens=%zu\n", count);
  char* filler = Filler(400);
  for (int i = 0; i < 64 && (int)count < fill; i++) {
    char* msg = calloc(strlen(filler) + 64, 1);
    sprintf(msg, "%sReply with the single word OK.", filler);
    r = Send(a, msg, NULL, &s);
    free(msg);
    if (!r) {
      printf("RESULT ctxgroup_fill FAIL step=%d tokens=%zu status=%d err=%s\n",
             i, count, s, litert_lm_get_last_error_message());
      return 1;
    }
    free(r);
    litert_lm_conversation_get_token_count(a, &count);
  }
  free(filler);
  printf("INFO ctxgroup a filled tokens=%zu (target %d)\n", count, fill);
  r = Send(b, "Name one planet. Answer with one word.", NULL, &s);
  char text[512] = "";
  if (r) TextOf(r, text, sizeof text);
  printf("INFO ctxgroup b status=%d answer=\"%s\"\n", s, text);
  free(r);
  r = Send(a, "What was the code word I asked you to remember? Answer with "
              "the word only.", NULL, &s);
  text[0] = 0;
  if (r) TextOf(r, text, sizeof text);
  bool ok = r && strstr(text, "PELICAN") != NULL;
  printf("RESULT ctxgroup %s tokens=%zu answer=\"%s\" status=%d err=%s\n",
         ok ? "PASS" : "FAIL", count, text, s,
         r ? "" : litert_lm_get_last_error_message());
  free(r);
  litert_lm_conversation_delete(b);
  litert_lm_conversation_delete(a);
  return ok ? 0 : 1;
}

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
static char* ReadFile(const char* path, size_t* size) {
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
// One EmbeddingGemma 2 request of the given parts; prints the vector's shape.
static int Eg2Embed(P engine, P opts, const char* label, P* parts, size_t n) {
  P resp = NULL;
  double t0 = Now();
  Status s = litert_lm_embedding_engine_compute_embedding(engine, parts, n,
                                                          opts, &resp);
  if (s != 0) {
    printf("RESULT eg2_%s FAIL status=%d err=%s\n", label, s,
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
  bool ok = finite && dim > 0 && norm > 0.5 && norm < 2.0 && trunc <= 0;
  printf("RESULT eg2_%s %s dim=%zu input_length=%d truncated=%d norm=%.4f "
         "first=%.5f,%.5f embed=%.3fs\n",
         label, ok ? "PASS" : "FAIL", dim, in_len, trunc, norm,
         v ? v[0] : NAN, v && dim > 1 ? v[1] : NAN, dt);
  litert_lm_embedding_response_delete(resp);
  return ok ? 0 : 1;
}
// EmbeddingGemma 2: text, and with PROBE_EG2_IMAGE / PROBE_EG2_AUDIO an image,
// an audio clip and the three combined in one request, with the towers on
// the CPU as the Dart pass names them. With PROBE_CACHE_DIR, lists the cache
// files the engine wrote (the names requireWeightCache checks).
static int CmdEg2(const char* model, const char* backend) {
  P settings = NULL, engine = NULL, opts = NULL;
  const char* image_path = getenv("PROBE_EG2_IMAGE");
  const char* audio_path = getenv("PROBE_EG2_AUDIO");
  // As the Dart pass: on the NPU the vision tower follows the bundle (no
  // backend named) and the audio tower runs on the CPU; elsewhere both towers
  // are named cpu.
  bool npu = !strcmp(backend, "npu");
  CHECK(litert_lm_embedding_engine_settings_create(
      model, backend, image_path && !npu ? "cpu" : NULL,
      audio_path ? "cpu" : NULL, &settings));
  if (g_dispatch_dir) {
    CHECK(litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir(
        settings, g_dispatch_dir));
    CHECK(litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir(
        settings, g_dispatch_dir));
    CHECK(litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir(
        settings, g_dispatch_dir));
  }
  CHECK(litert_lm_embedding_engine_settings_set_max_input_length(settings,
                                                                 1024));
  if (image_path) {
    CHECK(litert_lm_embedding_engine_settings_set_vision_tokens_per_image(
        settings, 140));
  }
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
  int fail = 0;
  const char* text = "task: search result | query: how do plants make food";
  P text_part = NULL, image_part = NULL, audio_part = NULL;
  CHECK(litert_lm_input_data_create(0, text, strlen(text), &text_part));
  fail += Eg2Embed(engine, opts, "text", &text_part, 1);
  size_t size = 0;
  char* bytes;
  if (image_path && (bytes = ReadFile(image_path, &size))) {
    CHECK(litert_lm_input_data_create(1, bytes, size, &image_part));
    free(bytes);
    fail += Eg2Embed(engine, opts, "image", &image_part, 1);
  }
  if (audio_path && (bytes = ReadFile(audio_path, &size))) {
    CHECK(litert_lm_input_data_create(3, bytes, size, &audio_part));
    free(bytes);
    fail += Eg2Embed(engine, opts, "audio", &audio_part, 1);
  }
  if (image_part || audio_part) {
    P parts[3];
    size_t n = 0;
    parts[n++] = text_part;
    if (image_part) parts[n++] = image_part;
    if (audio_part) parts[n++] = audio_part;
    fail += Eg2Embed(engine, opts, "combined", parts, n);
  }
  if (image_part) litert_lm_input_data_delete(image_part);
  if (audio_part) litert_lm_input_data_delete(audio_part);
  litert_lm_input_data_delete(text_part);
  litert_lm_embedding_options_delete(opts);
  litert_lm_embedding_engine_delete(engine);
  litert_lm_embedding_engine_settings_delete(settings);
#if !defined(_WIN32)
  if (g_cache_dir) {
    char cmd[2048];
    snprintf(cmd, sizeof cmd,
             "ls -l '%s' | awk 'NR>1 {print \"INFO eg2_cache_file \" $5 \" \" $9}'",
             g_cache_dir);
    fflush(stdout);
    if (system(cmd) != 0) printf("INFO eg2_cache_file listing failed\n");
  }
#endif
  printf("RESULT eg2 %s %d check(s) failed\n", fail ? "FAIL" : "PASS", fail);
  return fail ? 1 : 0;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr,
            "usage: %s <libLiteRtLm> <multiconv|constrained|rewind|scoring|"
            "mtp-off|mtp-on|mtp-adaptive|mtp-default|tools|longprompt|determinism|"
            "turnend|prefillroom|convrewind [image]|deleteduring|xsession|chat [image]|ctxgroup|eg2> "
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
  else if (!strcmp(cmd, "turnend")) rc = CmdTurnEnd(engine);
  else if (!strcmp(cmd, "prefillroom")) rc = CmdPrefillRoom(engine);
  else if (!strcmp(cmd, "deleteduring")) rc = CmdDeleteDuring(engine);
  else if (!strcmp(cmd, "xsession")) rc = CmdXSession(engine, model, backend);
  else if (!strcmp(cmd, "chat")) rc = CmdChat(engine, argc > 5 ? argv[5] : NULL);
  else if (!strcmp(cmd, "ctxgroup")) rc = CmdCtxGroup(engine);
  else if (!strcmp(cmd, "convrewind"))
    rc = CmdConvRewind(engine, argc > 5 ? argv[5] : NULL);
  else {
    fprintf(stderr, "unknown command %s\n", cmd);
    rc = 64;
  }
  litert_lm_engine_delete(engine);
  return rc;
}
