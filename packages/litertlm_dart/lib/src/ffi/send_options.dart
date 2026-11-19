// What a conversation and a send carry to native beyond the message: the
// decoding constraint, the per-message optional args, and the conversation's
// own extras. Internal: `Conversation` builds them from the public configs.

import 'dart:convert' show jsonEncode;
import 'dart:ffi';

import 'package:ffi/ffi.dart' show calloc;
import 'package:meta/meta.dart' show immutable;

import '../api/backend.dart' show SpeculativeDecodingMode;
import '../api/config.dart' show NoRepeatNgramConfig, RepetitionPenaltyConfig;
import 'litert_lm_bindings.dart';
import 'litert_lm_client.dart' show LiteRtLmLastErrorRead;
import 'litert_lm_status.dart';
import 'thinking_context.dart';

/// The LLGuidance constraint of a conversation: a JSON Schema or a regex.
@immutable
final class Constraint {
  const Constraint.jsonSchema(this.text) : regex = false;
  const Constraint.regex(this.text) : regex = true;

  /// The schema (JSON) or the pattern.
  final String text;

  /// Whether [text] is a regex rather than a JSON Schema.
  final bool regex;

  @override
  bool operator ==(Object other) =>
      other is Constraint && other.text == text && other.regex == regex;

  @override
  int get hashCode => Object.hash(text, regex);
}

/// One send's optional args beyond thinking and the constraint.
@immutable
final class SendOptions {
  const SendOptions({
    this.extraContext = const {},
    this.repetitionPenalty,
    this.noRepeatNgram,
    this.suppressTokens,
    this.thinkingTokenBudget,
  });

  /// Template variables for this message, merged under the thinking switch.
  final Map<String, Object?> extraContext;
  final RepetitionPenaltyConfig? repetitionPenalty;
  final NoRepeatNgramConfig? noRepeatNgram;
  final List<int>? suppressTokens;

  /// The thinking budget of this send; null leaves the engine's.
  final int? thinkingTokenBudget;

  static const none = SendOptions();
}

/// A conversation's extras beyond what every conversation is created with.
@immutable
final class ConversationExtras {
  const ConversationExtras({
    this.extraContext = const {},
    this.speculativeDecoding,
  });

  /// `conversation_config_set_extra_context`; empty sets nothing.
  final Map<String, Object?> extraContext;

  /// The session's speculative decoding; null leaves the engine's.
  final SpeculativeDecodingMode? speculativeDecoding;

  static const none = ConversationExtras();
}

/// The per-send `extra_context` JSON: [extra] with the thinking switch of
/// [thinkingContext] on top, so a template variable cannot turn thinking on
/// or off behind the caller's back.
String sendExtraContext(bool enableThinking, Map<String, Object?>? extra) =>
    extra == null || extra.isEmpty
    ? jsonEncode(thinkingContext(enableThinking))
    : jsonEncode({...extra, ...thinkingContext(enableThinking)});

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
