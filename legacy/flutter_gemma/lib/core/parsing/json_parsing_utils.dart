import 'dart:convert';

import 'package:flutter_gemma/core/model_response.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Shared JSON parsing utilities used by multiple format implementations.
class JsonParsingUtils {
  /// Remove model response wrappers (Gemma turn markers).
  static String cleanModelResponse(String response) {
    final turnRegex = RegExp(r'<start_of_turn>model\s*([\s\S]*?)<end_of_turn>');
    if (turnRegex.hasMatch(response)) {
      return turnRegex.firstMatch(response)!.group(1)!.trim();
    }
    return response.replaceAll(RegExp(r'<end_of_turn>\s*$'), '').trim();
  }

  /// Parse JSON string into FunctionCallResponse.
  /// Supports key names: "parameters", "args", "arguments".
  static FunctionCallResponse? parseJsonString(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);

      if (decoded is Map<String, dynamic>) {
        final name = decoded['name'] as String?;
        if (name == null) {
          gemmaLog('JsonParsingUtils: JSON missing "name" field');
          return null;
        }

        // Try all known key names for arguments
        final args =
            (decoded['parameters'] as Map<String, dynamic>?) ??
            (decoded['args'] as Map<String, dynamic>?) ??
            (decoded['arguments'] as Map<String, dynamic>?);

        // Use empty map for zero-argument functions (get_time, refresh, etc.)
        final resolvedArgs = args ?? <String, dynamic>{};
        gemmaLog(
          'JsonParsingUtils: Parsed function: $name($resolvedArgs)',
          level: GemmaLogLevel.verbose,
        );
        return FunctionCallResponse(name: name, args: resolvedArgs);
      }

      gemmaLog('JsonParsingUtils: JSON missing "name" field or not a Map');
      return null;
    } catch (e) {
      gemmaLog('JsonParsingUtils: Failed to decode JSON: $e');
      return null;
    }
  }

  /// Parse a JSON array of function calls.
  /// Returns all successfully parsed calls.
  static List<FunctionCallResponse> parseJsonArray(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        final results = <FunctionCallResponse>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final result = parseJsonString(jsonEncode(item));
            if (result != null) results.add(result);
          }
        }
        return results;
      }
    } catch (e) {
      gemmaLog('JsonParsingUtils: Failed to decode JSON array: $e');
    }
    return [];
  }

  /// Split text containing multiple JSON objects separated by newlines or commas.
  /// Handles: `{...}\n{...}`, `{...}, {...}`, and mixed.
  static List<FunctionCallResponse> parseMultipleJsonObjects(String text) {
    final results = <FunctionCallResponse>[];
    final trimmed = text.trim();

    // First try as JSON array: [{...}, {...}]
    if (trimmed.startsWith('[')) {
      final arrayResults = parseJsonArray(trimmed);
      if (arrayResults.isNotEmpty) return arrayResults;
    }

    // Split by top-level JSON objects using brace tracking
    int braceCount = 0;
    bool inString = false;
    bool escaped = false;
    int objectStart = -1;

    for (int i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];

      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == '\\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          if (braceCount == 0) objectStart = i;
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0 && objectStart >= 0) {
            final jsonStr = trimmed.substring(objectStart, i + 1);
            final result = parseJsonString(jsonStr);
            if (result != null) results.add(result);
            objectStart = -1;
          }
        }
      }
    }

    return results;
  }

  /// Fast check for balanced braces without full JSON parsing.
  static bool isBalancedJson(String str) {
    int braceCount = 0;
    bool inString = false;
    bool escaped = false;
    bool hasSeenOpenBrace = false;

    for (int i = 0; i < str.length; i++) {
      final char = str[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          braceCount++;
          hasSeenOpenBrace = true;
        } else if (char == '}') {
          braceCount--;
          if (braceCount < 0) return false;
        }
      }
    }

    return braceCount == 0 && hasSeenOpenBrace;
  }

  /// Check if text is definitely plain text (not a function call).
  /// Shared heuristic for JSON-based formats.
  static bool isDefinitelyText(
    String buffer, {
    List<String> extraIndicators = const [],
  }) {
    final clean = buffer.trim();
    if (clean.length < 5) return false;

    final early = clean.length > 30 ? clean.substring(0, 30) : clean;
    if (early.contains('{') ||
        early.toLowerCase().contains('json') ||
        early.contains('<tool')) {
      return false;
    }
    for (final indicator in extraIndicators) {
      if (early.contains(indicator)) return false;
    }
    return true;
  }
}
