import 'package:flutter_gemma/core/model_response.dart';

import 'function_call_format.dart';
import 'json_parsing_utils.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// JSON-based function call format (default).
///
/// Supports:
/// - `<tool_code>JSON</tool_code>` (XML-style)
/// - ` ```tool_code\nJSON\n``` ` (Gemma 3 markdown)
/// - ` ```json\nJSON\n``` ` (markdown)
/// - ` ```\nJSON\n``` ` (generic markdown)
/// - Direct JSON: `{"name": "...", "parameters": {...}}`
///
/// Used by: gemmaIt, hammer, general, and as default fallback.
class JsonFunctionCallFormat extends FunctionCallFormat {
  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    return clean.startsWith('{') ||
        clean.startsWith('```') ||
        clean.startsWith('<tool_code>');
  }

  @override
  bool isDefinitelyText(String buffer) {
    return JsonParsingUtils.isDefinitelyText(buffer);
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    if (clean.startsWith('{') && clean.endsWith('}')) {
      return JsonParsingUtils.isBalancedJson(clean);
    }
    if (clean.contains('```json') && clean.endsWith('```')) return true;
    if (clean.contains('```tool_code') && clean.endsWith('```')) return true;
    if (clean.contains('<tool_code>') && clean.contains('</tool_code>')) {
      return true;
    }
    return false;
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;
    final content = JsonParsingUtils.cleanModelResponse(text);

    return _parseToolCodeXmlBlock(content) ??
        _parseToolCodeMarkdownBlock(content) ??
        _parseMarkdownBlock(content) ??
        _parseDirectJson(content);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return [];
    final content = JsonParsingUtils.cleanModelResponse(text);
    final results = <FunctionCallResponse>[];

    // Try XML tool_code blocks (multiple)
    final xmlRegex = RegExp(
      r'<tool_code>\s*([\s\S]*?)\s*</tool_code>',
      multiLine: true,
    );
    for (final match in xmlRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    // Try markdown tool_code blocks
    final mdToolCodeRegex = RegExp(
      r'```tool_code\s*([\s\S]*?)\s*```',
      multiLine: true,
    );
    for (final match in mdToolCodeRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    // Try markdown json blocks
    final mdJsonRegex = RegExp(r'```json\s*([\s\S]*?)\s*```', multiLine: true);
    for (final match in mdJsonRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    // Try splitting multiple JSON objects (newline or comma-separated)
    final multiResults = JsonParsingUtils.parseMultipleJsonObjects(content);
    if (multiResults.isNotEmpty) return multiResults;

    return [];
  }

  /// Parse `<tool_code>JSON</tool_code>` format.
  FunctionCallResponse? _parseToolCodeXmlBlock(String content) {
    final regex = RegExp(
      r'<tool_code>\s*([\s\S]*?)\s*</tool_code>',
      multiLine: true,
    );
    final match = regex.firstMatch(content);

    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      gemmaLog(
        'JsonFormat: Found tool_code XML block: $jsonStr',
        level: GemmaLogLevel.verbose,
      );
      return JsonParsingUtils.parseJsonString(jsonStr);
    }
    return null;
  }

  /// Parse ` ```tool_code\nJSON\n``` ` format (Gemma 3).
  FunctionCallResponse? _parseToolCodeMarkdownBlock(String content) {
    final regex = RegExp(r'```tool_code\s*([\s\S]*?)\s*```', multiLine: true);
    final match = regex.firstMatch(content);

    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      gemmaLog(
        'JsonFormat: Found tool_code markdown block: $jsonStr',
        level: GemmaLogLevel.verbose,
      );
      return JsonParsingUtils.parseJsonString(jsonStr);
    }
    return null;
  }

  /// Parse ` ```json\nJSON\n``` ` or ` ```\nJSON\n``` ` format.
  FunctionCallResponse? _parseMarkdownBlock(String content) {
    var regex = RegExp(r'```json\s*([\s\S]*?)\s*```', multiLine: true);
    var match = regex.firstMatch(content);

    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      gemmaLog(
        'JsonFormat: Found markdown json block: $jsonStr',
        level: GemmaLogLevel.verbose,
      );
      return JsonParsingUtils.parseJsonString(jsonStr);
    }

    regex = RegExp(r'```\s*([\s\S]*?)\s*```', multiLine: true);
    match = regex.firstMatch(content);

    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      if (jsonStr.startsWith('{') && jsonStr.contains('"name"')) {
        gemmaLog(
          'JsonFormat: Found markdown code block: $jsonStr',
          level: GemmaLogLevel.verbose,
        );
        return JsonParsingUtils.parseJsonString(jsonStr);
      }
    }
    return null;
  }

  /// Parse direct JSON format.
  FunctionCallResponse? _parseDirectJson(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('{') && trimmed.contains('"name"')) {
      gemmaLog(
        'JsonFormat: Found direct JSON: $trimmed',
        level: GemmaLogLevel.verbose,
      );
      return JsonParsingUtils.parseJsonString(trimmed);
    }
    return null;
  }
}
