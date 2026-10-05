import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/model_response.dart';
import 'package:flutter_gemma/core/parsing/function_call_format.dart';
import 'package:flutter_gemma/core/parsing/function_call_format_factory.dart';
import 'package:flutter_gemma/core/parsing/sdk_passthrough_function_call_format.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Facade for backward compatibility.
/// Delegates to model-specific [FunctionCallFormat] implementations.
class FunctionCallParser {
  /// Whether [modelType]'s function-call format is the SDK-passthrough kind:
  /// the backend surfaces tool calls through a structured SDK response
  /// (`RawSdkResponseSession.lastRawResponse`) rather than in the text stream,
  /// and the text stream itself carries the raw
  /// `{"role":"assistant","tool_calls":...}` JSON that must be suppressed. Keyed
  /// off the format (not a hardcoded model) so every SDK-passthrough model —
  /// Gemma 4, and FunctionGemma on `.litertlm` — is handled the same way.
  /// [fileType] picks between a model family's runtimes; see
  /// [FunctionCallFormatFactory.create].
  static bool usesSdkPassthrough(
    ModelType? modelType, {
    ModelFileType? fileType,
  }) =>
      FunctionCallFormatFactory.create(modelType, fileType: fileType)
          is SdkPassthroughFunctionCallFormat;

  /// Whether this model's format has its tool declarations injected by the
  /// runtime/SDK, so [InferenceChat] must not weave its own tools prompt. The
  /// model-derived default for `InferenceChat.runtimeInjectsToolDeclarations`;
  /// an engine that injects tools natively (e.g. the web Prompt API) overrides
  /// it per-chat. Keyed off the format, not a hardcoded model.
  static bool runtimeInjectsToolDeclarations(
    ModelType? modelType, {
    ModelFileType? fileType,
  }) => FunctionCallFormatFactory.create(
    modelType,
    fileType: fileType,
  ).runtimeInjectsToolDeclarations;

  /// Check if buffer starts with function call indicators
  static bool isFunctionCallStart(String buffer, {ModelType? modelType}) {
    return FunctionCallFormatFactory.create(
      modelType,
    ).isFunctionCallStart(buffer);
  }

  /// DEPRECATED: Use isFunctionCallStart instead
  @Deprecated('Use isFunctionCallStart with modelType parameter')
  static bool isJsonStart(String buffer) {
    return isFunctionCallStart(buffer);
  }

  /// Checks if buffer looks definitely like text (not a function call)
  static bool isDefinitelyText(String buffer, {ModelType? modelType}) {
    return FunctionCallFormatFactory.create(modelType).isDefinitelyText(buffer);
  }

  /// Check if function call structure is complete
  static bool isFunctionCallComplete(String buffer, {ModelType? modelType}) {
    return FunctionCallFormatFactory.create(
      modelType,
    ).isFunctionCallComplete(buffer);
  }

  /// DEPRECATED: Use isFunctionCallComplete instead
  @Deprecated('Use isFunctionCallComplete with modelType parameter')
  static bool isJsonComplete(String buffer) {
    return isFunctionCallComplete(buffer);
  }

  /// Parse a single function call based on model type
  static FunctionCallResponse? parse(String text, {ModelType? modelType}) {
    if (text.trim().isEmpty) return null;

    try {
      return FunctionCallFormatFactory.create(modelType).parse(text);
    } catch (e) {
      gemmaLog('FunctionCallParser: Error parsing function call: $e');
      return null;
    }
  }

  /// Parse all function calls from text (for parallel tool calls)
  static List<FunctionCallResponse> parseAll(
    String text, {
    ModelType? modelType,
  }) {
    if (text.trim().isEmpty) return [];

    try {
      return FunctionCallFormatFactory.create(modelType).parseAll(text);
    } catch (e) {
      gemmaLog('FunctionCallParser: Error parsing function calls: $e');
      return [];
    }
  }
}
