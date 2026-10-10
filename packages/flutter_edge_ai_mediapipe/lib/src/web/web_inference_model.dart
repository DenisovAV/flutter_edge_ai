// Standalone library: the MediaPipe-web inference model + session + prompt
// parts, extracted from core's `flutter_edge_ai_web.dart`. Consumes the shared
// public web infra that STAYS in core (`web_model_source.dart`,
// `web_image_format.dart`) plus the sibling MediaPipe JS interop
// (`llm_inference_web.dart`).
import 'dart:async';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show InferenceModel, InferenceModelSession, SessionMetrics;
// WebInferenceModel.activeBackend overrides the [InferenceModel] contract, whose
// type is core's PreferredBackend (from core's platform_types.dart).
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/web/web_image_format.dart';
import 'package:flutter_edge_ai/web/web_model_source.dart';

import '../mediapipe_sampling.dart';
import 'llm_inference_web.dart';

/// Base class for prompt parts (text, image, audio)
abstract class PromptPart {}

/// Text prompt part
class TextPromptPart extends PromptPart {
  final String text;
  TextPromptPart(this.text);
}

/// Image prompt part with data URL
class ImagePromptPart extends PromptPart {
  final String dataUrl;
  ImagePromptPart(this.dataUrl);

  /// Create ImagePromptPart from Uint8List bytes
  factory ImagePromptPart.fromBytes(Uint8List bytes) {
    final base64String = base64Encode(bytes);
    final mimeType = detectImageMimeType(bytes);
    final dataUrl = 'data:$mimeType;base64,$base64String';
    return ImagePromptPart(dataUrl);
  }
}

/// Audio prompt part with raw audio bytes
/// For Gemma 3n E4B models - supports PCM audio (16kHz, 16-bit, mono)
class AudioPromptPart extends PromptPart {
  final Uint8List audioBytes;
  AudioPromptPart(this.audioBytes);
}

class WebInferenceModel extends InferenceModel with CloseNotifier {
  final VoidCallback onClose;
  bool _isClosed = false;
  @override
  final int maxTokens;

  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  PreferredBackend? get activeBackend => null;
  final List<int>? loraRanks;
  final WebModelSourceResolver sourceResolver;
  final bool supportImage; // Enabling image support
  final bool supportAudio; // Enabling audio support (Gemma 3n E4B)
  final int? maxNumImages;
  Completer<InferenceModelSession>? _initCompleter;
  @override
  InferenceModelSession? session;

  WebInferenceModel({
    required this.modelType,
    this.fileType = ModelFileType.task,
    required this.onClose,
    required this.maxTokens,
    this.loraRanks,
    required this.sourceResolver,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxNumImages,
    this.maxConcurrentSessions,
  });

