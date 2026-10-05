import 'dart:convert';

import 'package:flutter_gemma/core/model_response.dart';
import 'package:flutter_gemma/core/tool.dart';

import 'function_gemma_format.dart';
import 'function_gemma_wire.dart';

/// Parser for LiteRT-LM SDK Chat Completions JSON responses.
///
/// Used by [InferenceChat] when the active session backend exposes
/// `lastRawResponse` (FFI/LiteRT-LM path with structured `tool_calls`).
/// The SDK already converts native `<|tool_call>...<tool_call|>` Gemma 4
/// tokens into OpenAI-style JSON via `chat_template.jinja` + minja, so this
/// helper just walks the JSON and surfaces [FunctionCallResponse]s.
///
/// Parsing rules mirror upstream Python `Conversation._handle_tool_calls`
/// (`python/litert_lm/conversation.py`).
class SdkResponseParser {
  /// Extract all function calls from an SDK response JSON string.
  ///
  /// Accepts the structural variants observed in the wild:
  /// 1. Top-level `tool_calls` list (Gemma 4 standard path).
  /// 2. `content` array entries with `type: "tool_call"` (multimodal).
  /// 3. Concatenated multi-document JSON — when the model emits two or more
  ///    `<|tool_call>...<tool_call|>` blocks, the SDK serializes them as
  ///    separate `{role:assistant,tool_calls:[...]}{role:assistant,tool_calls:[...]}`
  ///    documents back-to-back rather than wrapping them in an array. We split
  ///    on top-level `}{` boundaries and parse each fragment.
  ///
  /// Each call element may be either OpenAI-style
  /// (`{type: "function", function: {name, arguments}}`) or flat
  /// (`{name, arguments}`) — both accepted.
  ///
  /// String values inside `arguments` (and nested maps/lists) are stripped of
  /// the `<|"|>` Gemma 4 escape token, which leaks through SDK parsing.
  static List<FunctionCallResponse> extractToolCalls(String jsonStr) {
    final result = <FunctionCallResponse>[];
    for (final fragment in _splitConcatenatedJson(jsonStr)) {
      final Map<String, dynamic> json;
      try {
        final parsed = jsonDecode(fragment);
        if (parsed is! Map<String, dynamic>) continue;
        json = parsed;
      } on FormatException {
        continue;
      }
      _harvestCalls(json, result);
    }
    // Web fallback: `@litert-lm/core` (0.12.1 / 0.14.0) does NOT convert Gemma 4
    // `<|tool_call>call:NAME{...}<tool_call|>` tokens into structured
    // `tool_calls` JSON — they stay as raw text (verified with Gemma 4 E4B on
    // web). Native (C++ liblitert_lm) does convert, so this only fires when the
    // structured pass found nothing but raw tokens are present.
    if (result.isEmpty && jsonStr.contains(_rawToolCallOpen)) {
      _harvestRawTokenCalls(jsonStr, result);
    }
    // FunctionGemma, same reason: when its call comes back as text rather than
    // `tool_calls` — the web SDK, or a `.litertlm` exported without the
    // function_gemma model type, whose runtime creates no tool-call channel —
    // parse the wire format the model wrote.
    if (result.isEmpty && jsonStr.contains(functionGemmaStartCall)) {
      result.addAll(FunctionGemmaCallFormat().parseAll(_responseText(jsonStr)));
    }
    return result;
  }

  /// The text a raw response carries: the `content` string or text items of
  /// every concatenated fragment, or [jsonStr] itself when none of it is JSON.
  static String _responseText(String jsonStr) {
    final text = StringBuffer();
    var parsedAny = false;
    for (final fragment in _splitConcatenatedJson(jsonStr)) {
      final Object? parsed;
      try {
        parsed = jsonDecode(fragment);
      } on FormatException {
        continue;
      }
      if (parsed is! Map<String, dynamic>) continue;
      parsedAny = true;
      final content = parsed['content'];
      if (content is String) text.write(content);
      if (content is List) {
        for (final item in content) {
          if (item is Map && item['type'] == 'text' && item['text'] is String) {
            text.write(item['text']);
          }
        }
      }
    }
    return parsedAny ? text.toString() : jsonStr;
  }

  static const _rawToolCallOpen = '<|tool_call>';

  /// Parse the raw Gemma 4 tool-call token stream the web SDK leaves untouched:
  /// `<|tool_call>call:NAME{key:<|"|>value<|"|>,...}<tool_call|>`. The closing
  /// `<tool_call|>` may be cut off by the stop token, so it's optional. Values
  /// are wrapped in `<|"|>...<|"|>` escape tokens (stripped here).
  static void _harvestRawTokenCalls(
    String text,
    List<FunctionCallResponse> out,
  ) {
    final callRegex = RegExp(
      r'<\|tool_call>call:([\w-]+)\{(.*?)\}(?:<tool_call\|>|$)',
      dotAll: true,
    );
    // The `<|"|>` escape may arrive raw or JSON-escaped as `<|\"|>` (web
    // stringifies the Message object, so the quote inside the content string
    // gets a backslash). Accept an optional backslash before the quote.
    final paramRegex = RegExp(
      r'([\w-]+):<\|\\?"\|>(.*?)<\|\\?"\|>',
      dotAll: true,
    );
    for (final match in callRegex.allMatches(text)) {
      final name = match.group(1)!;
      final paramsStr = match.group(2)!;
      final args = <String, dynamic>{};
      for (final p in paramRegex.allMatches(paramsStr)) {
        args[p.group(1)!] = p.group(2)!;
      }
      out.add(FunctionCallResponse(name: name, args: args));
    }
  }

