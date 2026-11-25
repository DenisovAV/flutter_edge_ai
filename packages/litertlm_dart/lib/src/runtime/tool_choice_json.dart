// A message's ToolChoice as the JSON LiteRT-LM's C API takes
// (`litert_lm_conversation_optional_args_set_tool_choice`, C API 1.1: OpenAI's
// Chat Completions tool_choice), checked against the conversation first. No
// dart:ffi: the web arm refuses what this returns.

import 'dart:convert' show jsonEncode;

import '../api/config.dart';

/// [choice] for a message of a conversation whose tools are [toolNames], as
/// the C API's JSON; null for no choice or [ToolChoice.auto], which is what
/// native does without one, so such a send reaches it exactly as before.
///
/// An [ArgumentError] for a choice other than auto in a conversation with no
/// tools or with a response format ([hasResponseFormat]; native would ignore
/// it there), a forced function or allowed tools that name no tool or one the
/// conversation does not have, and an empty list of allowed tools.
String? toolChoiceJson(
  ToolChoice? choice, {
  required List<String> toolNames,
  required bool hasResponseFormat,
}) {
  if (choice == null || choice is ToolChoiceAuto) return null;
  if (toolNames.isEmpty) {
    throw ArgumentError.value(
      choice,
      'toolChoice',
      'needs a conversation with tools (ConversationConfig.tools)',
    );
  }
  if (hasResponseFormat) {
    throw ArgumentError.value(
      choice,
      'toolChoice',
      'cannot be combined with the conversation\'s response format',
    );
  }
  void known(String name) {
    if (name.isEmpty) {
      throw ArgumentError.value(choice, 'toolChoice', 'names an empty tool');
    }
    if (!toolNames.contains(name)) {
      throw ArgumentError.value(
        choice,
        'toolChoice',
        'names $name, which is not one of the conversation\'s tools '
            '(${toolNames.join(', ')})',
      );
    }
  }

  Map<String, Object?> function(String name) => {
    'type': 'function',
    'function': {'name': name},
  };
  return switch (choice) {
    ToolChoiceAuto() => null,
    ToolChoiceNone() => jsonEncode('none'),
    ToolChoiceRequired() => jsonEncode('required'),
    ToolChoiceForcedFunction(:final name) => () {
      known(name);
      return jsonEncode(function(name));
    }(),
    ToolChoiceAllowedTools(:final names, :final required) => () {
      if (names.isEmpty) {
        throw ArgumentError.value(
          choice,
          'toolChoice',
          'allows no tool: name at least one',
        );
      }
      names.forEach(known);
      return jsonEncode({
        'type': 'allowed_tools',
        'allowed_tools': {
          'mode': required ? 'required' : 'auto',
          'tools': [for (final name in names) function(name)],
        },
      });
    }(),
  };
}
