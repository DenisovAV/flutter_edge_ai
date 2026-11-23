// The tool calls of a raw LiteRT-LM reply and the assistant message a
// rebuilt conversation replays for it. Shared by the native conversation
// handles (ffi/conversation_handles.dart) and the web one
// (web/web_conversation_handle.dart), so a stopped turn is kept the same way
// on both.

import 'dart:convert';

import '../api/message.dart' show messageFromJson;
import 'runtime_log.dart';

/// The tool calls in a raw LiteRT-LM reply: each call's name and arguments.
/// Reading them is chat-template knowledge (a model can write a call as
/// text), which the caller owns; the Flutter adapter passes core's parser.
typedef ToolCallReader =
    List<({String name, Map<String, Object?> arguments})> Function(
      String rawReply,
    );

/// The calls native converted itself: the `tool_calls` of every JSON object
/// in [rawReply] (a streamed reply is several, concatenated). A call the model
/// wrote as text stays text, as the native conversation keeps it.
List<({String name, Map<String, Object?> arguments})> nativeToolCalls(
  String rawReply,
) => [
  for (final message in concatenatedJsonObjects(rawReply)) ..._callsIn(message),
];

/// The calls of one reply object; one this release cannot read has none (the
/// turn's text is replayed instead, as native keeps an unconverted call).
List<({String name, Map<String, Object?> arguments})> _callsIn(
  Map<String, Object?> message,
) {
  try {
    return [
      for (final call in messageFromJson(message).toolCalls)
        (name: call.name, arguments: call.arguments),
    ];
  } on FormatException {
    return const [];
  } on StateError {
    return const [];
  }
}

/// The JSON objects of [text], a run of concatenated JSON values; anything
/// that is not an object, or not JSON, is skipped.
Iterable<Map<String, Object?>> concatenatedJsonObjects(String text) sync* {
  var depth = 0, start = -1;
  var inString = false, escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B) {
      if (depth++ == 0) start = i;
    } else if (c == 0x7D && depth > 0 && --depth == 0) {
      try {
        if (jsonDecode(text.substring(start, i + 1))
            case final Map<String, Object?> object) {
          yield object;
        }
      } on FormatException {
        // Not JSON after all: skipped.
      }
    }
  }
}

/// The assistant turn to replay: its tool calls when it made any, so the
/// tool results recorded after it still answer something, and its text
/// otherwise, also when [toolCallsOf] throws (which is logged).
Map<String, Object?> assistantTurnMessage(
  ToolCallReader toolCallsOf,
  String text,
  String raw,
) {
  List<({String name, Map<String, Object?> arguments})> calls;
  try {
    calls = toolCallsOf(raw);
  } catch (e) {
    // A reader that throws must not keep a turn from ending (it runs in the
    // turn's cleanup): the reply is kept as its text, and that is said.
    runtimeLog(
      '[litertlm_dart] could not read the tool calls of a reply ($e); its '
      'text is kept',
    );
    calls = const [];
  }
  if (calls.isEmpty) {
    return {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    };
  }
  return {
    'role': 'assistant',
    'tool_calls': [
      for (final call in calls)
        {
          'type': 'function',
          'function': {'name': call.name, 'arguments': call.arguments},
        },
    ],
  };
}
