// What a conversation and a send carry beyond the message: the decoding
// constraint, the per-message optional args, and the conversation's own
// extras. Internal: `Conversation` builds them from the public configs. No
// dart:ffi: the web arm reads them too (ffi/send_options.dart applies them
// natively).

import 'dart:convert' show jsonEncode;

import 'package:meta/meta.dart' show immutable;

import '../api/backend.dart' show SpeculativeDecodingConfig;
import '../api/config.dart' show NoRepeatNgramConfig, RepetitionPenaltyConfig;
import '../ffi/thinking_context.dart';

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
    this.unconstrained = false,
    this.toolChoiceJson,
  });

  /// Template variables for this message, merged under the thinking switch.
  final Map<String, Object?> extraContext;
  final RepetitionPenaltyConfig? repetitionPenalty;
  final NoRepeatNgramConfig? noRepeatNgram;
  final List<int>? suppressTokens;

  /// The thinking budget of this send; null leaves the engine's.
  final int? thinkingTokenBudget;

  /// This send goes without the conversation's response format: a message
  /// that is not a tool response while automatic tools are pending, as in
  /// Kotlin's and Swift's `resolveResponseFormat`.
  final bool unconstrained;

  /// This send's tool choice as the C API's JSON (tool_choice_json.dart);
  /// null leaves the model's default.
  final String? toolChoiceJson;

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
  final SpeculativeDecodingConfig? speculativeDecoding;

  static const none = ConversationExtras();
}

/// The per-send `extra_context` JSON: [extra] with the thinking switch of
/// [thinkingContext] on top, so a template variable cannot turn thinking on
/// or off behind the caller's back.
String sendExtraContext(bool enableThinking, Map<String, Object?>? extra) =>
    extra == null || extra.isEmpty
    ? jsonEncode(thinkingContext(enableThinking))
    : jsonEncode({...extra, ...thinkingContext(enableThinking)});
