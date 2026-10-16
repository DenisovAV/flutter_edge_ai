import 'dart:convert';

/// Pure-Dart extractor for LiteRT-LM SDK JSON response chunks.
///
/// Lives in core, not in flutter_edge_ai_litertlm's native `lib/src/ffi/`, so
/// the web `@litert-lm/core` path can reuse the exact same text-extraction
/// logic that the native FFI path uses — both inputs are the same OpenAI Chat
/// Completions chunk JSON shape produced by `liblitert_lm` and
/// `@litert-lm/core` respectively.
///
/// Handles these response formats:
/// - Text: `{"role":"assistant","content":[{"type":"text","text":"hello"}]}`
///   → returns `"hello"`
/// - Thinking: `{"role":"assistant","channels":{"thought":"reasoning..."}}`
///   → returns `<|channel>thought\nreasoning...<channel|>`
///   (compatible with `ThinkingFilter` in `core/extensions.dart`)
/// - An object without content, a tool call
///   (`{"role":"assistant","tool_calls":[...]}`) included → returns the
///   chunk's JSON unchanged.
/// - A content list keeps only its text parts, so `[]` gives `""`.
///
/// Text that is not JSON passes through. JSON that is not an object, or a
/// content of another type, throws: that is a contract change with LiteRT-LM.
class SdkTextExtractor {
  /// Extract text from a LiteRT-LM JSON response chunk.
  ///
  /// Partial / non-JSON chunks pass through verbatim. This is the only
  /// shape we are permissive about — any other parse error (TypeError,
  /// RangeError, etc.) signals a real contract change with LiteRT-LM and
  /// must surface, not be silently swallowed.
  static String extractTextFromResponse(String jsonStr) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(jsonStr) as Map<String, dynamic>;
    } on FormatException {
      return jsonStr;
    }

    final channels = json['channels'] as Map<String, dynamic>?;
    if (channels != null) {
      final thought = channels['thought'] as String?;
      if (thought != null && thought.isNotEmpty) {
        return '<|channel>thought\n$thought<channel|>';
      }
    }

    // The web SDK can represent a text message as a plain string, while the
    // native SDK normally uses the multimodal content-item array. Keep the
    // two supported shapes explicit: an unexpected shape signals a contract
    // change with LiteRT-LM and must not be silently passed into the chat.
    switch (json['content']) {
      case final String text:
        return text;
      case null:
        return jsonStr;
      case final List<Object?> parts:
        final buffer = StringBuffer();
        for (final part in parts) {
          if (part case {'type': 'text', 'text': final String text}) {
            buffer.write(text);
          }
        }
        return buffer.toString();
      case final other:
        throw StateError(
          'LiteRT-LM response content is ${other.runtimeType}, '
          'not a string or a list of parts: $jsonStr',
        );
    }
  }
}

/// Whether [token] is one LiteRT-LM chunk that carries tool calls and no text:
/// what [SdkTextExtractor.extractTextFromResponse] returns for a call. Gemma 4
/// can write a sentence and then call a tool in the same generation; the call
/// then arrives as a chunk of its own, after the text. `InferenceChat` takes
/// such a chunk out of the text when it handles calls; otherwise the call stays
/// visible as JSON. Assumes one session token is one LiteRT-LM chunk, as the
/// FFI and web sessions deliver them. An empty `tool_calls` list is no call.
///
/// Internal to core: `engine.dart` exports only [SdkTextExtractor].
bool isSdkToolCallChunk(String token) {
  final trimmed = token.trim();
  if (!trimmed.startsWith('{')) return false;
  final Object? json;
  try {
    json = jsonDecode(trimmed);
  } on FormatException {
    return false;
  }
  return json is Map<String, dynamic> &&
      json['tool_calls'] is List &&
      (json['tool_calls'] as List).isNotEmpty &&
      json['content'] == null;
}
