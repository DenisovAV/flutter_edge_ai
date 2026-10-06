import 'dart:convert';

import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_response.dart';
import 'package:flutter_edge_ai/core/parsing/function_gemma_wire.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

// The FunctionGemma tokens live with the wire format they belong to.
export 'package:flutter_edge_ai/core/parsing/function_gemma_wire.dart';

const userPrefix = "user";
const modelPrefix = "model";
const developerPrefix =
    "developer"; // FunctionGemma uses developer role for tools
const startTurn = "<start_of_turn>";
const endTurn = "<end_of_turn>";

const deepseekStart = "<｜begin▁of▁sentence｜>";
const deepseekUser = "<｜User｜>";
const deepseekAssistant = "<｜Assistant｜>";

// Qwen tokens
const qwenStart = "<|im_start|>";
const qwenEnd = "<|im_end|>";

// Llama tokens
const llamaInstStart = "[INST]";
const llamaInstEnd = "[/INST]";

// Hammer tokens (using general format for now - need more research)
const hammerUser = "User:";
const hammerAssistant = "Assistant:";

/// The three chat-prompt formatting modes the engine-dispatch decision selects.
///
/// Isolated here so the Phase B engine packages have ONE seam to own: the
/// decision of WHICH formatting mode a (modelType, fileType, platform) combo
/// uses. The per-[ModelType] manual templates themselves (`_transform*`) are a
/// separate concern that moves into the engine packages later. Private to
/// extensions.dart — not a public contract.
enum _ChatFormatMode {
  /// The runtime applies the chat template (MediaPipe for .task, LiteRT-LM for
  /// .litertlm) — return raw content.
  raw,

  /// Manual per-[ModelType] template formatting (.bin/.tflite).
  manual,

  /// System messages are not sent to the model.
  drop,
}

/// The engine-dispatch DECISION, isolated from the formatting. Returns which
/// [_ChatFormatMode] applies; the produced strings are identical to the prior
/// inline branching in [MessageExtension.transformToChatPrompt].
_ChatFormatMode _chatFormatModeFor(
  ModelType type,
  ModelFileType fileType,
  MessageType messageType,
) {
  // System messages should not be sent to the model.
  if (messageType == MessageType.systemInfo) return _ChatFormatMode.drop;

  // .task files - MediaPipe handles templates, return raw content
  // EXCEPT FunctionGemma which needs manual formatting (no prefix/suffix in .task)
  if (fileType == ModelFileType.task && type != ModelType.functionGemma) {
    return _ChatFormatMode.raw;
  }

  // .litertlm files - the LiteRT-LM Conversation API applies the model's own
  // chat template on every platform, iOS included, so the message goes in raw.
  // Until 0.14.0 iOS ran .litertlm through MediaPipe, which did not, and this
  // branch formatted it by hand there. Since 0.14.0 iOS shares LiteRtLmFfiClient
  // with Android and desktop, and formatting by hand wrapped the prompt twice:
  // the markers reached the model as message text.
  if (fileType == ModelFileType.litertlm) {
    return _ChatFormatMode.raw;
  }

  // Built-in OS models (Gemini Nano / Apple FM) — native SDK owns templates.
  if (fileType == ModelFileType.builtIn) {
    return _ChatFormatMode.raw;
  }

  // ORT-GenAI model directories — the SDK owns tokenizer + chat template
  // (OgaTokenizerApplyChatTemplate, applied worker-side in
  // flutter_edge_ai_onnx's GenAiFfiClient) — the same posture as .litertlm.
  if (fileType == ModelFileType.onnx) {
    return _ChatFormatMode.raw;
  }

  // .bin/.tflite files - always manual formatting based on model type.
  return _ChatFormatMode.manual;
}