  /// Split a string that may be one JSON object or a concatenation of multiple
  /// top-level objects (e.g. `{...}{...}`). Tracks brace depth while ignoring
  /// braces inside string literals so it doesn't false-cut on `"a{b}"`.
  static Iterable<String> _splitConcatenatedJson(String input) sync* {
    int depth = 0;
    int start = -1;
    bool inString = false;
    bool escape = false;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == r'\') {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0 && start >= 0) {
          yield input.substring(start, i + 1);
          start = -1;
        }
      }
    }
  }

  static void _harvestCalls(
    Map<String, dynamic> json,
    List<FunctionCallResponse> out,
  ) {
    void addFromCallObject(Object? raw) {
      if (raw is! Map<String, dynamic>) return;
      Map<String, dynamic>? fn;
      if (raw['type'] == 'function' &&
          raw['function'] is Map<String, dynamic>) {
        fn = raw['function'] as Map<String, dynamic>;
      } else if (raw['name'] is String) {
        fn = raw;
      }
      if (fn == null) return;
      final name = fn['name'] as String?;
      if (name == null) return;
      final rawArgs = fn['arguments'];
      final args = rawArgs is Map<String, dynamic>
          ? _stripEscapeTokens(rawArgs) as Map<String, dynamic>
          : <String, dynamic>{};
      out.add(FunctionCallResponse(name: name, args: args));
    }

    final topLevel = json['tool_calls'] as List<dynamic>?;
    if (topLevel != null) {
      for (final call in topLevel) {
        addFromCallObject(call);
      }
    }

    // `content` is a List for the multimodal tool_call shape, but a plain
    // String on the web path (a stringified Message) — guard the cast so the
    // raw-token fallback downstream still gets a chance to run.
    final content = json['content'];
    if (content is List<dynamic>) {
      for (final item in content) {
        if (item is Map<String, dynamic> && item['type'] == 'tool_call') {
          addFromCallObject(item['tool_call']);
        }
      }
    }
  }

  /// Recursively strip Gemma 4 `<|"|>` escape tokens from string values.
  ///
  /// Workaround for an SDK quirk observed on macOS GPU 2026-04-29 where
  /// minja-rendered escape tokens leak into the parsed `arguments` map (e.g.
  /// `"<|\"|>red<|\"|>"` instead of `"red"`). Walks Maps and Lists so nested
  /// argument values are also cleaned.
  static dynamic _stripEscapeTokens(dynamic value) {
    if (value is String) return value.replaceAll('<|"|>', '');
    if (value is Map) {
      return value.map((k, v) => MapEntry(k as String, _stripEscapeTokens(v)));
    }
    if (value is List) return value.map(_stripEscapeTokens).toList();
    return value;
  }

  /// Clean a raw SDK response JSON string by recursively stripping
  /// `<|"|>` escape tokens. Used by `chat.dart` before writing the
  /// assistant turn into chat history — without this the next request
  /// echoes the escape tokens back to the model and Gemma 4 starts
  /// reproducing them in subsequent `tool_calls` arguments (#248).
  ///
  /// Returns the cleaned JSON string, or the input unchanged if it isn't
  /// valid JSON (the caller falls back to writing the raw string in that
  /// case).
  static String cleanRawForHistory(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      return jsonEncode(_stripEscapeTokens(decoded));
    } on FormatException {
      return rawJson;
    }
  }

  /// Serialize [tools] into the OpenAI Chat Completions JSON format that
  /// LiteRT-LM SDK expects in `litert_lm_conversation_config_set_tools`.
  /// SDK then applies `chat_template.jinja` (via minja) to render native
  /// Gemma 4 `<|tool>declaration:...<tool|>` tokens.
  ///
  /// Reference: upstream `c/engine_test.cc::CreateConversationConfigWithTools`.
  static String serializeToolsForSdk(List<Tool> tools) => jsonEncode([
    for (final tool in tools)
      {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
      },
  ]);

  /// Build the role-`tool` message that returns a turn's tool results to the
  /// model. One message carries every result, so a model that made parallel
  /// calls reads all of their answers before it continues. The item shape
  /// mirrors upstream Python `Conversation._handle_tool_calls`
  /// (`{"type": "tool_response", "name", "response"}`), which the Gemma 4 and
  /// FunctionGemma data processors format natively — as
  /// `<|tool_response>response:NAME{...}<tool_response|>` and
  /// `<start_function_response>response:NAME{...}<end_function_response>`.
  ///
  /// It has to be role `tool`. Sent as a user message, the template opens a new
  /// user turn and then a new model turn, and FunctionGemma answers that by
  /// calling the same function again instead of reading the result.
  static String buildToolResponsesJson(
    List<({String name, Object? response})> responses,
  ) => jsonEncode({
    'role': 'tool',
    'content': [
      for (final r in responses)
        {'type': 'tool_response', 'name': r.name, 'response': r.response},
    ],
  });

  /// The `response` object for a tool result carried in `Message.text`, which
  /// `Message.toolResponse` fills with the JSON-encoded map. The runtime formats
  /// an object as `NAME{key:value,...}`; anything else — a hand-built message
  /// holding plain text — goes under `value`, the key FunctionGemma's template
  /// uses for a scalar response.
  static Map<String, Object?> toolResponsePayload(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'value': decoded};
    } on FormatException {
      return {'value': text};
    }
  }
}
