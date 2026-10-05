import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart'
    show
        FunctionCallResponse,
        InferenceChat,
        Message,
        ParallelFunctionCallResponse,
        TextResponse,
        ThinkingResponse;

import 'agent_event.dart';
import 'agent_tools.dart';
import 'skill.dart';
import 'skill_executor.dart';
import 'skill_registry.dart';
import 'skill_result.dart';
import 'secret_store.dart';

/// Orchestrates the agent turn over flutter_gemma's existing function-calling.
///
/// Given an [InferenceChat] created with the [agentTools] (and the skill
/// discovery list injected into its system prompt) plus the [registry] of
/// selected skills and the registered [executors], [run] drives one turn by
/// delegating the tool loop to core's
/// [InferenceChat.generateChatResponseWithTools] (one audited implementation of
/// the streaming + history-balancing + cancel logic) and translating its output
/// into the agent's rich [AgentEvent] stream:
///
/// 1. `TextResponse` tokens → [TextChunkEvent]s (streamed); the final, call-free
///    turn's accumulated text → [DoneEvent].
/// 2. Each tool call runs through core's `onToolCall` hook, where the agent
///    dispatches it and RETURNS the tool-response map (core feeds it back with
///    the model's original call name):
///    - `loadSkill` → return the skill's full SKILL.md instructions (lazy
///      second-stage discovery) from the [registry];
///    - `runSkill` / `runIntent` / `runMcp` → pick the first [SkillExecutor]
///      whose `canExecute` is true (highest [SkillExecutor.priority] wins) and
///      execute it.
///    The rich step events ([SkillLoadEvent] / [ToolCallEvent] /
///    [ToolResultEvent] / [AgentErrorEvent]) — which a plain `onToolCall`
///    callback cannot yield — are emitted into the stream during dispatch.
/// 3. Stop on the model's call-free answer ([DoneEvent]) or when [maxIterations]
///    is reached ([MaxIterationsEvent], surfaced via core's `onMaxToolTurns`).
///
/// [run] is a `Stream<AgentEvent>` so the UI can show progress + inline
/// image / webview / widget results as the turn unfolds.
class AgentLoop {
  AgentLoop({
    required this.registry,
    required this.executors,
    SecretStore? secretStore,
    this.maxIterations = 10,
  }) : secretStore = secretStore ?? SecretStore(),
       _executors = _sortedByPriority(executors);

  /// The selected-skills catalog (discovery + `loadSkill` lookup).
  final SkillRegistry registry;

  /// Registered executors, as supplied. Probed in [_executors] order.
  final List<SkillExecutor> executors;

  /// Runtime secrets for `require-secret` skills, injected into the executor —
  /// never into the prompt.
  final SecretStore secretStore;

  /// Hard guard against a runaway tool loop. The loop makes at most this many
  /// model generations before bailing with a [MaxIterationsEvent].
  final int maxIterations;

  /// [executors] sorted into probe order (descending priority, then registration
  /// order) — the same ordering rule as the engine/embedding registries.
  final List<SkillExecutor> _executors;

  // This comparator is intentionally identical to the core EngineRegistry /
  // SkillExecutorRegistry probe-chain sort (descending priority, then ascending
  // registration index for a stable tie-break). It is duplicated rather than
  // shared because those registries live in the core package and sort a
  // different provider type; keep the three in sync if the rule ever changes.
  static List<SkillExecutor> _sortedByPriority(List<SkillExecutor> executors) {
    final indexed = executors.indexed.toList()
      ..sort((a, b) {
        final byPriority = b.$2.priority.compareTo(a.$2.priority);
        if (byPriority != 0) return byPriority;
        return a.$1.compareTo(b.$1); // stable: earlier-registered wins ties
      });
    return [for (final e in indexed) e.$2];
  }

