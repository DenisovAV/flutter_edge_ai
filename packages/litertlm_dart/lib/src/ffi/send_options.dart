// What a conversation and a send carry to native beyond the message: the
// decoding constraint, the per-message optional args, and the conversation's
// own extras. Internal: `Conversation` builds them from the public configs.

import 'dart:ffi';

import 'package:ffi/ffi.dart' show StringUtf8Pointer, calloc;

import '../runtime/send_options.dart';
import 'litert_lm_bindings.dart';
import 'litert_lm_client.dart' show LiteRtLmLastErrorRead;
import 'litert_lm_status.dart';

export '../runtime/send_options.dart';

/// Sets one send's [options] on [optionalArgs]: the repetition penalty, the
/// no-repeat n-gram and the suppressed tokens, each only when given, so a
/// send without them reaches LiteRT-LM exactly as before. The args keep a
/// copy of each config, which is deleted here.
void applySendOptions(
  LiteRtLmBindings b,
  Pointer<LiteRtLmConversationOptionalArgs> optionalArgs,
  SendOptions options,
) {
  void set(String name, int code) =>
      checkLiteRtLmSetter(name, code, b.lastError);
  final penalty = options.repetitionPenalty;
  if (penalty != null) {
    final config = createLiteRtLm(
      'litert_lm_repetition_penalty_config_create',
      b.litert_lm_repetition_penalty_config_create,
      b.lastError,
    );
    try {
      if (penalty.repetitionPenalty case final v?) {
        set(
          'litert_lm_repetition_penalty_config_set_repetition_penalty',
          b.litert_lm_repetition_penalty_config_set_repetition_penalty(
            config,
            v,
          ),
        );
      }
      if (penalty.presencePenalty case final v?) {
        set(
          'litert_lm_repetition_penalty_config_set_presence_penalty',
          b.litert_lm_repetition_penalty_config_set_presence_penalty(config, v),
        );
      }
      if (penalty.frequencyPenalty case final v?) {
        set(
          'litert_lm_repetition_penalty_config_set_frequency_penalty',
          b.litert_lm_repetition_penalty_config_set_frequency_penalty(
            config,
            v,
          ),
        );
      }
      if (penalty.windowSize case final v?) {
        set(
          'litert_lm_repetition_penalty_config_set_window_size',
          b.litert_lm_repetition_penalty_config_set_window_size(config, v),
        );
      }
      set(
        'litert_lm_conversation_optional_args_set_repetition_penalty_config',
        b.litert_lm_conversation_optional_args_set_repetition_penalty_config(
          optionalArgs,
          config,
        ),
      );
    } finally {
      b.litert_lm_repetition_penalty_config_delete(config);
    }
  }
  final ngram = options.noRepeatNgram;
  if (ngram != null) {
    final config = createLiteRtLm(
      'litert_lm_no_repeat_ngram_config_create',
      b.litert_lm_no_repeat_ngram_config_create,
      b.lastError,
    );
    try {
      if (ngram.noRepeatNgramSize case final v?) {
        set(
          'litert_lm_no_repeat_ngram_config_set_no_repeat_ngram_size',
          b.litert_lm_no_repeat_ngram_config_set_no_repeat_ngram_size(
            config,
            v,
          ),
        );
      }
      if (ngram.windowSize case final v?) {
        set(
          'litert_lm_no_repeat_ngram_config_set_window_size',
          b.litert_lm_no_repeat_ngram_config_set_window_size(config, v),
        );
      }
      set(
        'litert_lm_conversation_optional_args_set_no_repeat_ngram_config',
        b.litert_lm_conversation_optional_args_set_no_repeat_ngram_config(
          optionalArgs,
          config,
        ),
      );
    } finally {
      b.litert_lm_no_repeat_ngram_config_delete(config);
    }
  }
  final toolChoice = options.toolChoiceJson;
  if (toolChoice != null) {
    final json = toolChoice.toNativeUtf8(allocator: calloc);
    try {
      set(
        'litert_lm_conversation_optional_args_set_tool_choice',
        b.litert_lm_conversation_optional_args_set_tool_choice(
          optionalArgs,
          json.cast(),
        ),
      );
    } finally {
      calloc.free(json);
    }
  }
  final suppress = options.suppressTokens;
  if (suppress != null) {
    final config = createLiteRtLm(
      'litert_lm_suppress_tokens_config_create',
      b.litert_lm_suppress_tokens_config_create,
      b.lastError,
    );
    final ids = calloc<Int>(suppress.isEmpty ? 1 : suppress.length);
    try {
      for (var i = 0; i < suppress.length; i++) {
        ids[i] = suppress[i];
      }
      set(
        'litert_lm_suppress_tokens_config_set_suppress_tokens',
        b.litert_lm_suppress_tokens_config_set_suppress_tokens(
          config,
          ids,
          suppress.length,
        ),
      );
      set(
        'litert_lm_conversation_optional_args_set_suppress_tokens_config',
        b.litert_lm_conversation_optional_args_set_suppress_tokens_config(
          optionalArgs,
          config,
        ),
      );
    } finally {
      calloc.free(ids);
      b.litert_lm_suppress_tokens_config_delete(config);
    }
  }
}
