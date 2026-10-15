import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'engine_queue.dart';
import 'llama_inference_chat.dart';
import 'llama_inference_session.dart';

/// Loaded GGUF weights shared by independently owned logical dialogues.
///
/// Unset sampling values use core's family/thinking defaults, then its fallback.
/// The pinned llamadart API does not expose model-file sampling defaults.
/// Explicit values take precedence; `topK: 1` or `temperature: 0` is greedy.
/// Invalid sampling values throw [ArgumentError] before replacing a session.
class LlamaInferenceModel extends edge.InferenceModel with CloseNotifier {
  /// Takes ownership of [engine] and its optional projector.
  LlamaInferenceModel({
    required this.engine,
    required this.maxTokens,
    required this.activeBackend,
    this.modelType = edge.ModelType.general,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxNumImages,
    this.maxConcurrentSessions,
    this.defaultLoraPath,
  }) {
    _queue = EngineQueue(
      onInvalidated: (_, _) {
        // Close synchronously marks this model unusable for core's cache. Awaiting
        // teardown here would deadlock the action that still owns the queue.
        unawaited(
          close().then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              edgeAiLog('GGUF runtime disposal failed: $error\n$stack');
            },
          ),
        );
      },
    );
  }

  /// Engine owned by this model.
  final llama.LlamaEngine engine;
  @override
  final int maxTokens;
  @override
  final edge.PreferredBackend? activeBackend;

  /// Installed model family used when a chat does not override it.
  ///
  /// Determines unset sampling values and the chat's family identity. Direct
  /// construction defaults to [edge.ModelType.general].
  final edge.ModelType modelType;

  /// Whether the loaded projector was qualified for image input.
  final bool supportImage;

  /// Whether the loaded projector was qualified for audio input.
  final bool supportAudio;

  /// Maximum images in one input message.
  final int? maxNumImages;

  /// Cap for detached sessions; the legacy singleton has a separate lane.
  final int? maxConcurrentSessions;

  /// Installed model-level LoRA, used unless a session supplies another adapter.
  final String? defaultLoraPath;
  @override
  edge.ModelFileType get fileType => edge.ModelFileType.gguf;

  late final EngineQueue _queue;
  final Set<LlamaInferenceSession> _detached = {};
  LlamaInferenceSession? _session;
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _closing;
  bool _closed = false;

  /// Whether teardown has started; core must wait before loading again.
  @override
  bool get isClosed => _closed;
  @override
  LlamaInferenceSession? get session => _session;
  @override
  List<edge.InferenceModelSession> get sessions =>
      List.unmodifiable([?_session, ..._detached]);

  @override
  Future<LlamaInferenceChat> createChat({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<edge.Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    edge.ModelType? modelType,
    edge.ToolChoice toolChoice = edge.ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    final effectiveTools = supportsFunctionCalls == false
        ? const <edge.Tool>[]
        : List<edge.Tool>.of(tools);
    if (toolChoice == edge.ToolChoice.required && effectiveTools.isEmpty) {
      throw ArgumentError('ToolChoice.required needs enabled tools.');
    }
    final result = LlamaInferenceChat(
      sessionCreator: () => _makeSession(
        detached: false,
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage,
        enableAudioModality: supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        modelType: modelType ?? this.modelType,
        tools: effectiveTools,
        maxOutputTokens: maxOutputTokens,
        toolChoice: switch (toolChoice) {
          edge.ToolChoice.auto => llama.ToolChoice.auto,
          edge.ToolChoice.required => llama.ToolChoice.required,
          edge.ToolChoice.none => llama.ToolChoice.none,
        },
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? this.supportImage,
      supportAudio: supportAudio ?? this.supportAudio,
      tools: effectiveTools,
      supportsFunctionCalls: effectiveTools.isNotEmpty,
      enableThinking: enableThinking,
      modelType: modelType ?? this.modelType,
      fileType: fileType,
      toolChoice: toolChoice,
      maxFunctionBufferLength: maxFunctionBufferLength ?? 1024,
    );
    await result.initSession();
    chat = result;
    return result;
  }

  @override
  Future<LlamaInferenceChat> openChat({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<edge.Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    edge.ModelType? modelType,
    edge.ToolChoice toolChoice = edge.ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    final effectiveTools = supportsFunctionCalls == false
        ? const <edge.Tool>[]
        : List<edge.Tool>.of(tools);
    if (toolChoice == edge.ToolChoice.required && effectiveTools.isEmpty) {
      throw ArgumentError('ToolChoice.required needs enabled tools.');
    }
    final result = LlamaInferenceChat(
      sessionCreator: () => _makeSession(
        detached: true,
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage,
        enableAudioModality: supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        modelType: modelType ?? this.modelType,
        tools: effectiveTools,
        maxOutputTokens: maxOutputTokens,
        toolChoice: switch (toolChoice) {
          edge.ToolChoice.auto => llama.ToolChoice.auto,
          edge.ToolChoice.required => llama.ToolChoice.required,
          edge.ToolChoice.none => llama.ToolChoice.none,
        },
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? this.supportImage,
      supportAudio: supportAudio ?? this.supportAudio,
      tools: effectiveTools,
      supportsFunctionCalls: effectiveTools.isNotEmpty,
      enableThinking: enableThinking,
      modelType: modelType ?? this.modelType,
      fileType: fileType,
      toolChoice: toolChoice,
      maxFunctionBufferLength: maxFunctionBufferLength ?? 1024,
    );
    await result.initSession();
    return result;
  }

  @override
  Future<LlamaInferenceSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<edge.Tool> tools = const [],
    int? maxOutputTokens,
  }) => _makeSession(
    detached: false,
    temperature: temperature,
    randomSeed: randomSeed,
    topK: topK,
    topP: topP,
    loraPath: loraPath,
    enableVisionModality: enableVisionModality,
    enableAudioModality: enableAudioModality,
    systemInstruction: systemInstruction,
    enableThinking: enableThinking,
    tools: tools,
    maxOutputTokens: maxOutputTokens,
  );

  @override
  Future<LlamaInferenceSession> openSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<edge.Tool> tools = const [],
    int? maxOutputTokens,
  }) => _makeSession(
    detached: true,
    temperature: temperature,
    randomSeed: randomSeed,
    topK: topK,
    topP: topP,
    loraPath: loraPath,
    enableVisionModality: enableVisionModality,
    enableAudioModality: enableAudioModality,
    systemInstruction: systemInstruction,
    enableThinking: enableThinking,
    tools: tools,
    maxOutputTokens: maxOutputTokens,
  );

  Future<LlamaInferenceSession> _makeSession({
    required bool detached,
    edge.ModelType? modelType,
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<edge.Tool> tools = const [],
    int? maxOutputTokens,
    llama.ToolChoice toolChoice = llama.ToolChoice.auto,
  }) async {
    _queue.ensureValid();
    if (_closed) throw StateError('The model is closed.');
    if (enableVisionModality == true && !supportImage ||
        enableAudioModality == true && !supportAudio) {
      throw UnsupportedError(
        'Load a compatible projector and enable supportImage/supportAudio on getActiveModel first.',
      );
    }
    if (kIsWeb && loraPath != null) {
      throw UnsupportedError('This connector does not wire Web LoRA adapters.');
    }
    final limit = maxOutputTokens;
    if (limit != null && limit <= 0) {
      throw ArgumentError('Use a positive output limit.');
    }
    final sampling = edge.SamplingParams.resolve(
      edge.SamplingParams(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
      ),
      modelType: modelType ?? this.modelType,
      thinking: enableThinking,
    );
    final operation = _lifecycle.then((_) async {
      if (_closed) throw StateError('The model is closed.');
      if (detached &&
          maxConcurrentSessions != null &&
          _detached.length >= maxConcurrentSessions!) {
        throw StateError(
          'maxConcurrentSessions ($maxConcurrentSessions) reached; close a detached session first.',
        );
      }
      late final LlamaInferenceSession next;
      next = LlamaInferenceSession(
        engine: engine,
        queue: _queue,
        contextSize: maxTokens,
        params: llama.GenerationParams(
          temp: sampling.temperature,
          seed: sampling.randomSeed,
          topK: sampling.topK,
          topP: sampling.topP,
          maxTokens: limit ?? maxTokens - 1,
        ),
        outputLimit: limit,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        enableVision: enableVisionModality ?? supportImage,
        enableAudio: enableAudioModality ?? supportAudio,
        maxImages: maxNumImages,
        loraPath: loraPath,
        defaultLoraPath: defaultLoraPath,
        tools: tools,
        toolChoice: toolChoice,
        onClose: () {
          _detached.remove(next);
          if (identical(_session, next)) _session = null;
        },
      );
      await _queue.run(() async {
        if (tools.isNotEmpty &&
            !(await engine.capabilities).supportsToolCalling) {
          throw UnsupportedError(
            'The active runtime does not support tool calling.',
          );
        }
        await next.validateTools();
      });
      // Validate the replacement before closing a usable legacy session.
      if (!detached) await _session?.close();
      if (_closed) {
        await next.close();
        throw StateError('The model is closed.');
      }
      if (detached) {
        _detached.add(next);
      } else {
        _session = next;
      }
      return next;
    });
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = _close();
  }

  Future<void> _close() async {
    await _lifecycle;
    try {
      // Start every cancellation together so queued peers do not block shutdown.
      await Future.wait(sessions.map((session) => session.close()));
    } finally {
      try {
        await _queue.run(engine.dispose, allowInvalid: true);
      } finally {
        fireCloseListeners();
      }
    }
  }
}
