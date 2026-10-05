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

    final content = json['content'] as List<dynamic>?;
    if (content == null) return jsonStr;
    final buffer = StringBuffer();
    for (final item in content) {
      if (item is Map<String, dynamic> && item['type'] == 'text') {
        buffer.write(item['text'] as String? ?? '');
      }
    }
    return buffer.toString();
  }
}
