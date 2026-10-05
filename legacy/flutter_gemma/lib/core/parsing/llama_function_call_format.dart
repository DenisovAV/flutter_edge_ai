import 'package:flutter_gemma/core/model_response.dart';

import 'function_call_format.dart';
import 'json_function_call_format.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Llama 3.2 tool call format.
///
/// Format: `<|python_tag|>[func_name(param="value", param2="value2")]`
///
/// Falls back to JSON formats for simpler model outputs.
///
/// Used by: ModelType.llama
class LlamaFunctionCallFormat extends FunctionCallFormat {
  final _jsonFallback = JsonFunctionCallFormat();

  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    return clean.contains('<|python_tag|>') ||
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
        !early.contains('<|python');
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    // Llama format: <|python_tag|>[func(...)]<|eot_id|> or just ]
    if (clean.contains('<|python_tag|>') &&
        (clean.contains('<|eot_id|>') || clean.endsWith(']'))) {
      return true;
    }
    return _jsonFallback.isFunctionCallComplete(buffer);
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;

    final llamaResult = _parseLlamaCall(text);
    if (llamaResult != null) return llamaResult;

    return _jsonFallback.parse(text);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return [];

    final results = _parseAllLlamaCalls(text);
    if (results.isNotEmpty) return results;

    return _jsonFallback.parseAll(text);
  }

  /// Parse Llama pythonic function calls.
  FunctionCallResponse? _parseLlamaCall(String text) {
    final calls = _parseAllLlamaCalls(text);
    return calls.isNotEmpty ? calls.first : null;
  }

  /// Parse all Llama pythonic function calls.
  /// Format: [func_name(param="value", param2="value2")]
  List<FunctionCallResponse> _parseAllLlamaCalls(String text) {
    // Extract content after <|python_tag|>
    final tagIndex = text.indexOf('<|python_tag|>');
    if (tagIndex < 0) return [];

    var content = text.substring(tagIndex + '<|python_tag|>'.length);
    // Remove trailing <|eot_id|>
    content = content.replaceAll('<|eot_id|>', '').trim();

    // Match [func1(...), func2(...)]
    final listMatch = RegExp(r'^\[([\s\S]*)\]$').firstMatch(content);
    if (listMatch == null) return [];

    final innerContent = listMatch.group(1)!;
    final results = <FunctionCallResponse>[];

    // Match each function call: func_name(args)
    final funcRegex = RegExp(r'(\w+)\(([^)]*)\)');
    for (final match in funcRegex.allMatches(innerContent)) {
      final name = match.group(1)!;
      final argsStr = match.group(2)!;

      final args = _parsePythonArgs(argsStr);
      gemmaLog(
        'LlamaFormat: Parsed function: $name($args)',
        level: GemmaLogLevel.verbose,
      );
      results.add(FunctionCallResponse(name: name, args: args));
    }

    return results;
  }

  /// Parse Python-style keyword arguments: param="value", param2="value2"
  Map<String, dynamic> _parsePythonArgs(String argsStr) {
    final args = <String, dynamic>{};
    if (argsStr.trim().isEmpty) return args;

    // Match key=value pairs, handling quoted strings
    final argRegex = RegExp(r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|[^,]+)');
    for (final match in argRegex.allMatches(argsStr)) {
      final key = match.group(1)!;
      var value = match.group(2)!.trim();

      // Remove surrounding quotes
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }

      // Try to parse as number
      final intVal = int.tryParse(value);
      if (intVal != null) {
        args[key] = intVal;
        continue;
      }
      final doubleVal = double.tryParse(value);
      if (doubleVal != null) {
        args[key] = doubleVal;
        continue;
      }
      // Boolean
      if (value == 'True' || value == 'true') {
        args[key] = true;
        continue;
      }
      if (value == 'False' || value == 'false') {
        args[key] = false;
        continue;
      }

      args[key] = value;
    }

    return args;
  }
}