  /// Cap on concurrent [openSession] sessions; null = unlimited. Accepted
  /// for API symmetry. The MediaPipe web `.task` path doesn't support
  /// concurrent sessions yet (openSession inherits the interface's
  /// UnsupportedError), so this is currently informational.
  final int? maxConcurrentSessions;

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality, // Enabling vision modality support
    bool? enableAudioModality, // Enabling audio modality support (Gemma 3n E4B)
    String? systemInstruction,
    bool enableThinking = false, // Not supported on Web (MediaPipe)
    List<Tool> tools =
        const [], // Tools wired through chat.dart prompt; SDK tools_json N/A on web
    int? maxOutputTokens,
  }) async {
    // Thinking mode not supported on Web (MediaPipe has no extraContext/channels API)
    if (enableThinking) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: enableThinking is not supported on Web (MediaPipe). '
          'Use Android or Desktop with .litertlm models for Gemma 4 thinking mode.',
        );
      }
    }
    if (maxOutputTokens != null) {
      edgeAiLog(
        '[MediaPipe Web] maxOutputTokens ($maxOutputTokens) is not supported '
        'on the .task web path (no session-level output cap); ignoring.',
      );
    }

    // TODO: Implement vision modality for web
    if (enableVisionModality == true) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: Vision modality is not yet implemented for web platform',
        );
      }
    }

    // Audio modality is handled via supportAudio flag in the model
    if (enableAudioModality == true && !supportAudio) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: Audio modality requested but supportAudio is false',
        );
      }
    }

    if (_initCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _initCompleter = Completer<InferenceModelSession>();
    try {
      // Shared resolver handles activeModel lookup + storage-mode branch.
      // Used identically by the LiteRT-LM web model in flutter_edge_ai_litertlm.
      final resolved = await sourceResolver.resolveActiveInferenceModel();

      final fileset = await FilesetResolver.forGenAiTasks(
        'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29/wasm'.toJS,
      ).toDart;

      // LoRA path comes from the resolver alongside the model source.
      final loraPathToUse = loraPath ?? resolved.loraPath;
      final hasLoraParams = loraPathToUse != null && loraRanks != null;

      // MediaPipe consumes either modelAssetPath (Blob URL string) or
      // modelAssetBuffer (ReadableStreamDefaultReader, for OPFS streaming).
      final baseOptions = switch (resolved.model) {
        BlobUrlModelSource(:final url) => LlmInferenceBaseOptions(
          modelAssetPath: url,
        ),
        OpfsStreamModelSource() => LlmInferenceBaseOptions(
          modelAssetBuffer: await (resolved.model as OpfsStreamModelSource)
              .openReader(),
        ),
      };

      // A `.task` file carries no sampler, so an unset field comes from the
      // family defaults. MediaPipe web 0.10.29 has no topP option; it is
      // passed and dropped.
      final sampling = resolveMediaPipeSampling(
        SamplingParams(
          temperature: temperature,
          topK: topK,
          topP: topP,
          randomSeed: randomSeed,
        ),
        modelType: modelType,
      );
      final config = LlmInferenceOptions(
        baseOptions: baseOptions,
        maxTokens: maxTokens,
        randomSeed: sampling.randomSeed,
        topK: sampling.topK,
        temperature: sampling.temperature,
        topP: sampling.topP,
        supportedLoraRanks: !hasLoraParams
            ? null
            : Int32List.fromList(loraRanks!).toJS,
        loraPath: !hasLoraParams ? null : loraPathToUse,
        maxNumImages: supportImage ? (maxNumImages ?? 1) : null,
      );

      final llmInference = await LlmInference.createFromOptions(
        fileset,
        config,
      ).toDart;

      session = WebModelSession(
        modelType: modelType,
        fileType: fileType,
        llmInference: llmInference,
        supportImage: supportImage, // Enabling image support
        supportAudio: supportAudio, // Enabling audio support
        systemInstruction: systemInstruction,
        onClose: onClose,
      );

      completer.complete(session);
      // `await` so the future stays inside this try. It is already completed
      // with `session` on the line above, so this changes no behaviour today —
      // but returning a Future unawaited from a try block means the catch
      // below would not see an error it carried.
      return await completer.future;
    } catch (e, st) {
      _initCompleter = null;
      completer.completeError(e, st);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await session?.close();
    session = null;
    _initCompleter = null;
    onClose();
    fireCloseListeners();
  }
}

class WebModelSession extends InferenceModelSession {
  final ModelType modelType;
  final ModelFileType fileType;
  final LlmInference llmInference;
  final VoidCallback onClose;
  final bool supportImage; // Enabling image support
  final bool supportAudio; // Enabling audio support (Gemma 3n E4B)
  StreamController<String>? _controller;
  final List<PromptPart> _promptParts = [];

  final String? systemInstruction;
  bool _systemInstructionSent = false;

  WebModelSession({
    required this.llmInference,
    required this.onClose,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.supportImage = false,
    this.supportAudio = false,
    this.systemInstruction,
  });