  /// Drive one agent turn for [userMessage] against [chat], emitting progress
  /// [AgentEvent]s. The [chat] must already have been created with [agentTools]
  /// and the skill discovery injected into its system prompt.
  ///
  /// [isCancelled], when provided, is polled between iterations — before the
  /// next generation and between dispatched calls — for barge-in: once it
  /// returns true the stream ends promptly (no [DoneEvent], no
  /// [MaxIterationsEvent]). A tool already executing still completes; only
  /// the *next* step is skipped. Tool calls the model already committed to
  /// [chat]'s history but that were not executed are answered with a
  /// synthetic `status: cancelled` tool-response, so the persistent chat is
  /// never left with a dangling half-answered call. `null` (the default)
  /// preserves prior behavior exactly.
  ///
  /// Pass [imageBytes] to attach a photo to the turn — the model then sees the
  /// image alongside [userMessage] and can call skills based on what it saw.
  ///
  /// PRECONDITION: [chat] must have been created with `supportImage: true`
  /// (see [AgentSession.fromModel]) and be backed by a multimodal model. The
  /// `supportImage: true` half is enforced with a real error (surfaced on the
  /// returned stream), because the engines below do NOT agree on what an
  /// unsupported image means: the FFI, mobile-MediaPipe and built-in-AI sessions
  /// drop it silently and answer text-only, while web MediaPipe throws
  /// `ArgumentError`. A silent drop is the worse half — the model returns a
  /// confident answer to a photo it never saw, and nothing in the event stream
  /// says so. Failing here makes the outcome identical on every platform. The
  /// "multimodal model" half cannot be checked from Dart (no capability
  /// introspection API): if the flag is set but the model is text-only, the
  /// image reaches the engine and is dropped there — a caller precondition.
  Stream<AgentEvent> run(
    InferenceChat chat,
    String userMessage, {
    bool Function()? isCancelled,
    Uint8List? imageBytes,
  }) {
    // Delegate the loop + history-balancing to core's
    // generateChatResponseWithTools (one audited implementation — cancel,
    // tool-throw and mid-stream-error balancing all live there) and translate its
    // ModelResponse stream + per-call hook into the agent's rich AgentEvent
    // stream. `onToolCall` cannot yield events (it returns the tool-response map
    // core feeds back), so dispatch emits step events through [emit] instead.
    //
    // The driver is started lazily on listen and stopped when the subscription
    // is cancelled — so disposing the chat view mid-turn (subscription.cancel())
    // halts generation + tool side-effects at the next turn/tool boundary,
    // instead of running the whole remaining loop into a dead controller.
    late final StreamController<AgentEvent> controller;
    final buffer = StringBuffer();
    var maxHit = false;
    var stopped = false; // the subscription was cancelled
    var cancelledSeen = false; // core acted on a cancel this run

    void emit(AgentEvent e) {
      if (!controller.isClosed) controller.add(e);
    }

    // Fold subscription-cancel into the caller's [isCancelled], and latch what
    // core actually acted on — so the terminal decision below matches core's
    // instead of re-polling a possibly-toggling flag.
    bool cancelled() {
      final c = stopped || (isCancelled?.call() ?? false);
      if (c) cancelledSeen = true;
      return c;
    }

    Future<void> drive() async {
      // Image precondition — checked before addQueryChunk so a rejected turn
      // writes nothing to history. Surfaces via the driver's catchError as a
      // stream error (see the doc on [run]).
      if (imageBytes != null) {
        if (!chat.supportsImages) {
          throw ArgumentError.value(
            chat,
            'chat',
            'AgentLoop.run(imageBytes:) requires a chat created with '
                'supportImage: true, backed by a multimodal model. Without it '
                'the engine drops the image and the model answers text-only.',
          );
        }
        if (imageBytes.isEmpty) {
          throw ArgumentError.value(
            imageBytes,
            'imageBytes',
            'imageBytes must not be empty.',
          );
        }
      }
      await chat.addQueryChunk(
        imageBytes == null
            ? Message(text: userMessage, isUser: true)
            : Message.withImage(
                text: userMessage,
                imageBytes: imageBytes,
                isUser: true,
              ),
      );
      await for (final r in chat.generateChatResponseWithTools(
        onToolCall: (call) {
          // A tool call ends this turn: the text streamed before it was preamble,
          // not the final answer — drop it so DoneEvent carries only the final
          // (call-free) turn's text (it was already surfaced as TextChunkEvent).
          buffer.clear();
          return _dispatch(call, emit);
        },
        maxToolTurns: maxIterations,
        isCancelled: cancelled,
        onMaxToolTurns: () {
          maxHit = true;
          emit(MaxIterationsEvent(maxIterations));
        },
      )) {
        switch (r) {
          case TextResponse(:final token):
            if (token.isEmpty) continue;
            buffer.write(token);
            emit(TextChunkEvent(token));
          case ThinkingResponse(:final content):
            // Thinking is off for the agent chat, so this never fires today; fold
            // it into the answer if it ever does (parity with the old switch).
            if (content.isEmpty) continue;
            buffer.write(content);
            emit(TextChunkEvent(content));
          case FunctionCallResponse() || ParallelFunctionCallResponse():
            break; // dispatched via onToolCall above
        }
      }
      // A barge-in (cancel) and maxToolTurns exhaustion (its own
      // MaxIterationsEvent) both end WITHOUT a DoneEvent — mirrors the
      // pre-consolidation loop.
      if (!maxHit && !cancelledSeen) {
        emit(DoneEvent(buffer.toString()));
      }
    }

    controller = StreamController<AgentEvent>(
      onListen: () {
        drive()
            .catchError((Object e, StackTrace st) {
              if (!controller.isClosed) controller.addError(e, st);
            })
            .whenComplete(() {
              if (!controller.isClosed) controller.close();
            });
      },
      onCancel: () => stopped = true,
    );
    return controller.stream;
  }

