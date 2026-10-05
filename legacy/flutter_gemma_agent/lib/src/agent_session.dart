import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart'
    show
        InferenceChat,
        InferenceModel,
        ModelType,
        SkillExecutorProvider,
        SkillExecutorRegistry,
        ToolChoice;

import 'agent_event.dart';
import 'agent_loop.dart';
import 'agent_tools.dart';
import 'secret_store.dart';
import 'skill_executor.dart';
import 'skill_registry.dart';

/// Resolve the executor list for an [AgentSession]: use [explicit] when given,
/// otherwise read whatever was registered through
/// `FlutterGemma.initialize(skillExecutors: …)` (core's [SkillExecutorRegistry]).
///
/// Throws [StateError] if neither path supplied executors, or if a registered
/// [SkillExecutorProvider] is not a [SkillExecutor] (a bare provider can't be
/// run — the agent loop needs `execute`). These are the two configuration
/// mistakes worth failing loudly on rather than silently doing nothing.
List<SkillExecutor> _resolveExecutors(List<SkillExecutor>? explicit) {
  if (explicit != null) return explicit;
  final registered = SkillExecutorRegistry.instance.registered;
  if (registered.isEmpty) {
    throw StateError(
      'No skill executors available: pass executors: to AgentSession.fromModel '
      'or register them via FlutterGemma.initialize(skillExecutors: [...]).',
    );
  }
  return [
    for (final p in registered)
      if (p is SkillExecutor)
        p
      else
        throw StateError(
          'Registered skill executor "${p.name}" (${p.runtimeType}) does not '
          'extend SkillExecutor, so the agent loop cannot run it. Register '
          'flutter_gemma_agent SkillExecutor subclasses.',
        ),
  ];
}

/// The default agent system prompt. Mirrors Gallery's skills-only prompt: route
/// the request to a skill, `loadSkill` its instructions, then follow them. The
/// `__SKILLS__` placeholder is replaced with the registry's two-stage discovery
/// list (name + description per selected skill).
const String defaultAgentSystemPrompt =
    '''
You are an AI assistant that helps users by answering questions and completing tasks using skills. For EVERY new task or request or question, you MUST execute the following steps in exact order. You MUST NOT skip any steps.

1. First, find the most relevant skill from the following list:

__SKILLS__

2. If a relevant skill exists, use the `${AgentToolNames.loadSkill}` tool to read its instructions.
3. Follow the skill's instructions exactly to complete the task. Output ONLY the final result when successful.
4. If no relevant skill is found, answer the user directly.''';

/// A thin facade tying a [SkillRegistry], the registered [SkillExecutor]s, an
/// [AgentLoop], and a model/chat into one [ask] entry point.
///
/// Build it with [AgentSession.fromModel] (creates the [InferenceChat] with the
/// [agentTools] and the discovery system prompt injected) or pass an
/// already-created [chat] to the constructor. Then call [ask] to drive a turn
/// and consume the `Stream<AgentEvent>`.
class AgentSession {
  /// Build a session. [executors] is optional: when omitted, the executors
  /// registered via `FlutterGemma.initialize(skillExecutors: …)` are used (see
  /// [_resolveExecutors]). Pass an explicit list to bypass the global registry.
  AgentSession({
    required this.chat,
    required this.registry,
    List<SkillExecutor>? executors,
    SecretStore? secretStore,
    int maxIterations = 10,
  }) : _loop = AgentLoop(
         registry: registry,
         executors: _resolveExecutors(executors),
         // AgentLoop resolves a null store to a fresh one; [secretStore] below
         // delegates to it so the facade and loop always share one instance.
         secretStore: secretStore,
         maxIterations: maxIterations,
       );

  /// The chat the loop drives. Created with [agentTools] + the discovery prompt.
  final InferenceChat chat;

  /// The selected-skills catalog.
  final SkillRegistry registry;

  final AgentLoop _loop;

  /// Runtime secrets for `require-secret` skills (never put in the prompt). The
  /// same store the loop reads at execution time.
  SecretStore get secretStore => _loop.secretStore;

  /// Build the discovery system prompt for [registry] by substituting the
  /// selected-skills list into [systemPromptTemplate].
  static String buildSystemPrompt(
    SkillRegistry registry, {
    String systemPromptTemplate = defaultAgentSystemPrompt,
  }) {
    final discovery = registry.discoveryString();
    return systemPromptTemplate.replaceAll('__SKILLS__', discovery);
  }

  /// Create an [AgentSession] over [model]: builds an [InferenceChat] with the
  /// [agentTools] and the skill discovery injected into the system prompt.
  ///
  /// [model] should be a function-calling-capable model (Gemma 4 E2B/E4B
  /// recommended). [supportsFunctionCalls] defaults to true since the agent is
  /// meaningless without it.
  ///
  /// [executors] is optional: omit it to use the executors registered via
  /// `FlutterGemma.initialize(skillExecutors: …)`; pass a list to override the
  /// global registry for this session.
  static Future<AgentSession> fromModel(
    InferenceModel model, {
    required SkillRegistry registry,
    List<SkillExecutor>? executors,
    SecretStore? secretStore,
    int maxIterations = 10,
    ModelType modelType = ModelType.gemma4,
    bool supportsFunctionCalls = true,
    bool supportImage = false,
    bool supportAudio = false,
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int? maxOutputTokens,
    String systemPromptTemplate = defaultAgentSystemPrompt,
  }) async {
    final chat = await model.createChat(
      tools: agentTools,
      supportsFunctionCalls: supportsFunctionCalls,
      toolChoice: ToolChoice.auto,
      modelType: modelType,
      supportImage: supportImage,
      supportAudio: supportAudio,
      temperature: temperature,
      randomSeed: randomSeed,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      systemInstruction: buildSystemPrompt(
        registry,
        systemPromptTemplate: systemPromptTemplate,
      ),
    );

    return AgentSession(
      chat: chat,
      registry: registry,
      executors: executors,
      secretStore: secretStore,
      maxIterations: maxIterations,
    );
  }

  /// Drive one agent turn for [userMessage], emitting progress [AgentEvent]s
  /// (skill loads, tool calls + their image/webview/widget results, streamed
  /// final text, and a terminal [DoneEvent] / [MaxIterationsEvent]).
  ///
  /// [isCancelled], when provided, ends the stream promptly between
  /// iterations for barge-in — see [AgentLoop.run].
  ///
  /// Pass [imageBytes] to attach a photo to the turn. The session must have been
  /// built with `supportImage: true` (see [fromModel]) and back a multimodal
  /// model. A missing `supportImage: true` fails the returned stream with an
  /// [ArgumentError] rather than quietly answering as if there were no image;
  /// the "multimodal model" half is a caller precondition (undetectable from
  /// Dart — see [AgentLoop.run]).
  Stream<AgentEvent> ask(
    String userMessage, {
    bool Function()? isCancelled,
    Uint8List? imageBytes,
  }) => _loop.run(
    chat,
    userMessage,
    isCancelled: isCancelled,
    imageBytes: imageBytes,
  );

  /// Close the underlying chat session.
  Future<void> close() => chat.close();
}
