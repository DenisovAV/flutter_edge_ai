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

/// [message], a message of the conversation API JSON, as the user message
/// sent in its place when it is a tool response: a `role: 'tool'` message,
/// or a message of any role holding a `tool_response` part (as
/// `Conversation` takes it). Each `tool_response` part becomes the text
/// line [webToolResponseText] (a part without a `response` is written as
/// `null`, as `Content.toolResponse(name, null)` sends it); every other part
/// (text, an image, audio) is kept, in order, with neighbouring text joined
/// into one text part, one line each. A tool message whose content is not a
/// list of parts keeps that content under the user role. Null when
/// [message] is no tool response: it is sent as it is. No message goes to
/// the runtime as `role: 'tool'`.
Map<String, Object?>? webToolResponseAsUserText(Map<String, Object?> message) {
  final content = message['content'];
  final parts = content is List<Object?> ? content : null;
  final hasResponse =
      parts?.any((part) => part is Map && part['type'] == 'tool_response') ??
      false;
  if (message['role'] != 'tool' && !hasResponse) return null;
  if (parts == null) {
    return {...message, 'role': 'user', 'content': content ?? <Object?>[]};
  }
  final converted = <Object?>[];
  final lines = <String>[];
  void flush() {
    if (lines.isEmpty) return;
    converted.add({'type': 'text', 'text': lines.join('\n')});
    lines.clear();
  }

  for (final part in parts) {
    switch (part) {
      case {'type': 'tool_response'}:
        final map = part as Map;
        final name = map['name'];
        final id = map['id'];
        lines.add(
          webToolResponseText(
            name is String ? name : jsonEncode(name),
            map['response'],
            id: id is String ? id : null,
          ),
        );
      case {'type': 'text', 'text': final String text}:
        lines.add(text);
      default:
        flush();
        converted.add(part);
    }
  }
  flush();
  return {...message, 'role': 'user', 'content': converted};
}
