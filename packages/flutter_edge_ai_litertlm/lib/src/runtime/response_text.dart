// The text of one LiteRT-LM response chunk. A copy of core's
// `SdkTextExtractor.extractTextFromResponse`, which the web engine shares; the
// runtime cannot import core, so test/runtime/response_text_test.dart holds
// the two equal on every chunk shape.

import 'dart:convert';

/// The text of the LiteRT-LM JSON response chunk [jsonStr]: a thought as
/// `<|channel>thought\n…<channel|>`, a string `content` as it is, the `text`
/// parts of a content list joined, and anything that is not JSON as it came.
/// A `content` of any other type is a contract change and throws
/// [StateError].
String extractResponseText(String jsonStr) {
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
