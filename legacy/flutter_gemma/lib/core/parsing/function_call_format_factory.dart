import 'package:flutter_gemma/core/model.dart';

import 'deepseek_function_call_format.dart';
import 'function_call_format.dart';
import 'function_gemma_format.dart';
import 'json_function_call_format.dart';
import 'llama_function_call_format.dart';
import 'phi_function_call_format.dart';
import 'qwen_function_call_format.dart';
import 'sdk_passthrough_function_call_format.dart';

/// Factory for creating model-specific [FunctionCallFormat] instances.
class FunctionCallFormatFactory {
  /// [fileType] matters where one model family runs on two runtimes with
  /// different tool support. FunctionGemma on `.litertlm` goes through
  /// LiteRT-LM's own FunctionGemma data processor, which renders the
  /// declarations, parses calls into structured `tool_calls` and takes results
  /// as role `tool` — the path Google's own apps use. MediaPipe (`.task`) has no
  /// native tools, so there FunctionGemma keeps the text wire format
  /// flutter_gemma renders itself.
  static FunctionCallFormat create(
    ModelType? modelType, {
    ModelFileType? fileType,
  }) {
    return switch (modelType) {
      ModelType.functionGemma when fileType == ModelFileType.litertlm =>
        SdkPassthroughFunctionCallFormat(),
      ModelType.functionGemma => FunctionGemmaCallFormat(),
      // Gemma 4: SDK parses native <|tool_call>...<tool_call|> tokens itself;
      // chat.dart reads structured tool_calls from session.lastRawResponse via
      // SdkResponseParser. Passthrough format reports "no calls in text".
      ModelType.gemma4 => SdkPassthroughFunctionCallFormat(),
      ModelType.qwen => QwenFunctionCallFormat(),
      ModelType.qwen3 => QwenFunctionCallFormat(),
      ModelType.deepSeek => DeepSeekFunctionCallFormat(),
      ModelType.llama => LlamaFunctionCallFormat(),
      ModelType.phi => PhiFunctionCallFormat(),
      // gemmaIt, hammer, general, and null all use JSON format
      _ => JsonFunctionCallFormat(),
    };
  }
}
