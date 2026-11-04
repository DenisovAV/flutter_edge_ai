import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart'
    show EngineTurn, edgeAiLog, toolCallsOf;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'engine_queue.dart';
import 'llama_tool.dart';
import 'lora_path.dart' if (dart.library.io) 'lora_path_native.dart';
import 'structured_output_schema.dart';

/// An independent dialogue replayed through a model-owned runtime context.
///
/// Successful turns commit atomically. Interrupted turns are rolled back in
/// both the low-level session and the high-level chat transcript.
///
/// A session with a [responseFormat] differs in three ways. Its turns are
/// generated under llamadart's grammar for the format, with thinking off.
/// Every turn that streamed a reply is recorded, whatever its end — the
/// input and the reply streamed so far, as core's chat records a structured
/// reply before its check throws — because the chat's history is this
/// session's [messages]. And a turn cut by the output cap, the context, a
/// stop or a close ends its text cleanly: [startTurn]'s end says which, and
/// core turns it into the format's error. A turn with no reply (stopped
/// while queued or before its first token, or an input the context cannot
/// hold) is rolled back as a plain one is.
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
    this.responseFormat,
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

  /// What every reply must be, enforced by llamadart's grammar; core checks
  /// each reply too. Null for a plain session.
  final edge.JsonSchemaResponseFormat? responseFormat;

  final EngineQueue _queue;
  final List<SchemaToolDefinition> _tools;
  final Map<String, String> _replayAliases = {};

  /// The token buffer of the chat this session serves, set by its turn
  /// hooks. A structured turn runs through [startTurn], not the chat's
  /// [getResponses], so it reads the buffer here and drops the oldest turns
  /// to keep it free, as a plain chat turn does.
  int? chatTokenBuffer;

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
  Stream<String> getResponseAsync() => startTurn().text;

  /// One turn, with how it ended: [edge.TurnEnd.stopped] for this session's
  /// stop or a cancelled subscription, [edge.TurnEnd.closed] for a close
  /// during the turn, [edge.TurnEnd.outputLimit] or
  /// [edge.TurnEnd.contextLimit] for llamadart's `length` finish (whichever
  /// budget the request ran out of), else [edge.TurnEnd.endOfSequence]. An
  /// error ends the text, and then the end is [edge.TurnEnd.closed], unread.
  @override
  EngineTurn startTurn() {
    final turn = _startTurn(responseFormat == null ? null : chatTokenBuffer);
    return EngineTurn(text: turn.responses.map(_responseText), end: turn.end);
  }

  static String _responseText(edge.ModelResponse response) =>
      switch (response) {
        edge.TextResponse(:final token) => token,
        edge.ThinkingResponse() => '',
        edge.FunctionCallResponse(:final name, :final args) => jsonEncode({
          'name': name,
          'arguments': args,
        }),
        edge.ParallelFunctionCallResponse(:final calls) => jsonEncode({
          'tool_calls': [
            for (final call in calls)
              {'name': call.name, 'arguments': call.args},
          ],
        }),
      };

  /// Typed output used by the connector chat, without model-family text parsing.
  Stream<edge.ModelResponse> getResponses({int? tokenBuffer}) =>
      _startTurn(tokenBuffer).responses;

  ({Stream<edge.ModelResponse> responses, Future<edge.TurnEnd> end}) _startTurn(
    int? tokenBuffer,
  ) {
    _ensureOpen();
    late final StreamController<edge.ModelResponse> controller;
    Completer<void>? ownedGeneration;
    final end = Completer<edge.TurnEnd>();
    // The end follows the text: it completes once the text's done event is
    // delivered, or once the consumer has cancelled.
    void finish(edge.TurnEnd how) => unawaited(
      controller.close().whenComplete(() {
        if (!end.isCompleted) end.complete(how);
      }),
    );
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
          finish(edge.TurnEnd.closed);
          return;
        }
        _done = ownedGeneration = Completer<void>();
        _abort = Completer<void>();
        _stopped = false;
        _userStopped = false;
        hiddenThinkingCharacters = 0;
        _metrics = edge.SessionMetrics();

        unawaited(_generate(controller, tokenBuffer, finish));
      },
      onCancel: () async {
        if (ownedGeneration != null && identical(_done, ownedGeneration)) {
          await stopGeneration();
        }
      },
    );
    return (responses: controller.stream, end: end.future);
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
    void Function(edge.TurnEnd) finish,
  ) async {
    final done = _done!;
    final format = responseFormat;
    final structured = format != null;
    var reportedError = false;
    // How the turn ended, once the generation has decided it; a stop or a
    // close that cut it short leaves it null.
    edge.TurnEnd? reached;
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
        // Before a commit: a restore that fails then fails the turn instead
        // of following a recorded reply.
        Future<void> restoreAdapters() async {
          if (adapterApplied) {
            await engine.removeLoraSource(adapter!);
            adapterApplied = false;
          }
          if (baselineRemoved) {
            await engine.setLoraSource(baseline!);
            baselineRemoved = false;
          }
        }

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
          // Sent explicitly with a format: core refuses thinking with one,
          // and llamadart's `create` defaults to thinking on.
          final thinking = structured ? false : enableThinking;
          final llamaFormat = structured ? llamaResponseFormat(format) : null;
          late List<llama.LlamaChatMessage> messages;
          late int promptTokens;
          late llama.LlamaChatTemplateResult rendered;
          while (true) {
            messages = [...retainedHistory, ..._pending];
            rendered = await engine.chatTemplate(
              messages,
              enableThinking: thinking,
              includeTokenCount: true,
              tools: _tools,
              toolChoice: toolChoice,
              parallelToolCalls: true,
              responseFormat: llamaFormat,
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
            reached = edge.TurnEnd.contextLimit;
            // Nothing was generated: the turn is rolled back below, and a
            // structured one ends cleanly for core to report.
            if (structured) return;
            throw StateError(
              'The rendered prompt ($promptTokens tokens) fills the $contextSize-token context. Shorten the latest input or increase the context.',
            );
          }
          final generationLimit = math.min(outputLimit ?? remaining, remaining);
          // A `length` finish ran out of the app's cap when that was the
          // smaller budget, else out of the context.
          final lengthEnd = outputLimit != null && outputLimit! <= remaining
              ? edge.TurnEnd.outputLimit
              : edge.TurnEnd.contextLimit;
          if (_stopped || _closed) return;
          final stopwatch = Stopwatch()..start();
          double? firstTokenMs;
          final contentFilter = _LeadingThoughtFilter(
            enabled: !thinking && _hasClosedThinkingPrompt(rendered),
          );
          final visibleTextBuffer = StringBuffer();
          void emitVisible(String text) {
            if (text.isEmpty) return;
            visibleTextBuffer.write(text);
            firstTokenMs ??= stopwatch.elapsedMicroseconds / 1000;
            controller.add(edge.TextResponse(text));
          }

          final completion = await engine
              .create(
                messages,
                params: params.copyWith(maxTokens: generationLimit),
                enableThinking: thinking,
                tools: _tools,
                toolChoice: toolChoice,
                parallelToolCalls: true,
                responseFormat: llamaFormat,
              )
              .takeWhile((_) => !_stopped && !_closed)
              .map((chunk) {
                final delta = chunk.choices.firstOrNull?.delta;
                final content = delta?.content;
                final reasoning = delta?.thinking;
                if (content != null && content.isNotEmpty) {
                  final hiddenBefore = contentFilter.hiddenCharacters;
                  emitVisible(contentFilter.add(content));
                  hiddenThinkingCharacters +=
                      contentFilter.hiddenCharacters - hiddenBefore;
                }
                if (!enableThinking && reasoning != null) {
                  hiddenThinkingCharacters += reasoning.length;
                }
                if (enableThinking &&
                    reasoning != null &&
                    reasoning.isNotEmpty) {
                  firstTokenMs ??= stopwatch.elapsedMicroseconds / 1000;
                  controller.add(edge.ThinkingResponse(reasoning));
                }
                return chunk;
              })
              .collect();
          if (_stopped || _closed) {
            // What streamed before the stop or close is the structured
            // reply core reports as incomplete, and records.
            // Recorded before the adapters are restored: a failed restore
            // after a stop is not the turn's error, and the reply streamed.
            if (structured) {
              _commitStructuredTurn(
                retainedHistory,
                visibleTextBuffer.toString(),
              );
            }
            return;
          }
          final hiddenBefore = contentFilter.hiddenCharacters;
          emitVisible(contentFilter.finish());
          hiddenThinkingCharacters +=
              contentFilter.hiddenCharacters - hiddenBefore;
          final visibleText = visibleTextBuffer.toString();
          final atLimit = completion.finishReason?.wireValue == 'length';
          if (structured) {
            // Core checks the reply against the format and reports a cut
            // one; there are no tools to run.
            await restoreAdapters();
            reached = atLimit ? lengthEnd : edge.TurnEnd.endOfSequence;
            _commitStructuredTurn(retainedHistory, visibleText);
            _metrics = _metricsOf(completion, promptTokens, firstTokenMs);
            return;
          }
          if (atLimit && (_tools.isNotEmpty || visibleText.trim().isEmpty)) {
            throw StateError(
              'Generation reached its token limit before completing a tool or visible answer. Increase maxOutputTokens/context size and retry.',
            );
          }
          if (visibleText.trim().isEmpty && completion.toolCalls.isEmpty) {
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
          await restoreAdapters();
          if (_stopped || _closed) return;
          final assistant = llama.LlamaChatMessage.withContent(
            role: llama.LlamaChatRole.assistant,
            content: [
              if (completion.thinking.isNotEmpty)
                llama.LlamaThinkingContent(completion.thinking),
              if (visibleText.isNotEmpty) llama.LlamaTextContent(visibleText),
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
          if (visibleText.isNotEmpty) {
            _transcript.add(edge.Message.text(text: visibleText));
          }
          if (calls.isNotEmpty) {
            _transcript.add(_toolCallMessage(calls));
          }
          _metrics = _metricsOf(completion, promptTokens, firstTokenMs);
          reached = atLimit ? lengthEnd : edge.TurnEnd.endOfSequence;
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
      // A structured turn cut by a close ends cleanly: core reports it as
      // incomplete, with what streamed.
      if (_closed && !_userStopped && !structured) {
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
          reportedError = true;
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
        // A turn that finished its commit keeps its own end, even if a stop
        // or a close arrived after it.
        finish(
          reportedError
              ? edge.TurnEnd.closed
              : reached ??
                    (!_userStopped && _closed
                        ? edge.TurnEnd.closed
                        : edge.TurnEnd.stopped),
        );
      }
    }
  }

  /// Records a structured turn that reached generation: the staged input
  /// and [visibleText]. Core records the same reply in its chat before it
  /// checks it, and the chat's history is [messages]. An empty reply is not
  /// recorded, as core records none: the input is rolled back, so the
  /// history never ends on an unanswered user turn (templates that require
  /// alternating roles refuse two in a row).
  void _commitStructuredTurn(
    List<llama.LlamaChatMessage> retainedHistory,
    String visibleText,
  ) {
    if (visibleText.isEmpty) return;
    _history
      ..clear()
      ..addAll(retainedHistory)
      ..addAll(_pending)
      ..add(
        llama.LlamaChatMessage.fromText(
          role: llama.LlamaChatRole.assistant,
          text: visibleText,
        ),
      );
    _transcript
      ..addAll(_pendingTranscript)
      ..add(edge.Message.text(text: visibleText));
    _pending.clear();
    _pendingTranscript.clear();
  }

  static edge.SessionMetrics _metricsOf(
    llama.LlamaCompletion completion,
    int promptTokens,
    double? firstTokenMs,
  ) {
    final usage = completion.usage;
    final duration = usage?.duration;
    return edge.SessionMetrics(
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

// In llamadart 0.17.5 these formats classify tags after a closed thought as text.
// Restrict compatibility handling to an empty thought at the rendered prompt end.
bool _hasClosedThinkingPrompt(llama.LlamaChatTemplateResult rendered) =>
    !rendered.thinkingForcedOpen &&
    {
      llama.ChatFormat.hermes.index,
      llama.ChatFormat.deepseekV3.index,
      llama.ChatFormat.qwen3CoderXml.index,
    }.contains(rendered.format) &&
    RegExp(r'<think>\s*</think>\s*$').hasMatch(rendered.prompt);

/// Hides only leading thought envelopes; after answer text starts, tags are text.
/// Holds partial delimiters across chunks without buffering the thought body.
class _LeadingThoughtFilter {
  _LeadingThoughtFilter({required bool enabled}) : _passthrough = !enabled;

  static const _start = '<think>';
  static const _end = '</think>';
  bool _passthrough;
  bool _insideThought = false;
  String _pending = '';
  int hiddenCharacters = 0;

  String add(String text) {
    if (_passthrough) return text;
    _pending += text;
    while (true) {
      if (_insideThought) {
        final end = _pending.indexOf(_end);
        if (end != -1) {
          hiddenCharacters += end;
          _pending = _pending.substring(end + _end.length);
          _insideThought = false;
          continue;
        }
        var kept = 0;
        for (var length = 1; length < _end.length; length++) {
          if (_pending.endsWith(_end.substring(0, length))) kept = length;
        }
        hiddenCharacters += _pending.length - kept;
        _pending = _pending.substring(_pending.length - kept);
        return '';
      }
      final opening = _pending.trimLeft();
      if (opening.startsWith(_start)) {
        _pending = opening.substring(_start.length);
        _insideThought = true;
        continue;
      }
      if (_start.startsWith(opening)) return '';
      _passthrough = true;
      final visible = _pending;
      _pending = '';
      return visible;
    }
  }

  String finish() {
    if (_insideThought) hiddenCharacters += _pending.length;
    final visible = !_insideThought && _pending.trim().isEmpty ? _pending : '';
    _pending = '';
    return visible;
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
