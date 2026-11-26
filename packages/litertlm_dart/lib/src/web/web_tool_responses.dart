// A tool response on the web, where the page's `@litert-lm/core` answers
// a `role: 'tool'` message with nothing more often than not.
//
// Measured with Gemma 4 E2B's GPU export (`gemma-4-E2B-it-gpu.litertlm`,
// revision cccc664e) in Chrome 158 on 2026-11-26, one tool and the prompt
// "Make the background purple.": after the turn that called the tool, the
// `role: 'tool'` message holding its result got no text (the history then
// ends with an empty assistant entry; 0.21.0-nightly.20261125 ends the turn
// with `finish_reason: "stop"`) under greedy decoding and on 5 of 8 seeds of
// the family sampler (temperature 1, top-k 64, top-p 0.95) on 0.20.0 and on
// the nightly; with constrained decoding on too. 0.19.0 answered it under
// greedy decoding, and got no text on 3 of the 8 seeds. The same result
// sent as user text, `Tool <name> returned: <JSON>` (with or without a
// call id), got a reply on all 8 seeds and under greedy decoding on all
// three versions (seed 1 calls the tool again). So on a runtime from 0.20.0
// on a tool message is sent as one user message of that text; on an older
// one it stays a tool message. No version is known to answer the tool
// message reliably: when one is measured to, it bounds the rule from
// above.
//
// Pure Dart, so the rule and the text are tested on the VM;
// web_conversation_handle.dart applies them.
library;

import 'dart:convert';

import 'web_runtime_version.dart';

/// The first `@litert-lm/core` version whose tool results go as user text:
/// 0.20.0, the first measured to answer a tool message with no text under
/// greedy decoding and on most sampler seeds (2026-11-26).
const webToolMessageEmptySince = (0, 20, 0);

/// Whether a tool response goes to the page's `@litert-lm/core` as user
/// text ([webToolResponseAsUserText]) rather than as a `role: 'tool'`
/// message. [pageVersions] are the versions the page fetched the runtime
/// by (`liteRtLmWebFetchedVersions()`): with none (a self-hosted or bundled
/// runtime) it is taken to be [liteRtLmWebRuntimeVersion], the one this
/// release is written for. True when any of them is
/// [webToolMessageEmptySince] or later, its prerelease (a nightly) counted
/// as its version; false when every one is older.
bool webToolResponsesAsUserText(Set<String> pageVersions) {
  final versions = pageVersions.isEmpty
      ? {liteRtLmWebRuntimeVersion}
      : pageVersions;
  return versions.any((version) {
    final core = _core.firstMatch(version);
    // The page's resources name it, but not as X.Y.Z: taken as the pin.
    if (core == null) return true;
    final parsed = [for (var i = 1; i <= 3; i++) int.parse(core.group(i)!)];
    final (major, minor, patch) = webToolMessageEmptySince;
    for (final (got, since) in [
      (parsed[0], major),
      (parsed[1], minor),
      (parsed[2], patch),
    ]) {
      if (got != since) return got > since;
    }
    return true;
  });
}

final _core = RegExp(r'^(\d+)\.(\d+)\.(\d+)');

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