extension MessageExtension on Message {
  String transformToChatPrompt({
    ModelType type = ModelType.general,
    ModelFileType fileType = ModelFileType.binary,
  }) {
    // DEBUG LOG
    edgeAiLog(
      '[transformToChatPrompt] modelType=$type, fileType=$fileType, messageType=${this.type}, isUser=$isUser',
    );

    switch (_chatFormatModeFor(type, fileType, this.type)) {
      case _ChatFormatMode.drop:
        return '';
      case _ChatFormatMode.raw:
        final result = _formatToolResponseContent();
        edgeAiLog(
          '[transformToChatPrompt] Using _formatToolResponseContent, result length=${result.length}',
        );
        return result;
      case _ChatFormatMode.manual:
        // .bin/.tflite files - manual formatting by model type.
        final result = switch (type) {
          ModelType.general => _transformGeneral(),
          ModelType.gemmaIt => _transformGemmaIt(),
          ModelType.gemma4 => _transformGemmaIt(),
          ModelType.deepSeek => _transformDeepSeek(),
          ModelType.qwen => _transformQwen(),
          ModelType.qwen3 => _transformQwen(),
          ModelType.qwen35 => _transformQwen(),
          ModelType.llama => _transformLlama(),
          ModelType.hammer => _transformHammer(),
          ModelType.functionGemma => _transformFunctionGemma(),
          ModelType.phi => _transformGeneral(),
        };
        return result;
    }
  }

  // Helper method to format tool response content
  String _formatToolResponseContent() {
    if (type == MessageType.toolResponse) {
      return '<tool_response>\n'
          'Tool Name: $toolName\n'
          'Tool Response:\n$text\n'
          '</tool_response>';
    }
    return text;
  }

  String _transformGeneral() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$startTurn$userPrefix\n$content$endTurn';
    }

    // Handle model responses
    var content = text;
    if (type == MessageType.toolCall) {
      // The text already contains the full <tool_code> block
      content = text;
    }
    return '$startTurn$modelPrefix\n$content$endTurn';
  }

  String _transformGemmaIt() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$startTurn$userPrefix\n$content$endTurn\n$startTurn$modelPrefix\n';
    }

    // Handle model responses - for GemmaIt format
    var content = text;
    if (type == MessageType.toolCall) {
      content = text;
    }
    return '$content$endTurn\n';
  }

  String _transformDeepSeek() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$deepseekStart$deepseekUser$content$deepseekAssistant';
    } else {
      return text;
    }
  }

  String _transformQwen() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$qwenStart$userPrefix\n$content$qwenEnd\n$qwenStart$modelPrefix\n';
    }
    var content = text;
    if (type == MessageType.toolCall) {
      content = text;
    }
    return '$content$qwenEnd\n';
  }

  String _transformLlama() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$llamaInstStart $content $llamaInstEnd';
    }
    return text;
  }

  String _transformHammer() {
    if (isUser) {
      final content = _formatToolResponseContent();
      return '$hammerUser $content\n$hammerAssistant ';
    }
    return text;
  }

  String _transformFunctionGemma() {
    // If text already has turn markers (from chat.dart with tools), return as is
    if (text.startsWith(startTurn)) {
      return text;
    }

    // A tool response continues the model's own turn: the template renders
    // call -> response -> answer inside one `<start_of_turn>model`. Opening a
    // second one nested a header the model never saw. Verified on device: the
    // engine still generates without it.
    if (type == MessageType.toolResponse) {
      return _formatFunctionGemmaContent();
    }

    if (isUser) {
      final content = _formatFunctionGemmaContent();
      return '$startTurn$userPrefix\n$content$endTurn\n$startTurn$modelPrefix\n';
    }
    return '$text$endTurn\n';
  }

  String _formatFunctionGemmaContent() {
    if (type == MessageType.toolResponse && toolName != null) {
      // The template splays the response map into its own dictsorted
      // `key:value` pairs. The old `result:<escape>{json}<escape>` wrapper was
      // invented here: that key appears nowhere in the model's chat_template.
      Object? response;
      try {
        response = jsonDecode(text);
      } on FormatException {
        response = text;
      }
      return '$functionGemmaStartResp'
          'response:$toolName{${functionGemmaResponseBody(response)}}'
          '$functionGemmaEndResp';
    }
    return text;
  }
}

// Filter class for thinking models
class ModelThinkingFilter {
  /// The wrapper `SdkTextExtractor` puts around reasoning the LiteRT-LM
  /// runtime streams on a bundle's thought channel — and Gemma 4's own
  /// thinking markers, which it mirrors.
  static const _channelStart = '<|channel>thought\n';
  static const _channelEnd = '<channel|>';
  static const _thinkStart = '<think>';
  static const _thinkEnd = '</think>';

