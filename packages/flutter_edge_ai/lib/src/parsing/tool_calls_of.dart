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
/// flat, with its arguments under `arguments` or `parameters`, as an object or
/// a JSON string; missing or blank arguments are `{}`. An `id` is kept. Returns
/// an empty list for any other message type or when nothing parses.
List<FunctionCallResponse> toolCallsOf(Message message) {
  if (message.type != MessageType.toolCall) return const [];
  if (message.toolCalls.isNotEmpty) return message.toolCalls;
  return List.unmodifiable(_parseToolCallText(message.text));
}

List<FunctionCallResponse> _parseToolCallText(String text) {
  if (text.trim().isEmpty) return const [];
  final structured = _structuredCalls(text);
  if (structured.isNotEmpty) return structured;
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
/// Anything else (several documents, the multimodal `content` shape, text
/// around the JSON) is left to the fallbacks, which read those too.
List<FunctionCallResponse> _structuredCalls(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (json is List) return [for (final item in json) ?_call(item)];
  if (json is! Map) return const [];
  final toolCalls = json['tool_calls'];
  if (toolCalls is List) return [for (final item in toolCalls) ?_call(item)];
  final single = _call(json);
  return single == null ? const [] : [single];
}

FunctionCallResponse? _call(Object? raw) {
  if (raw is! Map) return null;
  final function = raw['function'] is Map ? raw['function'] as Map : raw;
  final name = function['name'];
  if (name is! String || name.isEmpty) return null;
  final args = _arguments(function['arguments'] ?? function['parameters']);
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
