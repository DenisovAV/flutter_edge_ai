import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'engine_queue.dart';
import 'llama_chat_turn_hooks.dart';
import 'llama_inference_session.dart';
import 'runtime_error.dart';

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
  List<edge.InferenceModelSession> get engineSessions => [
    ?_session,
    ..._detached,
  ];

  /// Tools are off when [ChatRequest.supportsFunctionCalls] is false and on
  /// whenever there are any otherwise; [edge.ToolChoice.required] needs one.
  /// The GGUF template renders the declarations itself.
  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) {
    if (request.tokenBuffer < 0 || request.tokenBuffer >= maxTokens) {
      throw ArgumentError(
        'tokenBuffer must be nonnegative and below context size.',
      );
    }
    final effectiveTools = request.supportsFunctionCalls == false
        ? const <edge.Tool>[]
        : request.tools;
    if (request.toolChoice == edge.ToolChoice.required &&
        effectiveTools.isEmpty) {
      throw ArgumentError('ToolChoice.required needs enabled tools.');
    }
    return ResolvedChatRequest(
      modelType: request.modelType ?? modelType,
      supportImage: request.supportImage ?? supportImage,
      supportAudio: request.supportAudio ?? supportAudio,
      supportsFunctionCalls: effectiveTools.isNotEmpty,
      tools: effectiveTools,
      maxFunctionBufferLength: request.maxFunctionBufferLength ?? 1024,
      runtimeInjectsToolDeclarations: true,
      temperature: request.temperature,
      randomSeed: request.randomSeed,
      topK: request.topK,
      topP: request.topP,
      tokenBuffer: request.tokenBuffer,
      loraPath: request.loraPath,
      enableThinking: request.enableThinking,
      toolChoice: request.toolChoice,
      systemInstruction: request.systemInstruction,
      maxOutputTokens: request.maxOutputTokens,
    );
  }

  @override
  ChatTurnHooks createChatTurnHooks(ResolvedChatRequest request) =>
      LlamaChatTurnHooks(enableThinking: request.enableThinking);

  @override
  Future<edge.InferenceChat> createChat({
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
    final resolved = resolveChatRequest(
      ChatRequest(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        tokenBuffer: tokenBuffer,
        loraPath: loraPath,
        supportImage: supportImage,
        supportAudio: supportAudio,
        tools: tools,
        supportsFunctionCalls: supportsFunctionCalls,
        enableThinking: enableThinking,
        modelType: modelType,
        toolChoice: toolChoice,
        maxFunctionBufferLength: maxFunctionBufferLength,
        systemInstruction: systemInstruction,
        maxOutputTokens: maxOutputTokens,
      ),
    );
    final result = edge.InferenceChat(
      sessionCreator: () => _makeSession(
        detached: false,
        temperature: resolved.temperature,
        randomSeed: resolved.randomSeed,
        topK: resolved.topK,
        topP: resolved.topP,
        loraPath: resolved.loraPath,
        enableVisionModality: resolved.supportImage,
        enableAudioModality: resolved.supportAudio,
        systemInstruction: resolved.systemInstruction,
        enableThinking: resolved.enableThinking,
        modelType: resolved.modelType,
        tools: resolved.tools,
        maxOutputTokens: resolved.maxOutputTokens,
        toolChoice: _llamaToolChoice(resolved.toolChoice),
      ),
      maxTokens: maxTokens,
      tokenBuffer: resolved.tokenBuffer,
      supportImage: resolved.supportImage,
      supportAudio: resolved.supportAudio,
      tools: resolved.tools,
      supportsFunctionCalls: resolved.supportsFunctionCalls,
      enableThinking: resolved.enableThinking,
      modelType: resolved.modelType,
      fileType: fileType,
      toolChoice: resolved.toolChoice,
      maxFunctionBufferLength: resolved.maxFunctionBufferLength,
      runtimeInjectsToolDeclarations: resolved.runtimeInjectsToolDeclarations,
      turnHooks: createChatTurnHooks(resolved),
    );
    await result.initSession();
    chat = result;
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
  Future<LlamaInferenceSession> openEngineSession(SessionRequest request) =>
      _makeSession(
        detached: true,
        temperature: request.temperature,
        randomSeed: request.randomSeed,
        topK: request.topK,
        topP: request.topP,
        loraPath: request.loraPath,
        enableVisionModality: request.enableVisionModality,
        enableAudioModality: request.enableAudioModality,
        systemInstruction: request.systemInstruction,
        enableThinking: request.enableThinking,
        modelType: request.modelType,
        tools: request.tools,
        maxOutputTokens: request.maxOutputTokens,
        toolChoice: _llamaToolChoice(request.toolChoice),
      );

  static llama.ToolChoice _llamaToolChoice(edge.ToolChoice choice) =>
      switch (choice) {
        edge.ToolChoice.auto => llama.ToolChoice.auto,
        edge.ToolChoice.required => llama.ToolChoice.required,
        edge.ToolChoice.none => llama.ToolChoice.none,
      };

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
      // Rendering without token counting reads cached metadata, not runtime
      // context. Do not wait behind the turn this replacement must cancel.
      try {
        await next.validateTools();
        _queue.ensureValid();
      } catch (error, stack) {
        if (error is llama.LlamaStateException) _queue.invalidate(error, stack);
        Error.throwWithStackTrace(runtimeError(error), stack);
      }
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