  /// Filters ModelResponse stream for models with thinking support.
  ///
  /// Reasoning on a thought channel (`<|channel>thought\n...<channel|>`) is
  /// split out for every [modelType]: the runtime separates it for any bundle
  /// that declares the channel, whatever the family. Then the family's own
  /// tags: `<think>...</think>` for DeepSeek and Qwen.
  static Stream<ModelResponse> filterThinkingStream(
    Stream<ModelResponse> originalStream, {
    required ModelType modelType,
  }) async* {
    final channelSplit = _splitTagged(
      originalStream,
      startTag: _channelStart,
      endTag: _channelEnd,
    );
    switch (modelType) {
      case ModelType.deepSeek:
        // DeepSeek starts in thinking mode (no opening <think> tag).
        // Uses buffer to handle partial </think> across token boundaries.
        const endTag = _thinkEnd;
        bool dsInside = true;
        String dsBuffer = '';

        await for (final response in channelSplit) {
          if (response is TextResponse) {
            dsBuffer += response.token;

            while (dsBuffer.isNotEmpty) {
              if (dsInside) {
                final endIdx = dsBuffer.indexOf(endTag);
                if (endIdx >= 0) {
                  final thinking = dsBuffer.substring(0, endIdx);
                  if (thinking.isNotEmpty) {
                    yield ThinkingResponse(thinking);
                  }
                  dsBuffer = dsBuffer.substring(endIdx + endTag.length);
                  dsInside = false;
                } else {
                  final partial = _findPartialSuffix(dsBuffer, endTag);
                  final safe = dsBuffer.substring(0, dsBuffer.length - partial);
                  if (safe.isNotEmpty) {
                    yield ThinkingResponse(safe);
                  }
                  dsBuffer = dsBuffer.substring(dsBuffer.length - partial);
                  break;
                }
              } else {
                yield TextResponse(dsBuffer);
                dsBuffer = '';
                break;
              }
            }
          } else {
            yield response;
          }
        }
        if (dsBuffer.isNotEmpty) {
          yield dsInside ? ThinkingResponse(dsBuffer) : TextResponse(dsBuffer);
        }
        break;

      case ModelType.qwen:
      case ModelType.qwen3:
      case ModelType.qwen35:
        // Qwen3 emits <think>...</think>, Qwen2.5 emits nothing. Starts
        // outside — safe for non-thinking models. A thinking-only model
        // whose prompt opens <think> needs its bundle's thought channel,
        // which the runtime splits before this point.
        yield* _splitTagged(
          channelSplit,
          startTag: _thinkStart,
          endTag: _thinkEnd,
        );
        break;

      case ModelType.gemmaIt:
      case ModelType.gemma4:
      // Gemma 4 E2B/E4B thinks in <|channel>thought\n...<channel|>, which
      // the channel split above already separated.
      case ModelType.general:
      case ModelType.llama:
      case ModelType.hammer:
      case ModelType.functionGemma:
      case ModelType.phi:
        yield* channelSplit;
        break;
    }
  }

  /// Splits the text of [source] at [startTag]...[endTag] blocks: inside a
  /// block becomes [ThinkingResponse], outside [TextResponse]. A tag split
  /// across tokens is held back until it resolves; other responses pass
  /// through unchanged.
  static Stream<ModelResponse> _splitTagged(
    Stream<ModelResponse> source, {
    required String startTag,
    required String endTag,
  }) async* {
    var inside = false;
    var buffer = '';
    ModelResponse piece(String text) =>
        inside ? ThinkingResponse(text) : TextResponse(text);

    await for (final response in source) {
      if (response is! TextResponse) {
        yield response;
        continue;
      }
      buffer += response.token;
      while (buffer.isNotEmpty) {
        final tag = inside ? endTag : startTag;
        final idx = buffer.indexOf(tag);
        if (idx >= 0) {
          if (idx > 0) yield piece(buffer.substring(0, idx));
          buffer = buffer.substring(idx + tag.length);
          inside = !inside;
        } else {
          final partial = _findPartialSuffix(buffer, tag);
          final safe = buffer.substring(0, buffer.length - partial);
          if (safe.isNotEmpty) yield piece(safe);
          buffer = buffer.substring(buffer.length - partial);
          break;
        }
      }
    }
    if (buffer.isNotEmpty) yield piece(buffer);
  }

