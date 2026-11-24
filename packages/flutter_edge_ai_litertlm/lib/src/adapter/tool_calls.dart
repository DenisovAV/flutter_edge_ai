// The tool calls of a raw reply read with core's parser, which the native and
// the web engine hand litertlm_dart for a rebuilt conversation's replay.

import 'package:flutter_edge_ai/engine.dart' show SdkResponseParser;

/// The tool calls of a raw LiteRT-LM reply, read with core's parser: the
/// calls native converted, and a call the model wrote as text (FunctionGemma's
/// `<start_function_call>`, a raw Gemma 4 `<|tool_call>` block native did not
/// convert). A replayed history keeps them as calls, so the tool results
/// after them still answer something.
List<({String name, Map<String, Object?> arguments})> liteRtLmToolCallsOf(
  String rawReply,
) => [
  for (final call in SdkResponseParser.extractToolCalls(rawReply))
    (name: call.name, arguments: call.args),
];
