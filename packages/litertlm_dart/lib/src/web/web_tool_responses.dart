// A tool response on the web: the page's `@litert-lm/core` gets a turn's
// tool results as one user message of text, never as a `role: 'tool'`
// message.
//
// Measured with Gemma 4 E2B's GPU export (`gemma-4-E2B-it-gpu.litertlm`,
// revision cccc664e) in Chrome 158 on 2026-11-26, one tool and the prompt
// "Make the background purple.", over 8 seeds of the family sampler
// (temperature 1, top-k 64, top-p 0.95) and greedy decoding: after the turn
// that called the tool, the `role: 'tool'` message holding its result got
// no text (the history then ends with an empty assistant entry;
// 0.21.0-nightly.20261125 ends the turn with `finish_reason: "stop"`) on 5
// of 8 seeds and under greedy decoding on 0.20.0 and on the nightly, and on
// 3 of 8 seeds on 0.19.0 (which answered under greedy decoding). The same
// result sent as user text, `Tool <name> returned: <JSON>` (with or without
// a call id), got a reply on all 8 seeds and under greedy decoding on all
// three versions (seed 1 calls the tool again). No runtime this release
// drives answers the tool message reliably, and a version gate would have
// nothing to keep it for: a runtime older than 0.20.0 lacks members this
// release calls (`Engine.createSession`, `Conversation.clone`) and is
// refused before any message is sent.
//
// Pure Dart, so the text is tested on the VM;
// web_conversation_handle.dart applies it to every tool message.
library;

import 'dart:convert';

/// The text one tool response goes as: `Tool <name> returned: <JSON>`, the
/// form answered on 0.19.0, 0.20.0 and the nightly; with a call [id],
/// `Tool <name> (call <id>) returned: <JSON>`. [response] is written as
/// JSON, a string one quoted.
String webToolResponseText(String name, Object? response, {String? id}) =>
    'Tool $name${id == null || id.isEmpty ? '' : ' (call $id)'} returned: '
    '${jsonEncode(response)}';

/// [message], a `role: 'tool'` message of the conversation API JSON, as the
/// user message sent in its place: one text part holding each
/// `tool_response` part as [webToolResponseText] and each text part as is,
/// one per line, in their order. Null when [message] is not a tool message
/// with a list of parts, or holds a part that is neither: it is then sent as
/// it is, never rewritten in part.
Map<String, Object?>? webToolResponseAsUserText(Map<String, Object?> message) {
  if (message['role'] != 'tool') return null;
  final lines = <String>[];
  switch (message['content']) {
    case final List<Object?> parts:
      for (final part in parts) {
        switch (part) {
          case {
            'type': 'tool_response',
            'name': final String name,
            'response': final response,
          }:
            final id = (part as Map)['id'];
            lines.add(
              webToolResponseText(name, response, id: id is String ? id : null),
            );
          case {'type': 'text', 'text': final String text}:
            lines.add(text);
          default:
            return null;
        }
      }
    default:
      return null;
  }
  if (lines.isEmpty) return null;
  return {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': lines.join('\n')},
    ],
  };
}
