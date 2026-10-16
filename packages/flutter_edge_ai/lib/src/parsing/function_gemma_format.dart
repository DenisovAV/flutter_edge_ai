import 'package:flutter_edge_ai/src/extensions.dart';
import 'package:flutter_edge_ai/src/model_response.dart';

import 'escaped_call_syntax.dart';
import 'function_call_format.dart';

/// FunctionGemma proprietary format.
///
/// Format: `<start_function_call>call:name{param:<escape>value<escape>}<end_function_call>`
///
/// Used by: ModelType.functionGemma
class FunctionGemmaCallFormat extends FunctionCallFormat {
  @override
  bool isFunctionCallStart(String buffer) {
    return buffer.trim().startsWith(functionGemmaStartCall);
  }

  @override
  bool isDefinitelyText(String buffer) {
    final clean = buffer.trim();
    if (clean.length < 5) return false;
    if (isFunctionCallStart(buffer)) return false;

    final early = clean.length > 30 ? clean.substring(0, 30) : clean;
    return !early.contains(functionGemmaStartCall);
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;
    if (!clean.contains(functionGemmaStartCall)) return false;

    // The end tag means the model stopped, even if the body never balanced —
    // chat.dart then emits the buffer as text. Otherwise the call is finished
    // only once its own brace closes; a stop token may have cut the tag off.
    return clean.contains(functionGemmaEndCall) || _findCall(clean) != null;
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;

    final call = _findCall(text);
    if (call == null) return null;

    final args = parseEscapedCallArguments(
      call.body,
      escape: functionGemmaEscape,
    );
    if (args == null) return null;

    return FunctionCallResponse(name: call.name, args: args);
  }
}

EscapedCall? _findCall(String text) => findEscapedCall(
  text,
  start: functionGemmaStartCall,
  escape: functionGemmaEscape,
);
