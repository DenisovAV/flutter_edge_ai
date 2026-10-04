import 'dart:convert';

/// Pure-Dart extractor for LiteRT-LM SDK JSON response chunks.
///
/// Lives outside `lib/core/ffi/` so the web `@litert-lm/core` path can
/// reuse the exact same text-extraction logic that the native FFI path
/// uses — both inputs are the same OpenAI Chat Completions chunk JSON
/// shape produced by `liblitert_lm` and `@litert-lm/core` respectively.
///
/// Handles two response formats:
/// - Text: `{"role":"assistant","content":[{"type":"text","text":"hello"}]}`
///   → returns `"hello"`
/// - Thinking: `{"role":"assistant","channels":{"thought":"reasoning..."}}`
///   → returns `<|channel>thought\nreasoning...<channel|>`
///   (compatible with `ThinkingFilter` in `core/extensions.dart`)
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
