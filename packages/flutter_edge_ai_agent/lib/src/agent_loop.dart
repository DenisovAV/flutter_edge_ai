import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show
        FunctionCallResponse,
        InferenceChat,
        Message,
        ParallelFunctionCallResponse,
        TextResponse,
        ThinkingResponse;

import 'agent_event.dart';
import 'agent_tools.dart';
import 'executors/native_intent_executor.dart' show NativeIntentExecutor;
import 'skill.dart';
import 'skill_executor.dart';
import 'skill_registry.dart';
import 'skill_result.dart';
import 'secret_store.dart';

/// Orchestrates the agent turn over flutter_edge_ai's existing function-calling.
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
///    An answer with no text right after a successful `loadSkill` is asked
///    for again first ([emptyAfterSkillRetries]); if it stays empty the turn
///    ends with an [EmptyAnswerEvent].
///
/// [run] is a `Stream<AgentEvent>` so the UI can show progress + inline
/// image / webview / widget results as the turn unfolds.
class AgentLoop {
  /// Throws [ArgumentError] when [emptyAfterSkillRetries] is negative.
  AgentLoop({
    required this.registry,
    required this.executors,
    SecretStore? secretStore,
    this.maxIterations = 10,
    this.emptyAfterSkillRetries = 1,
    this.emptyAfterSkillNudge = defaultEmptyAfterSkillNudge,
  }) : secretStore = secretStore ?? SecretStore(),
       _executors = _sortedByPriority(executors) {
    if (emptyAfterSkillRetries < 0) {
      throw ArgumentError.value(
        emptyAfterSkillRetries,
        'emptyAfterSkillRetries',
        'must be 0 (no retry) or more',
      );
    }
  }

  /// The selected-skills catalog (discovery + `loadSkill` lookup).
  final SkillRegistry registry;

  /// Registered executors, as supplied. Probed in [_executors] order.
  final List<SkillExecutor> executors;

  /// Runtime secrets for `require-secret` skills, injected into the executor —
  /// never into the prompt.
  final SecretStore secretStore;

  /// Hard guard against a runaway tool loop. The loop makes at most this many
  /// model generations before bailing with a [MaxIterationsEvent]. Retries
  /// after an empty answer ([emptyAfterSkillRetries]) count too.
  final int maxIterations;

  /// How many times one turn asks the model again when the generation that
  /// would end the turn has no text (after trimming) right after a successful
  /// `loadSkill`. A retry emits an [EmptyAnswerRetryEvent], adds
  /// [emptyAfterSkillNudge] to the chat as a user message and generates again
  /// with the same tools, within what is left of [maxIterations] (no retry
  /// when nothing is left).
  ///
  /// When the answer is still empty and no retry is left, the turn ends with
  /// an [EmptyAnswerEvent] (a [DoneEvent] with empty text) instead of a plain
  /// [DoneEvent]. 0 turns the retry off; such a turn still ends with an
  /// [EmptyAnswerEvent]. An empty answer after any other tool result (an
  /// intent, a JS skill, an MCP tool) ends with a plain [DoneEvent], as
  /// before.
  ///
  /// FunctionGemma apps should pass 0: core clears a FunctionGemma chat's
  /// history after every text reply, so the nudge reaches a blank session and
  /// is answered without the question.
  final int emptyAfterSkillRetries;

