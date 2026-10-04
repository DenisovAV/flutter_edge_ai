import 'dart:convert';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'package:flutter_edge_ai/core/model_response.dart';

import 'function_call_format.dart';
import 'json_function_call_format.dart';

// DeepSeek special tokens (full-width Unicode characters)
const _toolCallsBegin = '<｜tool▁calls▁begin｜>';
const _toolCallBegin = '<｜tool▁call▁begin｜>';
const _toolSep = '<｜tool▁sep｜>';
const _toolCallEnd = '<｜tool▁call▁end｜>';

/// DeepSeek V3 tool call format.
///
/// Format:
/// ```
/// <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function
/// <｜tool▁sep｜>get_weather
/// {"location": "NYC"}
/// <｜tool▁call▁end｜><｜tool▁calls▁end｜>
/// ```
///
/// Falls back to JSON formats for simpler model outputs.
///
/// Used by: ModelType.deepSeek
class DeepSeekFunctionCallFormat extends FunctionCallFormat {
  final _jsonFallback = JsonFunctionCallFormat();

  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    return clean.contains(_toolCallsBegin) ||
        clean.contains(_toolCallBegin) ||
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
        !early.contains('<｜tool');
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    if (clean.contains(_toolCallBegin) && clean.contains(_toolCallEnd)) {
      return true;
    }
    return _jsonFallback.isFunctionCallComplete(buffer);
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;

    final deepSeekResult = _parseDeepSeekCall(text);
    if (deepSeekResult != null) return deepSeekResult;

    return _jsonFallback.parse(text);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return [];

    final results = _parseAllDeepSeekCalls(text);
    if (results.isNotEmpty) return results;

    return _jsonFallback.parseAll(text);
  }

  /// Parse a single DeepSeek tool call.
  FunctionCallResponse? _parseDeepSeekCall(String text) {
    final calls = _parseAllDeepSeekCalls(text);
    return calls.isNotEmpty ? calls.first : null;
  }

  /// Parse all DeepSeek tool calls from text.
  List<FunctionCallResponse> _parseAllDeepSeekCalls(String text) {
    final results = <FunctionCallResponse>[];

    // Match each tool call block
    final callRegex = RegExp(
      '${RegExp.escape(_toolCallBegin)}[\\s\\S]*?${RegExp.escape(_toolSep)}(\\S+)\\s*([\\s\\S]*?)${RegExp.escape(_toolCallEnd)}',
    );

    for (final match in callRegex.allMatches(text)) {
      final functionName = match.group(1)!.trim();
      final argsStr = match.group(2)!.trim();

      try {
        final args = jsonDecode(argsStr);
        if (args is Map<String, dynamic>) {
          edgeAiLog(
            'DeepSeekFormat: Parsed function: $functionName($args)',
            level: EdgeAiLogLevel.verbose,
          );
          results.add(FunctionCallResponse(name: functionName, args: args));
        }
      } catch (e) {
        edgeAiLog('DeepSeekFormat: Failed to parse args for $functionName: $e');
      }
    }

    return results;
  }
}
