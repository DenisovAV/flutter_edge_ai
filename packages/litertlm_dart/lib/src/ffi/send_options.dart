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
/// no-repeat n-gram, the tool choice, the output cap, the visual token budget
/// and the suppressed tokens, each only when given, so a
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
  // As Swift's `makeOptionalArgs` (Conversation.swift) sets both, and
  // Kotlin passes its `maxOutputToken` per message (Conversation.kt).
  if (options.maxOutputTokens case final cap?) {
    set(
      'litert_lm_conversation_optional_args_set_max_output_tokens',
      b.litert_lm_conversation_optional_args_set_max_output_tokens(
        optionalArgs,
        cap,
      ),
    );
  }
  if (options.visualTokenBudget case final budget?) {
    set(
      'litert_lm_conversation_optional_args_set_visual_token_budget',
      b.litert_lm_conversation_optional_args_set_visual_token_budget(
        optionalArgs,
        budget,
      ),
    );
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

/// Sets a speculative decoding config's fields, each only when given: a mode
/// left null is not set, so a conversation's config inherits the engine's
/// mode, and an engine's keeps the runtime's (off), as Swift's
/// `makeCSpeculativeDecodingConfig` (Engine.swift) leaves it.
void applySpeculativeDecodingFields(
  LiteRtLmBindings b,
  Pointer<LiteRtLmSpeculativeDecodingConfig> config, {
  required int? mode,
  required double? lenience,
}) {
  void set(String name, int code) =>
      checkLiteRtLmSetter(name, code, b.lastError);
  if (mode != null) {
    set(
      'litert_lm_speculative_decoding_config_set_mode',
      b.litert_lm_speculative_decoding_config_set_mode(
        config,
        LiteRtLmSpeculativeDecodingMode.fromValue(mode),
      ),
    );
  }
  if (lenience != null) {
    set(
      'litert_lm_speculative_decoding_config_set_lenience',
      b.litert_lm_speculative_decoding_config_set_lenience(config, lenience),
    );
  }
}

/// Sets the conversation extras Swift's `Engine.createConversation`
/// (Engine.swift) sets on its conversation config: the chat template
/// (`ConversationConfig.chatTemplate`) and tool call streaming
/// (`ConversationConfig.enableToolCallStreaming`, with Swift's channel name
/// [toolCallStreamingChannel]); each only when asked, so a conversation
/// without them reaches native as before.
void applyConversationExtras(
  LiteRtLmBindings b,
  Pointer<LiteRtLmConversationConfig> config,
  ConversationExtras extras,
) {
  void set(String name, int code) =>
      checkLiteRtLmSetter(name, code, b.lastError);
  if (extras.chatTemplate case final template?) {
    final text = template.toNativeUtf8(allocator: calloc);
    try {
      set(
        'litert_lm_conversation_config_set_prompt_template',
        b.litert_lm_conversation_config_set_prompt_template(
          config,
          text.cast(),
        ),
      );
    } finally {
      calloc.free(text);
    }
  }
  if (extras.streamToolCalls) {
    final channel = toolCallStreamingChannel.toNativeUtf8(allocator: calloc);
    try {
      set(
        'litert_lm_conversation_config_set_stream_tool_calls',
        b.litert_lm_conversation_config_set_stream_tool_calls(
          config,
          true,
          channel.cast(),
        ),
      );
    } finally {
      calloc.free(channel);
    }
  }
}