  /// Removes thinking blocks from final text.
  ///
  /// Thought-channel blocks (`<|channel>thought\n...<channel|>`) go for every
  /// [modelType], as in [filterThinkingStream]. DeepSeek and Qwen also lose
  /// `<think>...</think>` blocks, and everything up to a `</think>` with no
  /// opening tag — the shape a model that starts inside its reasoning leaves.
  /// Note: For streaming thinking output, use [filterThinkingStream] with generateChatResponseAsync() instead.
  static String removeThinkingFromText(
    String text, {
    required ModelType modelType,
  }) {
    final withoutChannel = text.replaceAll(
      RegExp(r'<\|channel>thought\n.*?<channel\|>', dotAll: true),
      '',
    );
    switch (modelType) {
      case ModelType.deepSeek:
      case ModelType.qwen:
      case ModelType.qwen3:
      case ModelType.qwen35:
        final withoutBlocks = withoutChannel.replaceAll(
          RegExp(r'<think>.*?</think>', dotAll: true),
          '',
        );
        final orphanEnd = withoutBlocks.lastIndexOf(_thinkEnd);
        return (orphanEnd < 0
                ? withoutBlocks
                : withoutBlocks.substring(orphanEnd + _thinkEnd.length))
            .trim();

      case ModelType.gemmaIt:
      case ModelType.gemma4:
        return withoutChannel.trim();

      case ModelType.general:
      case ModelType.llama:
      case ModelType.hammer:
      case ModelType.functionGemma:
      case ModelType.phi:
        // Only the runtime's thought channel; no family thinking tags.
        return withoutChannel == text ? text : withoutChannel.trim();
    }
  }

  /// Cleans model response from service tags and thinking blocks
  static String cleanResponse(
    String response, {
    required bool isThinking,
    required ModelType modelType,
    required ModelFileType fileType,
  }) {
    // Every model: a bundle's thought channel can reach any family.
    String cleaned = removeThinkingFromText(response, modelType: modelType);

    // For .task files, minimal cleaning - MediaPipe handles formatting
    if (fileType == ModelFileType.task) {
      return cleaned.trim();
    }

    // Built-in OS models return clean text - trim only.
    if (fileType == ModelFileType.builtIn) {
      return cleaned.trim();
    }

    // ORT-GenAI model directories — the SDK owns tokenizer + chat template,
    // so there are no manual turn markers to strip. Trim only.
    if (fileType == ModelFileType.onnx) {
      return cleaned.trim();
    }

    // .litertlm - LiteRT-LM ends the turn natively on every platform, iOS
    // included, so there are no turn markers to strip. Trim only.
    if (fileType == ModelFileType.litertlm) {
      return cleaned.trim();
    }

    // For .bin/.tflite files, apply model-specific cleaning
    switch (modelType) {
      case ModelType.general:
        // General models - no special cleaning needed
        return cleaned.trim();
      case ModelType.gemmaIt:
      case ModelType.gemma4:
        // Remove trailing <end_of_turn> tags and trim whitespace
        return cleaned.replaceAll(RegExp(r'<end_of_turn>\s*$'), '').trim();
      case ModelType.qwen:
      case ModelType.qwen3:
      case ModelType.qwen35:
        // Remove trailing <|im_end|> tags and trim whitespace
        return cleaned.replaceAll(RegExp(r'<\|im_end\|>\s*$'), '').trim();
      case ModelType.llama:
      case ModelType.hammer:
      case ModelType.deepSeek:
      case ModelType.functionGemma:
      case ModelType.phi:
        // These models don't use special end tags, just trim whitespace
        return cleaned.trim();
    }
  }

  /// Returns length of the longest suffix of [text] that is a prefix of [marker].
  static int _findPartialSuffix(String text, String marker) {
    for (int i = marker.length.clamp(0, text.length); i >= 1; i--) {
      if (text.endsWith(marker.substring(0, i))) {
        return i;
      }
    }
    return 0;
  }
}
