import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart' show edgeAiLog, toolCallsOf;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'engine_queue.dart';
import 'llama_tool.dart';
import 'lora_path.dart' if (dart.library.io) 'lora_path_native.dart';

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
    this.defaultLoraPath,
    this.outputLimit,
    this.toolChoice = llama.ToolChoice.auto,
    List<edge.Tool> tools = const [],
  }) : _queue = queue ?? EngineQueue(),
       _tools = SchemaToolDefinition.fromTools(tools) {
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      _history.add(
        llama.LlamaChatMessage.fromText(
          role: llama.LlamaChatRole.system,
          text: systemInstruction,
        ),
      );
    }
    if (_tools.map((t) => t.name).toSet().length != _tools.length) {
      throw ArgumentError('Tool names must be unique.');
    }
    if (toolChoice == llama.ToolChoice.required && _tools.isEmpty) {
      throw ArgumentError('ToolChoice.required needs at least one tool.');
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

  /// Model-level adapter already loaded with the weights.
  final String? defaultLoraPath;

  /// Explicit generation cap; null uses the remaining rendered context.
  final int? outputLimit;

  /// Tool policy forwarded to the GGUF template and request planner.
  final llama.ToolChoice toolChoice;

  final EngineQueue _queue;
  final List<SchemaToolDefinition> _tools;
  final Map<String, String> _replayAliases = {};

  /// Number of hidden reasoning characters in the current or last turn.
  int hiddenThinkingCharacters = 0;
  final List<llama.LlamaChatMessage> _history = [];
  final List<llama.LlamaChatMessage> _pending = [];
  final List<edge.Message> _transcript = [];
  final List<edge.Message> _pendingTranscript = [];
  // IDs remain reserved while their visible turns remain in fullHistory.
  final Set<String> _committedCallIds = {};
  Completer<void>? _done;
  Completer<void>? _abort;
  Future<void>? _closing;
  bool _ownsEngine = false;
  bool _closed = false;
  bool _stopped = false;
  bool _userStopped = false;
  int _callSequence = 0;
  edge.SessionMetrics _metrics = edge.SessionMetrics();

  /// Current visible transcript, including staged input.
  List<edge.Message> get messages =>
      List.unmodifiable([..._transcript, ..._pendingTranscript]);

  /// Preflight the active template before replacing a usable legacy session.
  Future<void> validateTools() async {
    if (_tools.isEmpty) return;
    final rendered = await engine.chatTemplate(
      [
        ..._history,
        llama.LlamaChatMessage.fromText(
          role: llama.LlamaChatRole.user,
          text: 'Hello',
        ),
      ],
      tools: _tools,
      toolChoice: toolChoice,
      parallelToolCalls: true,
      enableThinking: enableThinking,
      includeTokenCount: false,
    );
    final parameterFormats = {
      llama.ChatFormat.glm45.index,
      llama.ChatFormat.laguna.index,
      llama.ChatFormat.hunyuanV3.index,
    };
    if (parameterFormats.contains(rendered.format) &&
        _tools.any((tool) => tool.requiresFullSchema)) {
      throw UnsupportedError(
        'This model grammar cannot preserve the supplied JSON Schema constraints with the pinned llamadart version. Use simple typed properties or another model format.',
      );
    }
  }

  String _nextCallId(Set<String> reserved) {
    String id;
    do {
      id = (_callSequence++).toRadixString(36).padLeft(9, '0');
      if (id.length > 9) {
        throw StateError('Tool-call identifier space exhausted.');
      }
    } while (reserved.contains(id));
    return id;
  }

  void _ensureOpen() {
    _queue.ensureValid();
    if (_closed) throw StateError('The session is closed.');
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
    ..._committedCallIds,
    for (final message in _history.followedBy(_pending))
      for (final part in message.parts)
        if (part is llama.LlamaToolCallContent && part.id != null) part.id!,
  };

  @override
  Future<void> addQueryChunk(edge.Message message) async {
    _ensureOpen();
    if (_done != null) {
      throw StateError('Wait for generation before adding input.');
    }
    final parts = <llama.LlamaContentPart>[];
    var role = message.isUser
        ? llama.LlamaChatRole.user
        : llama.LlamaChatRole.assistant;
    if (message.type == edge.MessageType.toolResponse) {
      final calls = _unansweredCalls();
      final suppliedId = message.toolCallId;
      final explicitId = _replayAliases[suppliedId] ?? suppliedId;
      final matching = calls.values.where((c) => c.name == message.toolName);
      final call = explicitId != null
          ? calls[explicitId]
          : matching.firstOrNull;
      if (call == null || call.name != message.toolName) {
        throw ArgumentError('Tool result has no matching unanswered call.');
      }
      final Object? result;
      try {
        result = jsonDecode(message.text);
      } on FormatException {
        throw ArgumentError('Tool results must contain valid JSON.');
      }
      parts.add(
        llama.LlamaToolResultContent(
          id: call.id,
          name: call.name,
          result: result,
        ),
      );
      _replayAliases.removeWhere((_, id) => id == call.id);
      role = llama.LlamaChatRole.tool;
    } else if (message.type == edge.MessageType.toolCall) {
      final usedIds = _usedCallIds();
      try {
        final calls = toolCallsOf(message);
        if (calls.isEmpty) throw const FormatException();
        // Reserve every caller-provided ID before generating any missing ID,
        // including IDs on later calls in the same parallel batch.
        final reservedIds = {...usedIds};
        final suppliedIds = <String>{};
        final outstanding = _unansweredCalls();
        final aliases = <String, String>{};
        for (final item in calls) {
          final id = item.id;
          if (id != null) {
            if (!suppliedIds.add(id) ||
                outstanding.containsKey(id) ||
                _replayAliases.containsKey(id)) {
              throw const FormatException();
            }
            reservedIds.add(id);
          }
        }
        for (final item in calls) {
          final name = item.name;
          // Core freezes recorded arguments recursively. Own a mutable copy.
          final args =
              jsonDecode(jsonEncode(item.args)) as Map<String, dynamic>;
          final supplied = item.id;
          var id = supplied;
          if (id == null || !_validCallId(id) || usedIds.contains(id)) {
            id = _nextCallId(reservedIds);
            reservedIds.add(id);
          }
          if (!_tools.any((tool) => tool.name == name) || !usedIds.add(id)) {
            throw const FormatException();
          }
          if (supplied != null) aliases[supplied] = id;
          parts.add(
            llama.LlamaToolCallContent(
              id: id,
              name: name,
              arguments: args,
              rawJson: jsonEncode(args),
            ),
          );
        }
        _replayAliases.addAll(aliases);
      } on FormatException {
        throw ArgumentError(
          'Replayed tool calls need declared names, unique IDs and JSON object arguments.',
        );
      } on JsonUnsupportedObjectError {
        throw ArgumentError(
          'Replayed tool arguments must contain JSON values.',
        );
      } on TypeError {
        throw ArgumentError(
          'Replayed tool calls need declared names, unique IDs and JSON object arguments.',
        );
      }
      role = llama.LlamaChatRole.assistant;
    } else if (message.type == edge.MessageType.thinking) {
      parts.add(llama.LlamaThinkingContent(message.text));
      role = llama.LlamaChatRole.assistant;
    } else if (message.type == edge.MessageType.text) {
      if (message.isUser && _unansweredCalls().isNotEmpty) {
        throw StateError(
          'Answer outstanding tool calls before starting a new user turn.',
        );
      }
      if (message.hasImage && !enableVision ||
          message.hasAudio && !enableAudio) {
        throw UnsupportedError(
          'Enable the corresponding modality on the model and session first.',
        );
      }
      final images = message.images.isNotEmpty
          ? message.images
          : [if (message.imageBytes != null) message.imageBytes!];
      if (maxImages != null && images.length > maxImages!) {
        throw ArgumentError('This message exceeds maxNumImages ($maxImages).');
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
        throw ArgumentError(
          'Input must contain nonempty text or encoded media.',
        );
      }
    } else {
      throw UnsupportedError(
        'Display-only systemInfo messages cannot be model input.',
      );
    }
    if (role == llama.LlamaChatRole.assistant &&
        _pending.lastOrNull?.role == role) {
      final previous = _pending.removeLast();
      _pending.add(
        llama.LlamaChatMessage.withContent(
          role: role,
          content: [...previous.parts, ...parts],
        ),
      );
    } else {
      _pending.add(
        llama.LlamaChatMessage.withContent(role: role, content: parts),
      );
    }
    // Preserve explicit pairing even when ordinary results arrive out of order.
    edge.Message recorded = message;
    if (message.type == edge.MessageType.toolResponse) {
      final result = parts.single as llama.LlamaToolResultContent;
      recorded = edge.Message(
        text: message.text,
        toolName: message.toolName,
        type: edge.MessageType.toolResponse,
        isUser: true,
        toolCallId: result.id,
      );
    } else if (message.type == edge.MessageType.toolCall) {
      recorded = _toolCallMessage(
        parts.whereType<llama.LlamaToolCallContent>(),
      );
    }
    _pendingTranscript.add(recorded);
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
  Stream<edge.ModelResponse> getResponses({int? tokenBuffer}) {
    _ensureOpen();
    late final StreamController<edge.ModelResponse> controller;
    Completer<void>? ownedGeneration;
    controller = StreamController<edge.ModelResponse>(
      onListen: () {
        if (_closed ||
            _done != null ||
            (_pending.isEmpty &&
                _history.lastOrNull?.role != llama.LlamaChatRole.tool &&
                _history.lastOrNull?.role != llama.LlamaChatRole.user)) {
          controller.addError(
            StateError(
              'The session must be open, idle, and have staged input.',
            ),
          );
          unawaited(controller.close());
          return;
        }
        _done = ownedGeneration = Completer<void>();
        _abort = Completer<void>();
        _stopped = false;
        _userStopped = false;
        hiddenThinkingCharacters = 0;
        _metrics = edge.SessionMetrics();

        unawaited(_generate(controller, tokenBuffer));
      },
      onCancel: () async {
        if (ownedGeneration != null && identical(_done, ownedGeneration)) {
          await stopGeneration();
        }
      },
    );
    return controller.stream;
  }

  /// Commits completed replay turns; a trailing user input remains staged.
  void commitReplay() {
    _ensureOpen();
    if (_done != null) {
      throw StateError('Wait for generation before restoring history.');
    }
    // A trailing restored user input still needs a successful assistant turn.
    final trailingUsers = _pending.reversed
        .takeWhile((m) => m.role == llama.LlamaChatRole.user)
        .length;
    final count = _pending.length - trailingUsers;
    _history.addAll(_pending.take(count));
    _rememberCallIds(_pending.take(count));
    final trailingMessages = trailingUsers > 0
        ? _pendingTranscript.reversed
              .takeWhile((m) => m.isUser && m.type == edge.MessageType.text)
              .length
        : 0;
    _transcript.addAll(
      _pendingTranscript.take(_pendingTranscript.length - trailingMessages),
    );
    _pending.removeRange(0, count);
    _pendingTranscript.removeRange(
      0,
      _pendingTranscript.length - trailingMessages,
    );
    _orderTranscriptResults();
    _orderRuntimeResults(_history);
  }

  // Only drop complete turns before the latest user input. A tool round trip
  // remains in its originating turn, even when names repeat or calls are parallel.
  bool _dropOldestTurn(List<llama.LlamaChatMessage> history) {
    final combined = [...history, ..._pending];
    final first = combined.indexWhere(
      (m) => m.role == llama.LlamaChatRole.user,
    );
    if (first < 0 || first >= history.length) return false;
    final next = combined.indexWhere(
      (m) => m.role == llama.LlamaChatRole.user,
      first + 1,
    );
    if (next < 0) return false;
    history.removeRange(first, math.min(next, history.length));
    return true;
  }

  void _rememberCallIds(Iterable<llama.LlamaChatMessage> messages) {
    _committedCallIds.addAll([
      for (final message in messages)
        for (final call
            in message.parts.whereType<llama.LlamaToolCallContent>())
          call.id!,
    ]);
  }

  void _orderTranscriptResults() {
    var order = <String, int>{};
    for (var index = 0; index < _transcript.length; index++) {
      final message = _transcript[index];
      if (message.type == edge.MessageType.toolCall) {
        for (final call in toolCallsOf(message)) {
          order[call.id!] = order.length;
        }
      } else if (message.isUser && message.type == edge.MessageType.text) {
        order = {};
      } else if (message.type == edge.MessageType.toolResponse) {
        var end = index;
        while (end < _transcript.length &&
            _transcript[end].type == edge.MessageType.toolResponse) {
          end++;
        }
        final results = _transcript.sublist(index, end);
        results.sort(
          (a, b) =>
              (order[a.toolCallId] ?? 0).compareTo(order[b.toolCallId] ?? 0),
        );
        _transcript.setRange(index, end, results);
        index = end - 1;
      }
    }
  }

  void _orderRuntimeResults(List<llama.LlamaChatMessage> messages) {
    final order = <String?, int>{};
    for (final message in _history.followedBy(_pending)) {
      for (final call
          in message.parts.whereType<llama.LlamaToolCallContent>()) {
        order[call.id] = order.length;
      }
    }
    for (var index = 0; index < messages.length; index++) {
      if (messages[index].role != llama.LlamaChatRole.tool) continue;
      var end = index + 1;
      while (end < messages.length &&
          messages[end].role == llama.LlamaChatRole.tool) {
        end++;
      }
      final results = messages.sublist(index, end)
        ..sort(
          (
            a,
            b,
          ) => (order[(a.parts.single as llama.LlamaToolResultContent).id] ?? 0)
              .compareTo(
                order[(b.parts.single as llama.LlamaToolResultContent).id] ?? 0,
              ),
        );
      messages.setRange(index, end, results);
      index = end - 1;
    }
  }

  void _commitAnsweredResults() {
    _orderRuntimeResults(_pending);
    // Only results answering committed calls survive a generation rollback.
    // Replayed calls/results remain staged together until the replay commits.
    final committedIds = {
      for (final message in _history)
        for (final part
            in message.parts.whereType<llama.LlamaToolCallContent>())
          part.id,
    };
    var recorded = false;
    for (final message
        in _pending
            .where(
              (m) =>
                  m.role == llama.LlamaChatRole.tool &&
                  m.parts.whereType<llama.LlamaToolResultContent>().any(
                    (p) => committedIds.contains(p.id),
                  ),
            )
            .toList()) {
      final result = message.parts.single as llama.LlamaToolResultContent;
      final index = _pendingTranscript.indexWhere(
        (m) =>
            m.type == edge.MessageType.toolResponse &&
            m.toolName == result.name &&
            (m.toolCallId == null || m.toolCallId == result.id),
      );
      _history.add(message);
      _pending.remove(message);
      if (index >= 0) {
        _transcript.add(_pendingTranscript.removeAt(index));
        recorded = true;
      }
    }
    if (recorded) {
      _orderTranscriptResults();
      _orderRuntimeResults(_history);
    }
  }

  Future<void> _generate(
    StreamController<edge.ModelResponse> controller,
    int? tokenBuffer,
  ) async {
    final done = _done!;
    var reportedError = false;
    try {
      await _queue.run<void>(() async {
        if (_stopped || _closed) return;
        _ownsEngine = true;
        final override = loraPath != null && loraPath != defaultLoraPath;
        final adapter = override ? llama.ModelSource.path(loraPath!) : null;
        final baseline = defaultLoraPath == null
            ? null
            : llama.ModelSource.path(defaultLoraPath!);
        var adapterApplied = false;
        var baselineRemoved = false;
        Object? primaryError;
        try {
          if (_unansweredCalls().isNotEmpty) {
            throw StateError(
              'Every tool call must have a result before generation.',
            );
          }
          _commitAnsweredResults();
          if (adapter != null) {
            await validateLoraPath(loraPath!);
            if (baseline != null) {
              baselineRemoved = true;
              await engine.removeLoraSource(baseline);
            }
            // Attempt removal on failure too: a rejected load may have
            // partially changed runtime state before it raised an error.
            adapterApplied = true;
            await engine.setLoraSource(adapter);
          }
          if (_stopped || _closed) return;
          final retainedHistory = List<llama.LlamaChatMessage>.of(_history);
          late List<llama.LlamaChatMessage> messages;
          late int promptTokens;
          while (true) {
            messages = [...retainedHistory, ..._pending];
            final rendered = await engine.chatTemplate(
              messages,
              enableThinking: enableThinking,
              includeTokenCount: true,
              tools: _tools,
              toolChoice: toolChoice,
              parallelToolCalls: true,
            );
            promptTokens =
                rendered.tokenCount ??
                await engine.getTokenCount(rendered.prompt);
            if (_stopped || _closed) return;
            if (tokenBuffer == null ||
                contextSize - promptTokens >= math.max(1, tokenBuffer) ||
                !_dropOldestTurn(retainedHistory)) {
              break;
            }
          }
          final remaining = contextSize - promptTokens;
          if (remaining <= 0) {
            throw StateError(
              'The rendered prompt ($promptTokens tokens) fills the $contextSize-token context. Shorten the latest input or increase the context.',
            );
          }
          final generationLimit = math.min(outputLimit ?? remaining, remaining);
          if (_stopped || _closed) return;
          final stopwatch = Stopwatch()..start();
          double? firstTokenMs;
          final completion = await engine
              .create(
                messages,
                params: params.copyWith(maxTokens: generationLimit),
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
                if (!enableThinking && thinking != null) {
                  hiddenThinkingCharacters += thinking.length;
                }
                if (enableThinking && thinking != null && thinking.isNotEmpty) {
                  firstTokenMs ??= stopwatch.elapsedMicroseconds / 1000;
                  controller.add(edge.ThinkingResponse(thinking));
                }
                return chunk;
              })
              .collect();
          if (_stopped || _closed) return;
          if (completion.finishReason?.wireValue == 'length' &&
              (_tools.isNotEmpty || completion.text.trim().isEmpty)) {
            throw StateError(
              'Generation reached its token limit before completing a tool or visible answer. Increase maxOutputTokens/context size and retry.',
            );
          }
          if (completion.text.trim().isEmpty && completion.toolCalls.isEmpty) {
            throw StateError(
              'The model completed without a visible answer or tool call; retry with a larger output budget${enableThinking ? " or disable thinking" : ""}.',
            );
          }
          final calls = <llama.LlamaToolCallContent>[];
          final usedIds = _usedCallIds();
          final emittedIds = <String>{};
          for (final call in completion.toolCalls) {
            if (toolChoice == llama.ToolChoice.none ||
                !_tools.any((t) => t.name == call.name)) {
              throw StateError(
                'The model returned an undeclared or disabled tool call.',
              );
            }
            final Object? args;
            try {
              args = call.rawJson.trim().isEmpty
                  ? <String, dynamic>{}
                  : jsonDecode(call.rawJson);
            } on FormatException {
              throw StateError(
                'The model returned malformed JSON tool arguments.',
              );
            }
            if (args is! Map<String, dynamic>) {
              throw StateError(
                'Tool arguments must be a complete JSON object.',
              );
            }
            if (call.id != null && !emittedIds.add(call.id!)) {
              throw StateError(
                'The model returned duplicate tool-call identifiers.',
              );
            }
            var id = call.id;
            if (id == null || !_validCallId(id) || usedIds.contains(id)) {
              do {
                id = _nextCallId(usedIds);
              } while (usedIds.contains(id));
            }
            usedIds.add(id);
            calls.add(
              llama.LlamaToolCallContent(
                id: id,
                name: call.name,
                arguments: args,
                rawJson: jsonEncode(args),
              ),
            );
          }
          if (calls.map((c) => c.id).toSet().length != calls.length) {
            throw StateError(
              'The model returned duplicate tool-call identifiers.',
            );
          }
          if (toolChoice == llama.ToolChoice.required && calls.isEmpty) {
            throw StateError(
              'ToolChoice.required completed without a tool call.',
            );
          }
          if (adapterApplied) {
            await engine.removeLoraSource(adapter!);
            adapterApplied = false;
          }
          if (baselineRemoved) {
            await engine.setLoraSource(baseline!);
            baselineRemoved = false;
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
          _history
            ..clear()
            ..addAll(retainedHistory)
            ..addAll([..._pending, assistant]);
          _rememberCallIds([..._pending, assistant]);
          _transcript.addAll(_pendingTranscript);
          if (_pendingTranscript.any(
            (m) => m.type == edge.MessageType.toolResponse,
          )) {
            _orderTranscriptResults();
          }
          _pending.clear();
          _pendingTranscript.clear();
          if (enableThinking && completion.thinking.isNotEmpty) {
            _transcript.add(edge.Message.thinking(text: completion.thinking));
          }
          if (completion.text.isNotEmpty) {
            _transcript.add(edge.Message.text(text: completion.text));
          }
          if (calls.isNotEmpty) {
            _transcript.add(_toolCallMessage(calls));
          }
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
          final responses = <edge.FunctionCallResponse>[
            for (final call in calls)
              edge.FunctionCallResponse(
                id: call.id!,
                name: call.name,
                args: call.arguments,
              ),
          ];
          if (responses.length == 1) controller.add(responses.single);
          if (responses.length > 1) {
            controller.add(edge.ParallelFunctionCallResponse(calls: responses));
          }
        } catch (error, stack) {
          primaryError = error;
          // State exceptions are classified centrally by EngineQueue. The SDK
          // also reports native exception poisoning through other subclasses.
          if (error is llama.LlamaException &&
              error.message.startsWith('llama.cpp raised an exception')) {
            _queue.invalidate(error, stack);
          }
          rethrow;
        } finally {
          Object? cleanupError;
          StackTrace? cleanupStack;
          Future<void> recover(Future<void> Function() action) async {
            try {
              await action();
            } catch (error, stack) {
              _queue.invalidate(error, stack);
              cleanupError ??= error;
              cleanupStack ??= stack;
            }
          }

          try {
            if (adapterApplied) {
              await recover(() => engine.removeLoraSource(adapter!));
            }
            if (baselineRemoved) {
              await recover(() => engine.setLoraSource(baseline!));
            }
          } finally {
            _ownsEngine = false;
          }
          if (cleanupError != null) {
            if (primaryError != null) {
              edgeAiLog(
                'GGUF runtime cleanup failed after $primaryError: $cleanupError',
              );
            } else {
              Error.throwWithStackTrace(cleanupError!, cleanupStack!);
            }
          }
        }
      }, cancelled: _abort!.future);
      // Model teardown aborts queued work too; it must not look like user stop.
      _queue.ensureValid();
      if (_closed && !_userStopped) {
        throw StateError('The model/session closed during generation.');
      }
    } catch (error, stack) {
      if (_queue.isInvalid || !_userStopped) {
        reportedError = true;
        controller.addError(error, stack);
      }
    } finally {
      // A waiter can be stopped before acquiring the runtime queue.
      try {
        _commitAnsweredResults();
      } catch (error, stack) {
        if (!reportedError) {
          controller.addError(error, stack);
        } else {
          edgeAiLog('GGUF history cleanup failed: $error\n$stack');
        }
      } finally {
        _pending.clear();
        _pendingTranscript.clear();
        _replayAliases.clear();
        _done = null;
        _abort = null;
        done.complete();
        unawaited(controller.close());
      }
    }
  }

  @override
  Future<int> sizeInTokens(String text) async {
    _ensureOpen();
    if (_done != null) {
      throw StateError(
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
    if (!_closed) _userStopped = true;
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
    try {
      await stopGeneration();
      _commitAnsweredResults();
    } finally {
      _pending.clear();
      _history.clear();
      _pendingTranscript.clear();
      _replayAliases.clear();
      onClose();
    }
  }
}

final _callIdPattern = RegExp(r'^[a-zA-Z0-9]{9}$');
bool _validCallId(String id) => _callIdPattern.hasMatch(id);

edge.Message _toolCallMessage(Iterable<llama.LlamaToolCallContent> calls) =>
    edge.Message.toolCall(
      calls: [
        for (final call in calls)
          edge.FunctionCallResponse(
            id: call.id,
            name: call.name,
            args: call.arguments,
          ),
      ],
    );
