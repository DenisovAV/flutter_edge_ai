import 'package:flutter_gemma/core/model_response.dart';

import 'function_call_format.dart';
import 'json_function_call_format.dart';
import 'json_parsing_utils.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Qwen/Mistral tool call format.
///
/// Primary format: `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
/// Falls back to JSON formats (tool_code, markdown, direct JSON).
///
/// Used by: ModelType.qwen
class QwenFunctionCallFormat extends FunctionCallFormat {
  final _jsonFallback = JsonFunctionCallFormat();

  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    return clean.startsWith('<tool_call>') ||
        _jsonFallback.isFunctionCallStart(buffer);
  }

  @override
  bool isDefinitelyText(String buffer) {
    final clean = buffer.trim();
    if (clean.length < 5) return false;

    if (isFunctionCallStart(buffer)) return false;

    final early = clean.length > 30 ? clean.substring(0, 30) : clean;
    return !early.contains('{') &&
        !early.toLowerCase().contains('json') &&
        !early.contains('<tool');
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    if (clean.contains('<tool_call>') && clean.contains('</tool_call>')) {
      return true;
    }
    return _jsonFallback.isFunctionCallComplete(buffer);
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;
    final content = JsonParsingUtils.cleanModelResponse(text);

    return _parseToolCallBlock(content) ?? _jsonFallback.parse(text);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return [];
    final content = JsonParsingUtils.cleanModelResponse(text);

    final results = <FunctionCallResponse>[];
    final regex = RegExp(
      r'<tool_call>\s*([\s\S]*?)\s*</tool_call>',
      multiLine: true,
    );
    for (final match in regex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    return _jsonFallback.parseAll(text);
  }

  /// Parse `<tool_call>JSON</tool_call>` format.
  FunctionCallResponse? _parseToolCallBlock(String content) {
    final regex = RegExp(
      r'<tool_call>\s*([\s\S]*?)\s*</tool_call>',
      multiLine: true,
    );
    final match = regex.firstMatch(content);

    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      gemmaLog(
        'QwenFormat: Found tool_call block: $jsonStr',
        level: GemmaLogLevel.verbose,
      );
      return JsonParsingUtils.parseJsonString(jsonStr);
    }
    return null;
  }
}
