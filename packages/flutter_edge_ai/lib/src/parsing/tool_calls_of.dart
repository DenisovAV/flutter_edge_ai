import 'dart:convert';

import 'package:flutter_edge_ai/src/message.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_response.dart';

import 'function_call_format_factory.dart';
import 'sdk_response_parser.dart';

/// The calls a [MessageType.toolCall] message carries, for an engine that
/// replays a history.
///
/// [Message.toolCalls] when the message has them. Otherwise [Message.text] is
/// parsed, so a history saved before those fields existed still replays. The
/// text has had these shapes:
/// - `{"tool_calls": [...]}` — the canonical form, and the raw LiteRT-LM
///   response `InferenceChat` stored (also several such objects back to back);
/// - `{"name": ..., "parameters": {...}}` or a JSON list of them — the genai
///   and Genkit converters;
/// - the model's own words — native Gemma 4 or FunctionGemma tokens, or a
///   JSON, Qwen, DeepSeek, Phi or Llama function-call block.
///
/// Each call may be OpenAI-style (`{"function": {"name", "arguments"}}`) or
/// flat, with its arguments under `arguments`, `parameters` or `args`, as an
/// object or a JSON string; missing or blank arguments are `{}`. An `id` is
/// kept. One JSON document of calls is read whole: when one of its calls
/// cannot be read (arguments that are not an object), none is returned, so a
/// replay does not answer part of that turn. The model-format fallbacks read
/// call by call. Returns an empty list for any other message type or when
/// nothing parses, a toolCall message included: the engine then replays its
/// [Message.text]. A web Gemma 4 call recorded as text has lost the escape
/// tokens that mark its string arguments, so from text alone it reads with
/// none; its [Message.toolCalls] keep the arguments. One model turn may be several
/// consecutive toolCall messages; an engine that replays calls merges them.
List<FunctionCallResponse> toolCallsOf(Message message) {
  if (message.type != MessageType.toolCall) return const [];
  if (message.toolCalls.isNotEmpty) return message.toolCalls;
  return List.unmodifiable(_parseToolCallText(message.text));
}

List<FunctionCallResponse> _parseToolCallText(String text) {
  if (text.trim().isEmpty) return const [];
  final structured = _structuredCalls(text);
  if (structured != null) return structured;
  // Native tokens the web SDK leaves as text, and FunctionGemma's wire format.
  final sdk = SdkResponseParser.extractToolCalls(text);
  if (sdk.isNotEmpty) return sdk;
  // A text-path call: the model's own block, in whichever format it used.
  for (final type in const [
    ModelType.deepSeek,
    ModelType.phi,
    ModelType.qwen,
    ModelType.general,
    ModelType.llama,
  ]) {
    try {
      final calls = FunctionCallFormatFactory.create(type).parseAll(text);
      if (calls.isNotEmpty) return calls;
    } on Object {
      continue;
    }
  }
  return const [];
}

/// One JSON document: the canonical object, a list of calls, or one call.
/// Null when [text] is none of these, which leaves it to the fallbacks
/// (several documents, the multimodal `content` shape, text around the JSON).
/// A document of calls is final, read or not: a fallback would read a call it
/// cannot represent with its arguments dropped.
List<FunctionCallResponse>? _structuredCalls(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is List) return _wholeTurn(json);
  if (json is! Map) return null;
  final toolCalls = json['tool_calls'];
  if (toolCalls is List) return _wholeTurn(toolCalls);
  return _wholeTurn([json]);
}

/// Every call of [items], or none when one of them cannot be read. Null when
/// no item names a function: [items] is then not a list of calls.
List<FunctionCallResponse>? _wholeTurn(List<Object?> items) {
  if (!items.any(_namesFunction)) return null;
  final calls = [for (final item in items) _call(item)];
  return calls.contains(null) ? const [] : calls.nonNulls.toList();
}

/// Whether [raw] is a call object: a name, flat or under `function`.
bool _namesFunction(Object? raw) {
  if (raw is! Map) return false;
  final function = raw['function'] is Map ? raw['function'] as Map : raw;
  return function['name'] is String;
}

FunctionCallResponse? _call(Object? raw) {
  if (raw is! Map) return null;
  final function = raw['function'] is Map ? raw['function'] as Map : raw;
  final name = function['name'];
  if (name is! String || name.isEmpty) return null;
  final args = _arguments(
    function['arguments'] ?? function['parameters'] ?? function['args'],
  );
  if (args == null) return null;
  final id = raw['id'] ?? function['id'];
  return FunctionCallResponse(
    name: name,
    args: args,
    id: id is String && id.isNotEmpty ? id : null,
  );
}

Map<String, dynamic>? _arguments(Object? raw) {
  if (raw == null) return <String, dynamic>{};
  if (raw is String) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      return _arguments(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}
