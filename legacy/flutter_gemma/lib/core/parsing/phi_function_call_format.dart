import 'package:flutter_gemma/core/model_response.dart';

import 'function_call_format.dart';
import 'json_function_call_format.dart';
import 'json_parsing_utils.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Phi-4 tool call format.
///
/// Format: `<|tool_calls|>[{"name":"...","arguments":{...}}]<|/tool_calls|>`
///
/// Falls back to JSON formats for simpler model outputs.
///
/// Note: Phi-4 always outputs a JSON **array**, even for single calls.
///
/// Used by: ModelType.phi
class PhiFunctionCallFormat extends FunctionCallFormat {
  final _jsonFallback = JsonFunctionCallFormat();

  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    return clean.contains('<|tool_calls|>') ||
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
        !early.contains('<tool') &&
        !early.contains('<|tool');
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    if (clean.contains('<|tool_calls|>') && clean.contains('<|/tool_calls|>')) {
      return true;
    }
    return _jsonFallback.isFunctionCallComplete(buffer);
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;

    final phiResult = _parsePhiCall(text);
    if (phiResult != null) return phiResult;

    return _jsonFallback.parse(text);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return [];

    final results = _parseAllPhiCalls(text);
    if (results.isNotEmpty) return results;

    return _jsonFallback.parseAll(text);
  }

  /// Parse a single Phi-4 tool call (returns first from array).
  FunctionCallResponse? _parsePhiCall(String text) {
    final calls = _parseAllPhiCalls(text);
    return calls.isNotEmpty ? calls.first : null;
  }

  /// Parse all Phi-4 tool calls.
  List<FunctionCallResponse> _parseAllPhiCalls(String text) {
    final regex = RegExp(
      r'<\|tool_calls\|>\s*([\s\S]*?)\s*<\|/tool_calls\|>',
      multiLine: true,
    );
    final match = regex.firstMatch(text);
    if (match == null) return [];

    final jsonStr = match.group(1)!.trim();
    gemmaLog(
      'PhiFormat: Found tool_calls block: $jsonStr',
      level: GemmaLogLevel.verbose,
    );

    // Phi-4 always outputs a JSON array
    final results = JsonParsingUtils.parseJsonArray(jsonStr);
    if (results.isNotEmpty) return results;

    // Fallback: try as single JSON object
    final single = JsonParsingUtils.parseJsonString(jsonStr);
    return single != null ? [single] : [];
  }
}
