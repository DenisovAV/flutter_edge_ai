// Declarations patch_c_api.sh adds to LiteRT-LM's C API: sections 2 and 3
// (engine settings) in `c/engine.h`, sections 16 and 23 (the stopped-turn
// rewind and the turn-end record) in `c/conversation.h`. Copied from the
// patched tree at LiteRT-LM 771b06e1 (v0.19.0); section 14's two response
// getters stay in `c/embedding_engine.h`, as before. The bindings are
// generated from upstream's headers plus this one, so `include/c/` stays
// upstream's own and a pin bump that makes one of these upstream's shows.
//
// Not compiled into anything: ffigen reads it (ffigen.yaml).

#ifndef FLUTTER_EDGE_AI_LITERT_LM_PATCHES_H_
#define FLUTTER_EDGE_AI_LITERT_LM_PATCHES_H_

#include "c/conversation.h"
#include "c/engine.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Sets whether to use hardware masking for NPU. Default is true which on
// Intel LunarLake/PantherLake preview silicon causes engine_create to
// crash because the NPU HW mask update path is not fully supported.
// Pass false to force CPU/SIMD mask update fallback.
LITERT_LM_C_API_EXPORT
LiteRtLmStatusCode litert_lm_engine_settings_set_use_hw_masking_for_npu(
    LiteRtLmEngineSettings* settings, bool value);

// Lowers the GPU inference context priority (OpenCL kLow) so on-device GPU
// prefill/decode does not starve the host UI compositor (#364). GPU-only;
// a no-op on backends whose delegate ignores context priority.
LITERT_LM_C_API_EXPORT
LiteRtLmStatusCode litert_lm_engine_settings_set_gpu_context_low_priority(
    LiteRtLmEngineSettings* settings, bool value);

// Hints a GPU kernel batch size so the delegate periodically flushes, giving
// the UI compositor scheduling windows during long GPU work (#364).
LITERT_LM_C_API_EXPORT
LiteRtLmStatusCode litert_lm_engine_settings_set_kernel_batch_size(
    LiteRtLmEngineSettings* settings, int kernel_batch_size);

// flutter_edge_ai (patch_c_api.sh section 16): how the last send on a
// conversation ended.
typedef enum {
  kLiteRtLmTurnEndNone = 0,       // nothing was sent, or it was rewound
  kLiteRtLmTurnEndCompleted = 1,  // the reply ended by itself
  kLiteRtLmTurnEndCancelled = 2,  // cancelled; the conversation is poisoned
  kLiteRtLmTurnEndFailed = 3,     // ended with an error
  kLiteRtLmTurnEndRunning = 4,    // had not ended when the wait timed out
  // flutter_edge_ai (patch_c_api.sh section 23): the ends that section 16
  // reported as "completed" or "failed".
  kLiteRtLmTurnEndOutputLimit = 5,   // the reply reached max_output_tokens
  kLiteRtLmTurnEndContextLimit = 6,  // the decode filled the context window
                                     // (max_num_tokens); the reply is cut
  kLiteRtLmTurnEndContextFull = 7,   // the input did not fit what the context
                                     // window has left (or the window has no
                                     // room for any prefill): it is not in the
                                     // history, and the conversation fails
                                     // until rewind_cancelled_turn
  kLiteRtLmTurnEndRefused = 8,  // the last send was refused before it started
                                // (a NULL argument or a message that is not
                                // JSON): nothing ran and the conversation is
                                // as the send before it left it
} LiteRtLmTurnEnd;

// flutter_edge_ai (patch_c_api.sh section 23). How the last send on
// `conversation` ended, as a LiteRtLmTurnEnd, with the absl status code it
// ended with (0 unless it is kLiteRtLmTurnEndFailed or
// kLiteRtLmTurnEndContextFull). It is settled before that send's final
// callback runs: read it after the final chunk, or after send_message
// returns. While a send runs it is kLiteRtLmTurnEndRunning. A send refused
// before it starts is kLiteRtLmTurnEndRefused with its status code, so a
// caller never reads the end of the send before it. Either out pointer may be
// NULL.
LITERT_LM_C_API_EXPORT
LiteRtLmStatusCode litert_lm_conversation_get_last_turn_end(
    LiteRtLmConversation* conversation, int* out_turn_end,
    int* out_status_code);

// flutter_edge_ai (patch_c_api.sh section 16). Makes a conversation whose last
// send was stopped usable again, without deleting it. It cancels whatever of
// that send still runs and waits, up to 10 minutes, until every task of the
// conversation has ended and its callbacks have run; never call it from a
// stream callback. Then, by how the last send ended:
// - none, completed, output limit or context limit: nothing changes;
// - context full: the conversation is rewound to just before that send's own
//   prefill (its input was never prefilled: `messages_json` is ignored);
// - cancelled: the conversation is rewound to just before that send's own
//   prefill, which also undoes the poisoning, and when `messages_json` is not
//   NULL those messages (a JSON array, for example the stopped message and the
//   part of the reply that was produced) are prefilled without generating and
//   added to the history;
// - failed or still running: the conversation must be deleted.
// `extra_context` and `optional_args` (both may be NULL) are what the stopped
// send was given. `out_last_turn_end` (may be NULL) receives the
// LiteRtLmTurnEnd seen after the wait.
//
// Returns kLiteRtLmStatusOk when the conversation can be used, otherwise
// another LiteRtLmStatusCode with the last error set, and the conversation
// must be deleted.
LITERT_LM_C_API_EXPORT
LiteRtLmStatusCode litert_lm_conversation_rewind_cancelled_turn(
    LiteRtLmConversation* conversation, const char* messages_json,
    const char* extra_context,
    const LiteRtLmConversationOptionalArgs* optional_args,
    int* out_last_turn_end);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // FLUTTER_EDGE_AI_LITERT_LM_PATCHES_H_