  /// The user message a retry sends ([emptyAfterSkillRetries]). It names no
  /// skill, so one text serves every skill.
  final String emptyAfterSkillNudge;

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
  /// next generation, between dispatched calls and after an empty answer —
  /// for barge-in: once it returns true the stream ends promptly (no
  /// [DoneEvent], no [MaxIterationsEvent]). A tool already executing still
  /// completes; only the *next* step is skipped. Tool calls the model already
  /// committed to [chat]'s history but that were not executed are answered
  /// with a synthetic `status: cancelled` tool-response, so the persistent
  /// chat is never left with a dangling half-answered call. `null` (the
  /// default) preserves prior behavior exactly.
  ///
  /// To stop a turn, flip [isCancelled] or cancel the subscription BEFORE
  /// `chat.stopGeneration()`: a stopped empty generation right after a
  /// `loadSkill` is otherwise taken for an empty answer and retried
  /// ([emptyAfterSkillRetries]).
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
  ///
  /// Pass [audioBytes] to ask with a recording — the spoken question, for a
  /// model with an audio encoder (Gemma 4 E2B or E4B as `.litertlm`, on a
  /// native platform). It rides on the same first message as [userMessage] and
  /// [imageBytes]; [userMessage] may be empty when the audio carries the
  /// question. Tool-result follow-ups in the turn carry no media. The bytes
  /// reach the engine unchanged: a `.litertlm` model (LiteRT-LM) decodes an
  /// audio FILE, so send a WAV (16 kHz mono 16-bit PCM in a RIFF container), not
  /// bare PCM samples. Audio is native-only: LiteRT-LM on the web throws
  /// `UnsupportedError`, which ends the returned stream, and MediaPipe's web
  /// `.task` files have no audio encoder. After a stopped turn (a cancelled
  /// subscription), a `.litertlm` chat rebuilds its conversation from the turns'
  /// text, so the recordings of earlier turns are gone from its context.
  ///
  /// PRECONDITION, as for images: [chat] must have been created with
  /// `supportAudio: true` (see [AgentSession.fromModel]). Without it the FFI
  /// session drops the audio and the model answers as if nothing was said, so a
  /// missing flag fails the returned stream with an [ArgumentError] before
  /// anything reaches the chat's history. Empty [audioBytes] fail the same way.
  Stream<AgentEvent> run(
    InferenceChat chat,
    String userMessage, {
    bool Function()? isCancelled,
    Uint8List? imageBytes,
    Uint8List? audioBytes,
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
    final turn = _TurnCalls();
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
      if (audioBytes != null) {
        if (!chat.supportAudio) {
          throw ArgumentError.value(
            chat,
            'chat',
            'AgentLoop.run(audioBytes:) requires a chat created with '
                'supportAudio: true, backed by a model with an audio encoder. '
                'Without it the engine drops the audio and the model answers '
                'as if nothing was said.',
          );
        }
        if (audioBytes.isEmpty) {
          throw ArgumentError.value(
            audioBytes,
            'audioBytes',
            'audioBytes must not be empty.',
          );
        }
      }
      // One user message for the whole turn: its text and whatever media it
      // carries, as Message.withImage / withAudio would build them.
      await chat.addQueryChunk(
        Message(
          text: userMessage,
          isUser: true,
          imageBytes: imageBytes,
          images: imageBytes == null ? const [] : [imageBytes],
          audioBytes: audioBytes,
        ),
      );
      // Generations core may still make: all of them at first, then what an
      // empty-answer retry leaves.
      var budget = maxIterations;
      var retries = 0;
      var emptyAnswers = 0;
      while (true) {
        await for (final r in chat.generateChatResponseWithTools(
          onToolCall: (call) {
            // A tool call ends this turn: the text streamed before it was
            // preamble, not the final answer — drop it so DoneEvent carries only
            // the final (call-free) turn's text (it was already surfaced as
            // TextChunkEvent).
            buffer.clear();
            return _dispatch(call, emit, turn);
          },
          maxToolTurns: budget,
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
              // Thinking is off for the agent chat, so this never fires today;
              // fold it into the answer if it ever does (parity with the old
              // switch).
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
        if (maxHit || cancelledSeen) return;

        final text = buffer.toString();
        final skillName = turn.skillLoadedLast;
        if (skillName == null || text.trim().isNotEmpty) {
          emit(DoneEvent(text));
          return;
        }

        // The model stopped with no text right after reading a skill's
        // instructions. The nudge goes in as an ordinary user turn: core
        // records no reply for an empty generation (a whitespace-only one
        // becomes the model's turn). The budget counts every dispatched call
        // as a generation of its own (parallel calls share one), so it can
        // only overestimate what was used: the turn never makes more than
        // maxIterations generations. A cancel ends the turn here with no
        // event: a stopped generation is empty too, and EmptyAnswerEvent is a
        // DoneEvent, which a cancelled turn never emits.
        emptyAnswers++;
        budget = maxIterations - turn.dispatched - emptyAnswers;
        if (cancelled()) return;
        if (retries >= emptyAfterSkillRetries || budget < 1) {
          emit(EmptyAnswerEvent(skillName));
          return;
        }
        retries++;
        emit(
          EmptyAnswerRetryEvent(
            skillName: skillName,
            nudge: emptyAfterSkillNudge,
            attempt: retries,
          ),
        );
        await chat.addQueryChunk(
          Message(text: emptyAfterSkillNudge, isUser: true),
        );
        buffer.clear();
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
  /// an alias so both paths dispatch to the same executor. Gallery's own tool
  /// names, `runJs` and `runMcpTool`, are accepted the same way.
  static const _toolNameAliases = <String, String>{
    'run_js': AgentToolNames.runSkill,
    'runJs': AgentToolNames.runSkill,
    'run_intent': AgentToolNames.runIntent,
    'run_mcp': AgentToolNames.runMcp,
    'runMcpTool': AgentToolNames.runMcp,
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
    _TurnCalls turn,
  ) async {
    turn.dispatched++;
    turn.skillLoadedLast = null;
    // Normalize a SKILL.md tool-name spelling to the canonical declared name
    // (e.g. `run_js` -> `runSkill`). A native call already uses the canonical
    // name, so the alias map leaves it untouched.
    final canonical = _toolNameAliases[originalCall.name];
    final call = canonical == null
        ? originalCall
        : FunctionCallResponse(name: canonical, args: originalCall.args);
    switch (call.name) {
      case AgentToolNames.loadSkill:
        return _loadSkill(call, emit, turn);
      case AgentToolNames.runSkill:
      case AgentToolNames.runIntent:
      case AgentToolNames.runMcp:
        return _runExecutor(call, emit, turn);
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
    _TurnCalls turn,
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

    turn.skillLoadedLast = skill.name;
    turn.loaded = skill;
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
    _TurnCalls turn,
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
    // `runIntent` names its action in `intent`, `runMcp` its tool in
    // `toolName`. Small models often add the loaded skill's `skillName` to the
    // call too; the action still comes from `intent` / `toolName`, while the
    // registered skill stays the call's skill for the event above and for the
    // secret below.
    final action = switch (call.name) {
      AgentToolNames.runIntent => _stringArg(call.args, 'intent').trim(),
      AgentToolNames.runMcp => _stringArg(call.args, 'toolName').trim(),
      _ => '',
    };
    final probe = skill == null || action.isNotEmpty
        ? _syntheticSkillFor(call)
        : skill;
    final executor = _pickExecutor(probe);
    if (executor == null) {
      final message =
          _textOnlySkillHint(call, probe, turn) ??
          'No executor available for "${call.name}".';
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
    if (result is ErrorResult && _isUnknownIntent(executor, probe, dataJson)) {
      final hint = _textOnlySkillHint(call, probe, turn);
      if (hint != null) result = ErrorResult(hint);
    }

    emit(ToolResultEvent(toolName: call.name, result: result));
    if (result is ErrorResult) {
      emit(AgentErrorEvent(result.message, toolName: call.name));
    }

    return _resultToResponse(result);
  }

  /// The error fed back for a `runIntent` that names no intent the app can run,
  /// when the skill the model loaded last in this turn is text-only. Such a
  /// skill calls no tool, so the model is told to answer from its
  /// instructions instead of being handed the list of intents to try next.
  /// Null in every other case.
  String? _textOnlySkillHint(
    FunctionCallResponse call,
    Skill probe,
    _TurnCalls turn,
  ) {
    final loaded = turn.loaded;
    if (call.name != AgentToolNames.runIntent ||
        loaded == null ||
        loaded.type != SkillType.textOnly) {
      return null;
    }
    return 'The loaded skill "${loaded.name}" calls no tool, and '
        '"${probe.name}" is not an intent this app can run. Answer the user '
        "directly, following the skill's instructions.";
  }

  /// Whether [executor] has no intent by the name the call gave: neither
  /// [probe]'s name nor an `intent` inside the payload, the two places
  /// [NativeIntentExecutor.execute] looks. Only the package's own intent
  /// executor can be asked; another executor's errors are its own.
  static bool _isUnknownIntent(
    SkillExecutor executor,
    Skill probe,
    String dataJson,
  ) =>
      executor is NativeIntentExecutor &&
      !executor.isWhitelisted(probe.name.trim()) &&
      !executor.isWhitelisted(_payloadIntent(dataJson));

  /// The `intent` a `parameters` payload carries itself, or '' when it has
  /// none (or is not JSON).
  static String _payloadIntent(String dataJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(dataJson);
    } on FormatException {
      return '';
    }
    if (decoded case {'intent': final String intent}) return intent.trim();
    return '';
  }

  /// First executor (in probe order) that can run [skill]; null if none can.
  SkillExecutor? _pickExecutor(Skill skill) {
    for (final executor in _executors) {
      if (executor.canExecuteSkill(skill)) return executor;
    }
    return null;
  }

  /// Build a stand-in [Skill] for an intent / MCP call that names its action,
  /// or that does not target a registered skill, so executors can still probe
  /// by [SkillType]. It carries no instructions and no metadata. The
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
  /// A model sometimes passes an object or a list where the tool asks for a
  /// JSON string (`parameters`, `data`, `input`); it is handed on as JSON, not
  /// as Dart's `{key: value}` text, which no executor can decode.
  String _stringArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return '';
    if (value is String) return value;
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }
}

/// The default [AgentLoop.emptyAfterSkillNudge].
const String defaultEmptyAfterSkillNudge =
    "Continue with the loaded skill's instructions.";

/// What one [AgentLoop.run] remembers about the tool calls it dispatched.
class _TurnCalls {
  /// Calls dispatched so far in the turn, of every kind.
  int dispatched = 0;

  /// The skill's name when the most recent dispatched call was a `loadSkill`
  /// that found it; null after any other call.
  String? skillLoadedLast;

  /// The skill of the turn's most recent successful `loadSkill`, whatever
  /// was called after it.
  Skill? loaded;
}