  @override
  Future<int> sizeInTokens(String text) async {
    final size = llmInference.sizeInTokens(text.toJS);
    return size.toDartInt;
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    if (kDebugMode) {
      edgeAiLog(
        '🟢 WebModelSession.addQueryChunk() called - hasImage: ${message.hasImage}, hasAudio: ${message.hasAudio}, supportImage: $supportImage, supportAudio: $supportAudio',
      );
    }

    var messageToSend = message;
    if (message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty) {
      _systemInstructionSent = true;
      messageToSend = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }

    final finalPrompt = messageToSend.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );

    // Add image parts first, then audio, then text last.
    if (message.hasImage) {
      if (!supportImage) {
        if (kDebugMode) {
          edgeAiLog('🔴 Model does not support images - throwing exception');
        }
        throw ArgumentError('This model does not support images');
      }

      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? [message.imageBytes!]
                : const <Uint8List>[]);
      for (final imageBytes in images) {
        if (kDebugMode) {
          edgeAiLog(
            '🟢 Processing image: ${imageBytes.length} bytes',
            level: EdgeAiLogLevel.verbose,
          );
        }
        final imagePart = ImagePromptPart.fromBytes(imageBytes);
        _promptParts.add(imagePart);
        if (kDebugMode) {
          edgeAiLog(
            '🟢 Added image part with dataUrl length: ${imagePart.dataUrl.length}',
          );
        }
      }
    }

    // Handle audio processing for web (Gemma 3n E4B)
    if (message.hasAudio && message.audioBytes != null) {
      if (kDebugMode) {
        edgeAiLog(
          '🎵 Processing audio: ${message.audioBytes!.length} bytes',
          level: EdgeAiLogLevel.verbose,
        );
      }
      if (!supportAudio) {
        if (kDebugMode) {
          edgeAiLog('🔴 Model does not support audio - throwing exception');
        }
        throw ArgumentError('This model does not support audio');
      }
      // Add audio part
      final audioPart = AudioPromptPart(message.audioBytes!);
      _promptParts.add(audioPart);
      if (kDebugMode) {
        edgeAiLog(
          '🎵 Added audio part with ${message.audioBytes!.length} bytes',
        );
      }
    }

    // Add text part last so multimodal turns keep image/audio context first.
    _promptParts.add(TextPromptPart(finalPrompt));
    if (kDebugMode) {
      edgeAiLog(
        '🟢 Added text part: ${finalPrompt.substring(0, math.min(100, finalPrompt.length))}...',
      );
    }

    if (kDebugMode) {
      edgeAiLog(
        '🟢 Total prompt parts: ${_promptParts.length}',
        level: EdgeAiLogLevel.verbose,
      );
    }
  }

  /// Convert PromptParts to JavaScript array for MediaPipe
  JSAny _createPromptArray() {
    if (kDebugMode) {
      edgeAiLog(
        '🔧 _createPromptArray: Starting with ${_promptParts.length} prompt parts',
      );
    }

    if (_promptParts.isEmpty) {
      if (kDebugMode) {
        edgeAiLog(
          '📝 _createPromptArray: Empty prompt parts, returning empty string',
        );
      }
      return ''.toJS; // Empty string fallback
    }

    // If only text parts, join them
    if (_promptParts.every((part) => part is TextPromptPart)) {
      final fullText = _promptParts
          .cast<TextPromptPart>()
          .map((part) => part.text)
          .join('');
      if (kDebugMode) {
        edgeAiLog(
          '📝 _createPromptArray: All text parts, returning string of length ${fullText.length}',
        );
        edgeAiLog(
          '📝 _createPromptArray: Text preview: ${fullText.substring(0, math.min(100, fullText.length))}...',
        );
      }
      return fullText.toJS;
    }

    // Multimodal: create array of parts following MediaPipe documentation format
    if (kDebugMode) {
      edgeAiLog(
        '🎯 _createPromptArray: Multimodal mode - creating array with proper format',
      );
    }

    final jsArray = <JSAny>[];

    // Add conversation start token
    jsArray.add('<ctrl99>user\n'.toJS);

    for (int i = 0; i < _promptParts.length; i++) {
      final part = _promptParts[i];

      if (part is TextPromptPart) {
        if (kDebugMode) {
          edgeAiLog(
            '📝 _createPromptArray: Adding text part: "${part.text.substring(0, math.min(50, part.text.length))}..."',
          );
        }
        jsArray.add(part.text.toJS);
      } else if (part is ImagePromptPart) {
        if (kDebugMode) {
          edgeAiLog(
            '🖼️ _createPromptArray: Adding image part with data URL length: ${part.dataUrl.length}',
          );
          edgeAiLog(
            '🖼️ _createPromptArray: Image data URL prefix: ${part.dataUrl.substring(0, math.min(50, part.dataUrl.length))}...',
          );
        }

        // Create proper image object for MediaPipe
        final imageObj = <String, String>{'imageSource': part.dataUrl}.jsify();
        if (kDebugMode) {
          edgeAiLog(
            '🖼️ _createPromptArray: Created image object with jsify()',
          );
        }
        jsArray.add(imageObj as JSAny);
      } else if (part is AudioPromptPart) {
        if (kDebugMode) {
          edgeAiLog(
            '🎵 _createPromptArray: Adding audio part with ${part.audioBytes.length} bytes',
          );
        }

        // Create proper audio object for MediaPipe
        // Audio is passed as raw PCM bytes (16kHz, 16-bit, mono)
        final audioObj = <String, Object>{
          'audioSource': part.audioBytes.buffer.asUint8List(),
        }.jsify();
        if (kDebugMode) {
          edgeAiLog('🎵 _createPromptArray: Created audio object with jsify()');
        }
        jsArray.add(audioObj as JSAny);
      } else {
        if (kDebugMode) {
          edgeAiLog(
            '❌ _createPromptArray: Unsupported prompt part type: ${part.runtimeType}',
          );
        }
        throw Exception('Unsupported prompt part type: $part');
      }
    }

    // Add conversation end and model start tokens
    jsArray.add('<ctrl100>\n<ctrl99>model\n'.toJS);

    if (kDebugMode) {
      edgeAiLog(
        '✅ _createPromptArray: Created JS array with ${jsArray.length} elements (including control tokens)',
      );
      edgeAiLog('🎯 _createPromptArray: Array structure ready for MediaPipe');
    }

    return jsArray.toJS;
  }

  @override
  Future<String> getResponse() async {
    if (kDebugMode) {
      edgeAiLog('🚀 getResponse: Starting response generation');
    }

    try {
      final promptArray = _createPromptArray();

      if (kDebugMode) {
        edgeAiLog(
          '🎯 getResponse: Prompt array type: ${promptArray.runtimeType}',
        );
        edgeAiLog('🎯 getResponse: Is JSString? ${promptArray is JSString}');
      }

      String response;

      // Use appropriate method based on prompt type
      if (promptArray is JSString) {
        if (kDebugMode) {
          edgeAiLog(
            '📝 getResponse: Using generateResponse for text-only prompt',
          );
        }
        response =
            (await llmInference.generateResponse(promptArray, null).toDart)
                .toDart;
      } else {
        if (kDebugMode) {
          edgeAiLog(
            '🖼️ getResponse: Using generateResponseMultimodal for multimodal prompt',
          );
        }
        response =
            (await llmInference
                    .generateResponseMultimodal(promptArray, null)
                    .toDart)
                .toDart;
      }

      if (kDebugMode) {
        edgeAiLog(
          '✅ getResponse: Successfully generated response of length ${response.length}',
        );
        edgeAiLog(
          '✅ getResponse: Response preview: ${response.substring(0, math.min(100, response.length))}...',
        );
      }

      // Don't add response back to promptParts - that's handled by InferenceChat
      return response;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        edgeAiLog('❌ getResponse: Exception caught: $e');
        edgeAiLog('❌ getResponse: Stack trace: $stackTrace');
      }
      _promptParts.clear();
      rethrow;
    }
  }

  @override
  Stream<String> getResponseAsync() {
    if (kDebugMode) {
      edgeAiLog('🌊 getResponseAsync: Starting async response generation');
    }

    // Close previous controller to prevent leak if called again before completion
    _controller?.close();
    _controller = StreamController<String>();

    try {
      final promptArray = _createPromptArray();

      if (kDebugMode) {
        edgeAiLog(
          '🎯 getResponseAsync: Prompt array type: ${promptArray.runtimeType}',
        );
        edgeAiLog(
          '🎯 getResponseAsync: Is JSString? ${promptArray is JSString}',
        );
      }

      // Use appropriate method based on prompt type
      if (promptArray is JSString) {
        if (kDebugMode) {
          edgeAiLog(
            '📝 getResponseAsync: Using generateResponse for text-only prompt',
          );
        }
        llmInference.generateResponse(
          promptArray,
          ((JSString partialJs, JSAny completeRaw) {
            try {
              final complete = completeRaw.parseBool();
              final partial = partialJs.toDart;
              if (kDebugMode) {
                edgeAiLog(
                  '📝 getResponseAsync: Received partial (complete: $complete): ${partial.substring(0, math.min(50, partial.length))}...',
                );
              }
              _controller?.add(partial);
              if (complete) {
                if (kDebugMode) {
                  edgeAiLog('✅ getResponseAsync: Text response completed');
                }
                _controller?.close();
              }
            } catch (e) {
              if (kDebugMode) {
                edgeAiLog('❌ getResponseAsync: Error in text callback: $e');
              }
              _controller?.addError(e);
            }
          }).toJS,
        );
      } else {
        if (kDebugMode) {
          edgeAiLog(
            '🖼️ getResponseAsync: Using generateResponseMultimodal for multimodal prompt',
          );
        }
        llmInference.generateResponseMultimodal(
          promptArray,
          ((JSString partialJs, JSAny completeRaw) {
            try {
              final complete = completeRaw.parseBool();
              final partial = partialJs.toDart;
              if (kDebugMode) {
                edgeAiLog(
                  '🖼️ getResponseAsync: Received multimodal partial (complete: $complete): ${partial.substring(0, math.min(50, partial.length))}...',
                );
              }
              _controller?.add(partial);
              if (complete) {
                if (kDebugMode) {
                  edgeAiLog(
                    '✅ getResponseAsync: Multimodal response completed',
                  );
                }
                _controller?.close();
              }
            } catch (e) {
              if (kDebugMode) {
                edgeAiLog(
                  '❌ getResponseAsync: Error in multimodal callback: $e',
                );
              }
              _controller?.addError(e);
            }
          }).toJS,
        );
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        edgeAiLog('❌ getResponseAsync: Exception during setup: $e');
        edgeAiLog('❌ getResponseAsync: Stack trace: $stackTrace');
      }
      _controller?.addError(e);
    }

    return _controller!.stream;
  }

  @override
  Future<void> stopGeneration() async {
    try {
      llmInference.cancelProcessing();
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[WebModelSession] cancelProcessing error: $e');
      }
    } finally {
      _controller?.close();
      _controller = null;
      _promptParts.clear();
    }
  }

  @override
  SessionMetrics getSessionMetrics() {
    // Web MediaPipe implementation doesn't expose detailed token metrics.
    // Users can estimate using sizeInTokens() before/after generation.
    return SessionMetrics();
  }

  @override
  Future<void> close() async {
    // Cleanup MediaPipe LlmInference WASM resources (important for hot restart)
    // This prevents memory leaks and "memory access out of bounds" errors
    // Note: MediaPipe's close() will also release any OPFS stream readers internally
    try {
      llmInference.close();
      if (kDebugMode) {
        edgeAiLog('[WebModelSession] Cleaned up LlmInference resources');
      }
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[WebModelSession] Warning: Error closing LlmInference: $e');
      }
    }

    _promptParts.clear();
    _controller?.close();
    _controller = null;
    onClose();
  }
}