  /// Execute one [call] and feed its result back to [chat], emitting the
  /// matching progress events.
  /// The bundled SKILL.md files (verbatim from Gallery) instruct the model to
  /// "Call the `run_js` / `run_intent` tool", while the tool DECLARATIONS are
  /// named [AgentToolNames.runSkill] / `runIntent` / `runMcp`. Native decoders
  /// take the name from the structured declaration; the web decoder follows the
  /// SKILL.md text literally and calls `run_js`. Accept the SKILL.md spelling as
  /// an alias so both paths dispatch to the same executor.
  static const _toolNameAliases = <String, String>{
    'run_js': AgentToolNames.runSkill,
    'run_intent': AgentToolNames.runIntent,
    'run_mcp': AgentToolNames.runMcp,
    'load_skill': AgentToolNames.loadSkill,
  };

  /// Run one [call], emitting progress events via [emit], and RETURN the
  /// tool-response map. Core's generateChatResponseWithTools feeds it back with
  /// the model's ORIGINAL call name (so a web-decoder `run_js` gets a `run_js`
  /// response, correctly paired). The agent still normalizes the alias internally
  /// to pick the executor.
  Future<Map<String, dynamic>> _dispatch(
    FunctionCallResponse originalCall,
    void Function(AgentEvent) emit,
  ) async {
    // Normalize a SKILL.md tool-name spelling to the canonical declared name
    // (e.g. `run_js` -> `runSkill`). A native call already uses the canonical
    // name, so the alias map leaves it untouched.
    final canonical = _toolNameAliases[originalCall.name];
    final call = canonical == null
        ? originalCall
        : FunctionCallResponse(name: canonical, args: originalCall.args);
    switch (call.name) {
      case AgentToolNames.loadSkill:
        return _loadSkill(call, emit);
      case AgentToolNames.runSkill:
      case AgentToolNames.runIntent:
      case AgentToolNames.runMcp:
        return _runExecutor(call, emit);
      default:
        // Unknown tool. Small models (notably the web decoder) sometimes call
        // a skill by name as if it were a tool — e.g. `calculate-hash{...}` —
        // skipping the two-stage `loadSkill` then `run_*`. We must NOT execute
        // it directly (that would bypass the skill's instructions, which say
        // WHICH executor to use). Instead, mirror Gallery's
        // `guardMissingEntityWithSkillFallback`: if the name is a known skill,
        // hint the model to load it so it can self-correct on the next turn.
        final isKnownSkill = registry.get(call.name) != null;
        final message = isKnownSkill
            ? '"${call.name}" is a skill, not a tool. '
                  'Call ${AgentToolNames.loadSkill}(skillName: "${call.name}") '
                  'first, then follow its instructions.'
            : 'Unknown tool "${call.name}".';
        emit(AgentErrorEvent(message, toolName: call.name));
        return {'error': message, 'status': 'failed'};
    }
  }

  /// `loadSkill(skillName)` — return the full SKILL.md instructions as the
  /// tool-response map (lazy second-stage discovery).
  Future<Map<String, dynamic>> _loadSkill(
    FunctionCallResponse call,
    void Function(AgentEvent) emit,
  ) async {
    final skillName = _stringArg(call.args, 'skillName').trim();
    final skill = registry.get(skillName);

    emit(SkillLoadEvent(skillName, found: skill != null));

    if (skill == null) {
      // Mirror the unknown-tool path: surface a real error event and a
      // `status: failed` marker, rather than feeding "Skill not found" into the
      // same `skill_instructions` field real instructions occupy (which the
      // model would read as content and could act on as if a skill loaded).
      final message = 'Skill "$skillName" not found.';
      emit(AgentErrorEvent(message, toolName: call.name));
      return {'skill_name': skillName, 'error': message, 'status': 'failed'};
    }

    return {
      'skill_name': skillName,
      'skill_instructions': _skillContent(skill),
    };
  }

