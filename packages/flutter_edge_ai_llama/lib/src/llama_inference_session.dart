import 'dart:async';
import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'engine_queue.dart';
import 'llama_tool.dart';

/// An independent dialogue replayed through a model-owned runtime context.
///
/// Successful turns commit atomically. Interrupted turns are rolled back in
/// both the low-level session and the high-level chat transcript.
class LlamaInferenceSession extends edge.InferenceModelSession {
  /// Creates a session; the model retains ownership of [engine].
  LlamaInferenceSession({
    required this.engine,
    required this.contextSize,
    required this.params,
    required this.onClose,
    EngineQueue? queue,
    String? systemInstruction,
    this.enableThinking = false,
    this.enableVision = false,
    this.enableAudio = false,
    this.maxImages,
    this.loraPath,
    this.toolChoice = llama.ToolChoice.auto,
    List<edge.Tool> tools = const [],
  }) : _queue = queue ?? EngineQueue(),
       _tools = tools.map(SchemaToolDefinition.new).toList() {
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      _history.add(
        llama.LlamaChatMessage.fromText(
          role: llama.LlamaChatRole.system,
          text: systemInstruction,
        ),
      );
    }
    if (_tools.map((t) => t.name).toSet().length != _tools.length) {
      throw llama.LlamaArgumentException('Tool names must be unique.');
    }
    if (toolChoice == llama.ToolChoice.required && _tools.isEmpty) {
      throw llama.LlamaArgumentException(
        'ToolChoice.required needs at least one tool.',
      );
    }
  }

  /// Shared engine, disposed only when its owning model closes.
  final llama.LlamaEngine engine;

  /// Input and output token budget.
  final int contextSize;

  /// Per-turn sampling and output settings.
  final llama.GenerationParams params;

  /// Removes this session from the model's live session collection.
  final void Function() onClose;

  /// Whether to expose typed reasoning deltas.
  final bool enableThinking;

  /// Whether image messages are enabled for this session.
  final bool enableVision;

  /// Whether audio messages are enabled for this session.
  final bool enableAudio;

  /// Per-message image limit, when configured by the model.
  final int? maxImages;

  /// Native per-session adapter, applied only during this session's turn.
  final String? loraPath;

  /// Tool policy forwarded to the GGUF template and request planner.
  final llama.ToolChoice toolChoice;

  final EngineQueue _queue;
  final List<llama.ToolDefinition> _tools;
  final List<llama.LlamaChatMessage> _history = [];
  final List<llama.LlamaChatMessage> _pending = [];
  final List<edge.Message> _transcript = [];
  final List<edge.Message> _pendingTranscript = [];
  Completer<void>? _done;
  Completer<void>? _abort;
  Future<void>? _closing;
  bool _ownsEngine = false;
  bool _closed = false;
  bool _stopped = false;
  int _callSequence = 0;
  edge.SessionMetrics _metrics = edge.SessionMetrics();

  /// Current visible transcript, including staged input.
  List<edge.Message> get messages =>
      List.unmodifiable([..._transcript, ..._pendingTranscript]);

  /// Native termination; `length` means the output budget was exhausted.
  String? lastFinishReason;

  /// True only when the most recent turn completed and committed.
  bool lastTurnCommitted = false;

  void _ensureOpen() {
    if (_closed) throw llama.LlamaStateException('The session is closed.');
  }

  Map<String, llama.LlamaToolCallContent> _unansweredCalls() {
    final calls = <String, llama.LlamaToolCallContent>{};
    for (final message in _history.followedBy(_pending)) {
      for (final part in message.parts) {
        if (part is llama.LlamaToolCallContent) calls[part.id!] = part;
        if (part is llama.LlamaToolResultContent) calls.remove(part.id);
      }
    }
    return calls;
  }

  Set<String> _usedCallIds() => {
    for (final message in _history.followedBy(_pending))
      for (final part in message.parts)
        if (part is llama.LlamaToolCallContent && part.id != null) part.id!,
  };

  @override
  Future<void> addQueryChunk(edge.Message message) async {
    _ensureOpen();
    if (_done != null) {
      throw llama.LlamaStateException(
        'Wait for generation before adding input.',
      );
    }
    final parts = <llama.LlamaContentPart>[];
    var role = message.isUser
        ? llama.LlamaChatRole.user
        : llama.LlamaChatRole.assistant;
    if (message.type == edge.MessageType.toolResponse) {
      final calls = _unansweredCalls();
      final explicitId = message is LlamaToolResponseMessage
          ? message.callId
          : null;
      final matching = calls.values.where((c) => c.name == message.toolName);
      final call = explicitId != null
          ? calls[explicitId]
          : matching.firstOrNull;
      if (call == null || call.name != message.toolName) {
        throw llama.LlamaArgumentException(
          'Tool result has no matching unanswered call.',
        );
      }
      final Object? result;
      try {
        result = jsonDecode(message.text);
      } on FormatException {
        throw llama.LlamaArgumentException(
          'Tool results must contain valid JSON.',
        );
      }
      parts.add(
        llama.LlamaToolResultContent(
          id: call.id,
          name: call.name,
          result: result,
        ),
      );
      role = llama.LlamaChatRole.tool;
    } else if (message.type == edge.MessageType.toolCall) {
      final usedIds = _usedCallIds();
      try {
        final decoded = jsonDecode(message.text) as Map<String, dynamic>;
        final calls = decoded['tool_calls'] as List;
        if (calls.isEmpty) throw const FormatException();
        for (final item in calls) {
          final call = item as Map<String, dynamic>;
          final function = call['function'] as Map<String, dynamic>;
          final name = function['name'] as String;
          final raw = function['arguments'];
          final args =
              (raw is String ? jsonDecode(raw) : raw) as Map<String, dynamic>;
          final id = call['id'] as String? ?? 'replay_${_callSequence++}';
          if (toolChoice == llama.ToolChoice.none ||
              !_tools.any((tool) => tool.name == name) ||
              id.isEmpty ||
              !usedIds.add(id)) {
            throw const FormatException();
          }
          parts.add(
            llama.LlamaToolCallContent(
              id: id,
              name: name,
              arguments: args,
              rawJson: jsonEncode(args),
            ),
          );
        }
      } on FormatException {
        throw llama.LlamaArgumentException(
          'Replayed tool calls need declared names, unique IDs and JSON object arguments.',
        );
      } on TypeError {
        throw llama.LlamaArgumentException(
          'Replayed tool calls need declared names, unique IDs and JSON object arguments.',
        );
      }
      role = llama.LlamaChatRole.assistant;
    } else if (message.type == edge.MessageType.thinking) {
      parts.add(llama.LlamaThinkingContent(message.text));
      role = llama.LlamaChatRole.assistant;
    } else if (message.type == edge.MessageType.text) {
      if (message.isUser && _unansweredCalls().isNotEmpty) {
        throw llama.LlamaStateException(
          'Answer outstanding tool calls before starting a new user turn.',
        );
      }
      if (message.hasImage && !enableVision ||
          message.hasAudio && !enableAudio) {
        throw llama.LlamaUnsupportedException(
          'Enable the corresponding modality on the model and session first.',
        );
      }
      final images = message.images.isNotEmpty
          ? message.images
          : [if (message.imageBytes != null) message.imageBytes!];
      if (maxImages != null && images.length > maxImages!) {
        throw llama.LlamaArgumentException(
          'This message exceeds maxNumImages ($maxImages).',
        );
      }
      if (message.text.isNotEmpty) {
        parts.add(llama.LlamaTextContent(message.text));
      }
      parts.addAll(
        images.map((bytes) => llama.LlamaImageContent(bytes: bytes)),
      );
      if (message.audioBytes != null) {
        parts.add(llama.LlamaAudioContent(bytes: message.audioBytes));
      }
      if (parts.isEmpty ||
          images.any((bytes) => bytes.isEmpty) ||
          message.audioBytes?.isEmpty == true) {
        throw llama.LlamaArgumentException(
          'Input must contain nonempty text or encoded media.',
        );
      }
    } else {
      throw llama.LlamaUnsupportedException(
        'Display-only systemInfo messages cannot be model input.',
      );
    }
    _pending.add(
      llama.LlamaChatMessage.withContent(role: role, content: parts),
    );
    _pendingTranscript.add(message);
  }

  @override
  Future<String> getResponse() async =>
      (await getResponseAsync().toList()).join();

  @override
  Stream<String> getResponseAsync() => getResponses().map(
    (response) => switch (response) {
      edge.TextResponse(:final token) => token,
      edge.ThinkingResponse() => '',
      edge.FunctionCallResponse(:final name, :final args) => jsonEncode({
        'name': name,
        'arguments': args,
      }),
      edge.ParallelFunctionCallResponse(:final calls) => jsonEncode({
        'tool_calls': [
          for (final call in calls) {'name': call.name, 'arguments': call.args},
        ],
      }),
    },
  );

  /// Typed output used by the connector chat, without model-family text parsing.
  Stream<edge.ModelResponse> getResponses() {
    _ensureOpen();
    late final StreamController<edge.ModelResponse> controller;
    Completer<void>? ownedGeneration;
    controller = StreamController<edge.ModelResponse>(
      onListen: () {
        if (_closed || _done != null || _pending.isEmpty) {
          controller.addError(
            llama.LlamaStateException(
              'The session must be open, idle, and have staged input.',
            ),
          );
          unawaited(controller.close());
          return;
        }
        _done = ownedGeneration = Completer<void>();
        _abort = Completer<void>();
        _stopped = false;
        lastTurnCommitted = false;
        _metrics = edge.SessionMetrics();
        lastFinishReason = null;
        unawaited(_generate(controller));
      },
      onCancel: () async {
        if (ownedGeneration != null && identical(_done, ownedGeneration)) {
          await stopGeneration();
        }
      },
    );
    return controller.stream;
  }

  Future<void> _generate(
    StreamController<edge.ModelResponse> controller,
  ) async {
    final done = _done!;
    try {
      await _queue.run<void>(() async {
        if (_stopped || _closed) return;
        _ownsEngine = true;
        final adapter = loraPath == null
            ? null
            : llama.ModelSource.path(loraPath!);
        var adapterApplied = false;
        try {
          if (_unansweredCalls().isNotEmpty) {
            throw llama.LlamaStateException(
              'Every tool call must have a result before generation.',
            );
          }
          if (adapter != null) {
            try {
              await engine.setLoraSource(adapter);
              adapterApplied = true;
            } catch (_) {
              // A failed runtime mutation cannot be assumed to leave it clean.
              _queue.invalidate();
              rethrow;
            }
          }
          if (_stopped || _closed) return;
          final messages = [..._history, ..._pending];
          final rendered = await engine.chatTemplate(
            messages,
            enableThinking: enableThinking,
            includeTokenCount: true,
            tools: _tools,
            toolChoice: toolChoice,
            parallelToolCalls: true,
          );
          final promptTokens =
              rendered.tokenCount ??
              await engine.getTokenCount(rendered.prompt);
          if (promptTokens + params.maxTokens > contextSize) {
            throw llama.LlamaContextException(
              'The rendered prompt ($promptTokens tokens) plus output budget (${params.maxTokens}) exceeds the $contextSize-token context. Start a new chat or increase the context.',
            );
          }
          if (_stopped || _closed) return;
          final stopwatch = Stopwatch()..start();
          double? firstTokenMs;
          final completion = await engine
              .create(
                messages,
                params: params,
                enableThinking: enableThinking,
                tools: _tools,
                toolChoice: toolChoice,
                parallelToolCalls: true,
              )
              .takeWhile((_) => !_stopped && !_closed)
              .map((chunk) {
                final delta = chunk.choices.firstOrNull?.delta;
                final content = delta?.content;
                final thinking = delta?.thinking;
                if (content != null && content.isNotEmpty) {
                  firstTokenMs ??= stopwatch.elapsedMicroseconds / 1000;
                  controller.add(edge.TextResponse(content));
                }
                if (enableThinking && thinking != null && thinking.isNotEmpty) {
                  firstTokenMs ??= stopwatch.elapsedMicroseconds / 1000;
                  controller.add(edge.ThinkingResponse(thinking));
                }
                return chunk;
              })
              .collect();
          if (_stopped || _closed) return;
          final calls = <llama.LlamaToolCallContent>[];
          final usedIds = _usedCallIds();
          final emittedIds = <String>{};
          for (final call in completion.toolCalls) {
            if (toolChoice == llama.ToolChoice.none ||
                !_tools.any((t) => t.name == call.name)) {
              throw llama.LlamaInferenceException(
                'The model returned an undeclared or disabled tool call.',
              );
            }
            final Object? args;
            try {
              args = jsonDecode(call.rawJson);
            } on FormatException {
              throw llama.LlamaInferenceException(
                'The model returned malformed JSON tool arguments.',
              );
            }
            if (args is! Map<String, dynamic>) {
              throw llama.LlamaInferenceException(
                'Tool arguments must be a complete JSON object.',
              );
            }
            if (call.id != null && !emittedIds.add(call.id!)) {
              throw llama.LlamaInferenceException(
                'The model returned duplicate tool-call identifiers.',
              );
            }
            var id = call.id;
            if (id == null || id.isEmpty || usedIds.contains(id)) {
              do {
                id = 'llama_${_callSequence++}';
              } while (usedIds.contains(id));
            }
            usedIds.add(id);
            calls.add(
              llama.LlamaToolCallContent(
                id: id,
                name: call.name,
                arguments: args,
                rawJson: call.rawJson,
              ),
            );
          }
          if (calls.map((c) => c.id).toSet().length != calls.length) {
            throw llama.LlamaInferenceException(
              'The model returned duplicate tool-call identifiers.',
            );
          }
          if (toolChoice == llama.ToolChoice.required && calls.isEmpty) {
            throw llama.LlamaInferenceException(
              'ToolChoice.required completed without a tool call.',
            );
          }
          if (adapterApplied) {
            try {
              await engine.removeLoraSource(adapter!);
            } catch (_) {
              _queue.invalidate();
              rethrow;
            }
            adapterApplied = false;
          }
          if (_stopped || _closed) return;
          final assistant = llama.LlamaChatMessage.withContent(
            role: llama.LlamaChatRole.assistant,
            content: [
              if (completion.thinking.isNotEmpty)
                llama.LlamaThinkingContent(completion.thinking),
              if (completion.text.isNotEmpty)
                llama.LlamaTextContent(completion.text),
              ...calls,
            ],
          );
          _history.addAll([..._pending, assistant]);
          _transcript.addAll(_pendingTranscript);
          if (enableThinking && completion.thinking.isNotEmpty) {
            _transcript.add(edge.Message.thinking(text: completion.thinking));
          }
          if (completion.text.isNotEmpty) {
            _transcript.add(edge.Message.text(text: completion.text));
          }
          if (calls.isNotEmpty) {
            _transcript.add(
              edge.Message.toolCall(text: jsonEncode(assistant.toJson())),
            );
          }
          lastFinishReason = completion.finishReason?.wireValue;
          final usage = completion.usage;
          final duration = usage?.duration;
          _metrics = edge.SessionMetrics(
            inputTokens: usage?.promptTokens ?? promptTokens,
            outputTokens: usage?.completionTokens ?? 0,
            totalTokens: usage?.totalTokens ?? promptTokens,
            timeToFirstTokenMs: usage?.timeToFirstToken == null
                ? firstTokenMs
                : usage!.timeToFirstToken!.inMicroseconds / 1000,
            tokensPerSecond: duration == null || duration.inMicroseconds == 0
                ? null
                : usage!.completionTokens * 1000000 / duration.inMicroseconds,
          );
          lastTurnCommitted = true;
          final responses = [
            for (final call in calls)
              LlamaFunctionCallResponse(
                id: call.id!,
                name: call.name,
                args: call.arguments,
              ),
          ];
          if (responses.length == 1) controller.add(responses.single);
          if (responses.length > 1) {
            controller.add(edge.ParallelFunctionCallResponse(calls: responses));
          }
        } finally {
          try {
            if (adapterApplied) {
              try {
                await engine.removeLoraSource(adapter!);
              } catch (_) {
                _queue.invalidate();
                rethrow;
              }
            }
          } finally {
            _ownsEngine = false;
          }
        }
      }, cancelled: _abort!.future);
    } catch (error, stack) {
      if (!_stopped && !_closed) controller.addError(error, stack);
    } finally {
      _pending.clear();
      _pendingTranscript.clear();
      _done = null;
      _abort = null;
      done.complete();
      unawaited(controller.close());
    }
  }

  @override
  Future<int> sizeInTokens(String text) async {
    _ensureOpen();
    if (_done != null) {
      throw llama.LlamaStateException(
        'Wait for this session to finish generating before tokenizing.',
      );
    }
    return (await _queue.run(() async {
      _ensureOpen();
      return engine.getTokenCount(text);
    }))!;
  }

  @override
  Future<void> stopGeneration() async {
    final done = _done;
    if (done == null) return;
    _stopped = true;
    if (_abort != null && !_abort!.isCompleted) _abort!.complete();
    if (_ownsEngine) engine.cancelGeneration();
    await done.future;
  }

  @override
  edge.SessionMetrics getSessionMetrics() => _metrics;

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = _close();
  }

  Future<void> _close() async {
    await stopGeneration();
    _pending.clear();
    _history.clear();
    _pendingTranscript.clear();
    _transcript.clear();
    onClose();
  }
}