  /// `runSkill` / `runIntent` / `runMcp` — pick an executor by probe-chain and
  /// run it, returning the structured result map fed back to the model.
  Future<Map<String, dynamic>> _runExecutor(
    FunctionCallResponse call,
    void Function(AgentEvent) emit,
  ) async {
    // Resolve the targeted skill (skill-based calls carry a `skillName`; intent
    // and MCP calls don't, so this may be null).
    final skillName = _stringArg(call.args, 'skillName').trim();
    final skill = skillName.isEmpty ? null : registry.get(skillName);

    // `run_js` (runSkill) targets a specific skill, so it MUST carry skillName.
    // The web decoder sometimes loads a skill then calls run_js without it; we
    // must NOT guess (synthesizing a skill named after the tool asked for
    // `assets/skills/runSkill/...` → 404). Feed back a hint so the model
    // re-issues the call with skillName — the same error-feedback strategy as
    // the direct-skill-call guard. Intent/MCP calls legitimately omit skillName.
    if (call.name == AgentToolNames.runSkill && skill == null) {
      final message = skillName.isEmpty
          ? 'run_js requires a "skillName" argument naming the skill to run '
                '(the one you just loaded). Call it again with skillName set.'
          : 'Skill "$skillName" not found. Pass a valid skillName to run_js.';
      emit(AgentErrorEvent(message, toolName: call.name));
      return {'error': message, 'status': 'failed'};
    }

    // Expose an unmodifiable view so a UI consumer can't mutate the loop's own
    // parsed call args through the event.
    emit(
      ToolCallEvent(
        toolName: call.name,
        args: Map.unmodifiable(call.args),
        skill: skill,
      ),
    );

    // Map the tool call to the (data) payload + skill the executor expects.
    final probe = skill ?? _syntheticSkillFor(call);
    final executor = _pickExecutor(probe);
    if (executor == null) {
      final message = 'No executor available for "${call.name}".';
      emit(AgentErrorEvent(message, toolName: call.name));
      return {'error': message, 'status': 'failed'};
    }

    final dataJson = _dataFor(call);
    final secret = skill != null ? secretStore.get(skill.name) : null;

    SkillResult result;
    try {
      result = await executor.execute(probe, dataJson, secret: secret);
    } catch (e) {
      result = ErrorResult(e.toString());
    }

    emit(ToolResultEvent(toolName: call.name, result: result));
    if (result is ErrorResult) {
      emit(AgentErrorEvent(result.message, toolName: call.name));
    }

    return _resultToResponse(result);
  }

  /// First executor (in probe order) that can run [skill]; null if none can.
  SkillExecutor? _pickExecutor(Skill skill) {
    for (final executor in _executors) {
      if (executor.canExecuteSkill(skill)) return executor;
    }
    return null;
  }

  /// Build a stand-in [Skill] for an intent / MCP call that does not target a
  /// registered skill, so executors can still probe by [SkillType]. The
  /// synthetic skill's name carries the concrete action — the `intent` arg for
  /// `runIntent`, the `toolName` arg for `runMcp` — so the executor can resolve
  /// which whitelisted action to run from [Skill.name].
  Skill _syntheticSkillFor(FunctionCallResponse call) {
    final (type, nameArg) = switch (call.name) {
      AgentToolNames.runIntent => (SkillType.intent, 'intent'),
      AgentToolNames.runMcp => (SkillType.mcp, 'toolName'),
      _ => (SkillType.js, 'toolName'),
    };
    final resolved = _stringArg(call.args, nameArg).trim();
    return Skill(
      name: resolved.isNotEmpty ? resolved : call.name,
      description: '',
      instructions: '',
      type: type,
    );
  }

  /// The `data` payload to hand the executor. For `runSkill` it's the JS `data`
  /// arg; for `runIntent` it's the `parameters` JSON; for `runMcp` it's `input`.
  String _dataFor(FunctionCallResponse call) {
    return switch (call.name) {
      AgentToolNames.runIntent => _stringArg(call.args, 'parameters'),
      AgentToolNames.runMcp => _stringArg(call.args, 'input'),
      _ => _stringArg(call.args, 'data'),
    };
  }

  /// Convert a [SkillResult] into the `{result | image | webview | error}`-shaped
  /// map fed back to the model (mirrors Gallery's tool-response shapes).
  Map<String, dynamic> _resultToResponse(SkillResult result) {
    return switch (result) {
      TextResult(:final text) => {'result': text, 'status': 'succeeded'},
      ImageResult() => {
        'result': 'An image was produced and shown to the user.',
        'status': 'succeeded',
      },
      WidgetResult() => {
        'result': 'A widget was produced and shown to the user.',
        'status': 'succeeded',
      },
      WebviewResult(:final url) => {
        'result': 'A web view was opened for the user.',
        'webview': url,
        'status': 'succeeded',
      },
      ErrorResult(:final message) => {'error': message, 'status': 'failed'},
    };
  }

  /// The Gallery `SKILL_INSTRUCTIONS_TEMPLATE` content `loadSkill` returns.
  String _skillContent(Skill skill) =>
      '---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n\n'
      '${skill.instructions}';

  /// Read a string tool argument, tolerating a missing key or non-string value.
  String _stringArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return '';
    return value is String ? value : value.toString();
  }
}
