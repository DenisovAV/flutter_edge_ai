// The decider SPI (InferenceModel.readDecisionSection, openOptionScorer) is
// @experimental; this model is its LiteRT-LM implementation.
// The model also keeps the deprecated singleton chat API until 3.0.
// ignore_for_file: experimental_member_use, deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter_edge_ai/engine.dart';

import 'package:flutter/foundation.dart';

import 'package:litertlm_dart/internal_io.dart'
    show
        ScoringStoppedError,
        conversationHandle,
        conversationTokenCount,
        createConversationWithDefault,
        createOwnConversation,
        engineBundleSampler,
        engineRenderUserMessage,
        engineFiltersChannelContent,
        engineNoRewindReason,
        isReleaseBuild,
        messageRawJson,
        runtimeLog;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import '../litertlm_decision_section.dart';
import '../option_scoring_self_check.dart';
import '../reported_engine_turn.dart';
import 'runtime_log_binding.dart';
import 'turn_errors.dart';

export 'turn_errors.dart' show LiteRtLmSessionClosedError;
import 'user_message.dart';

export 'user_message.dart' show liteRtLmUserMessage;
import 'runtime_mapping.dart';

/// Whether the scoring self-check is skipped as in a release build:
/// [isReleaseBuild] (`dart.vm.product`, a compile-time constant), set by tests,
/// which never run in release.
@visibleForTesting
bool liteRtLmScoringReleaseMode = isReleaseBuild;

/// The text a streamed LiteRT-LM reply chunk shows core's chat: a thought as
/// `<|channel>thought\n…<channel|>` (what core's parser reads as thinking),
/// else its text parts; a chunk that carries only tool calls shows as its
/// JSON, as the SDK's chunk did.
String liteRtLmChunkText(lm.Message chunk) {
  final thought = chunk.channels['thought'];
  if (thought != null && thought.isNotEmpty) {
    return '<|channel>thought\n$thought<channel|>';
  }
  if (chunk.contents.isEmpty && chunk.toolCalls.isNotEmpty) {
    return liteRtLmChunkJson(chunk);
  }
  return chunk.text;
}

/// [chunk] as the Conversation API JSON core's [SdkResponseParser] reads
/// (`tool_calls`, `content`, `channels`): what native wrote for it, which
/// keeps what [lm.Message] does not (a call's id, a flat call), else rebuilt.
String liteRtLmChunkJson(lm.Message chunk) =>
    messageRawJson(chunk) ?? _rebuiltChunkJson(chunk);

String _rebuiltChunkJson(lm.Message chunk) => jsonEncode({
  'role': 'assistant',
  if (chunk.contents.isNotEmpty)
    'content': [
      for (final part in chunk.contents)
        if (part case lm.TextContent(:final text))
          {'type': 'text', 'text': text},
    ],
  if (chunk.toolCalls.isNotEmpty)
    'tool_calls': [
      for (final call in chunk.toolCalls)
        {
          'type': 'function',
          'function': {'name': call.name, 'arguments': call.arguments},
        },
    ],
  if (chunk.channels.isNotEmpty) 'channels': chunk.channels,
});

/// FFI implementation of InferenceModel using dart:ffi → LiteRT-LM C API.
/// Shared between desktop and mobile (iOS) for .litertlm models.
///
/// Scores options for `createDecider` ([openOptionScorer]) on the CPU and
/// GPU backends (not the NPU), from the decision litetune wrote into the
/// model file ([decisionRead], read when the model was loaded).
base class FfiInferenceModel extends InferenceModel with CloseNotifier {
  FfiInferenceModel({
    required this.engine,
    required this.maxTokens,
    required this.modelType,
    required this.activeBackend,
    this.decisionRead,
    this.activeVisionBackend,
    this.activeAudioBackend,
    this.fileType = ModelFileType.litertlm,
    this.supportImage = false,
    this.supportAudio = false,
    MultimodalOrder? multimodalOrder,
    this.maxConcurrentSessions,
    this.thinkingTokenBudget,
    this.structuredOutput = const StructuredOutputSupport.none(
      'This LiteRT-LM model was not loaded through LiteRtLmEngine.',
    ),
    required this.onClose,
  }) : multimodalOrder =
           multimodalOrder ?? MultimodalOrder.forModelType(modelType) {
    // The runtime logs on this isolate through core from here on.
    bindRuntimeLogToCore();
  }

  /// The loaded LiteRT-LM engine.
  final lm.Engine engine;

  /// Why a conversation of this model is rebuilt from history instead of
  /// being rewound after a stopped turn or a full context; null when it
  /// rewinds.
  @visibleForTesting
  String? get noRewindReason => engineNoRewindReason(engine);

  /// Whether LiteRT-LM may strip a finished reply's thought from the KV
  /// cache ([lm.Engine.filtersChannelContent]).
  @visibleForTesting
  bool get filterChannelContent => engineFiltersChannelContent(engine);
  final ModelType modelType;

  /// The thinking budget of every generation with thinking on
  /// (`LiteRtLmEngine.thinkingTokenBudget`); null sets none.
  final int? thinkingTokenBudget;

  /// The decision the loaded `.litertlm` carries, read with the model so
  /// that a decider reads the file the engine loaded; null only for a model
  /// built without one (tests), which then cannot read its decision.
  final LitetuneDecisionRead? decisionRead;

  /// Whether this engine's scoring self-check ran and passed before the first
  /// decision on this model; false until then, and in a release build, which
  /// skips it.
  bool get scoringChecked => _scoringChecked;
  bool _scoringChecked = false;
  Future<void>? _scoringCheck;
  @override
  final ModelFileType fileType;
  @override
  final int maxTokens;
  @override
  final PreferredBackend? activeBackend;
  @override
  final PreferredBackend? activeVisionBackend;
  @override
  final PreferredBackend? activeAudioBackend;
  final bool supportImage;
  final bool supportAudio;

  /// Where a message's images and audio go around its text, in
  /// [createSession] sessions and all [openSession] sessions, including the
  /// full-message replay used by [OpenSessionBacking.virtual].
  final MultimodalOrder multimodalOrder;

  /// Cap on concurrent [openSession] sessions; null = unlimited.
  final int? maxConcurrentSessions;

  /// LLGuidance qualification for the exact host and backend that loaded the
  /// model. The engine computes it from the package's device-run allow-list.
  final StructuredOutputSupport structuredOutput;

  @override
  StructuredOutputSupport get engineStructuredOutputSupport => structuredOutput;

  @override
  ResponseFormatUnsupportedException? engineRefusalFor(
    JsonSchemaResponseFormat format,
  ) => thinkingTokenBudget == null
      ? null
      : const ResponseFormatUnsupportedException(
          'LiteRT-LM cannot combine a response format with a model loaded '
          'with thinkingTokenBudget. Register LiteRtLmEngine without a '
          'thinkingTokenBudget and load the model again.',
        );

  final VoidCallback onClose;

  FfiInferenceModelSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  /// Sessions opened via [openSession] — detached from the legacy [_session]
  /// singleton. Each owns its own conversation handle.
  final Set<FfiInferenceModelSession> _openSessions = {};

  /// [openSession] calls past the cap check whose native conversation is
  /// still being created, so that concurrent calls cannot pass the cap
  /// together.
  int _openSessionsPending = 0;

  @override
  InferenceModelSession? get session => _session;

  @override
  Future<String?> readDecisionSection() async {
    final read = decisionRead;
    if (read == null) {
      throw const DeciderUnsupportedException(
        'This model was built without reading its file, so it has no '
        'decision to read.',
      );
    }
    if (read.error case final error?) throw error;
    return read.payload;
  }

  /// The self-check, once per model in a debug or profile build (a release
  /// build scores without it); a check that
  /// failed runs again next time (it may have failed on a model that was
  /// closing). Its runs belong to [scorer]: closing that scorer stops them,
  /// and another scorer waiting on the same check then runs it again for
  /// itself.
  Future<void> _scoringCheckFor(
    _LiteRtLmOptionScorer scorer,
    List<String> targets,
  ) async {
    while (true) {
      final known = _scoringCheck;
      if (known == null) return _runScoringCheck(scorer, targets);
      try {
        return await known;
      } on ScoringStoppedError {
        // Stopped by the scorer that ran it, or by this model's close: run
        // it again unless this scorer or the model is the one closed. A
        // native failure is not retried here: it reaches this caller.
        scorer._engine;
      }
    }
  }

  Future<void> _runScoringCheck(
    _LiteRtLmOptionScorer scorer,
    List<String> targets,
  ) {
    List<double> single(OptionScoringRun run, List<String> tokens) => [
      for (var i = 0; i < tokens.length; i++)
        if (run.tokenScores[i].length == 1)
          run.tokenScores[i].single
        else
          throw DeciderUnsupportedException(
            'The self-check\'s one-token target "${tokens[i]}" scored '
            '${run.tokenScores[i].length} tokens.',
          ),
    ];
    // isReleaseBuild is `dart.vm.product`, a compile-time constant: true in a
    // release build only (profile builds keep the check), and the check's
    // code is tree-shaken out of a release build.
    final check = liteRtLmScoringChecked(
      releaseMode: liteRtLmScoringReleaseMode,
      selfCheck: () => liteRtLmScoringSelfCheck(
        backend: activeBackend,
        targets: targets,
        tokenize: scorer.tokenize,
        detokenize: scorer.detokenize,
        scoreOneToken: (prompt, token) async =>
            single(await scorer._score(prompt, [token]), [token]).single,
        scoreInRun: (prompt, tokens) async =>
            single(await scorer._score(prompt, tokens), tokens),
      ),
    );
    _scoringCheck = check;
    return check.then(
      (ran) => _scoringChecked = ran,
      onError: (Object e, StackTrace st) {
        if (identical(_scoringCheck, check)) _scoringCheck = null;
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  /// Scores on the CPU and on the GPU. The GPU's scores are not the CPU's,
  /// and the calibration in a bundle is fitted on CPU probabilities; in a
  /// debug or profile build the self-check runs on either before the first
  /// decision (a release build skips it). The NPU is refused:
  /// its executor rolls back one token only, and a decision rewinds between
  /// options.
  @override
  Future<OptionScorer> openOptionScorer() async {
    if (_isClosed) throw StateError('The model is closed.');
    switch (activeBackend) {
      case PreferredBackend.cpu || PreferredBackend.gpu:
        return _LiteRtLmOptionScorer(this);
      case PreferredBackend.npu:
        throw const DeciderUnsupportedException(
          'Option scoring does not run on the NPU: its executor rolls back one '
          'token only, and a decision rewinds between options. Load a bundle '
          'built for the CPU or GPU with preferredBackend: PreferredBackend.cpu '
          'or PreferredBackend.gpu to create a decider from it.',
        );
      case null:
        throw const DeciderUnsupportedException(
          'Option scoring runs on the CPU and GPU backends, and this model '
          'does not report its backend. Load it with preferredBackend: '
          'PreferredBackend.cpu or PreferredBackend.gpu to create a decider '
          'from it.',
        );
    }
  }

  @override
  List<InferenceModelSession> get engineSessions => [
    ?_session,
    ..._openSessions,
  ];

  /// [explicit], completed from the bundle's own sampler, then the family's
  /// defaults, then the fallback.
  ResolvedSampling _resolveSampling(
    SamplingParams explicit, {
    required bool thinking,
  }) => SamplingParams.resolve(
    explicit,
    modelType: modelType,
    thinking: thinking,
    modelDefaults: engineBundleSampler(engine).toCore,
  );

  static lm.SamplerConfig _samplerConfig(ResolvedSampling sampling) =>
      lm.SamplerConfig(
        topK: sampling.topK,
        topP: sampling.topP,
        temperature: sampling.temperature,
        seed: sampling.randomSeed,
      );

  /// Without [explicit] sampling, the resolved values: the model's own
  /// default, which never counts as the caller's choice.
  static lm.SamplerConfig? _defaultSampler(
    SamplingParams explicit,
    ResolvedSampling sampling,
  ) => explicit.isEmpty ? _samplerConfig(sampling) : null;

  /// The conversation config of a session: [explicit] sampling marks the
  /// caller's choice (see [_defaultSampler] for the rest).
  lm.ConversationConfig _conversationConfig({
    required SamplingParams explicit,
    required ResolvedSampling sampling,
    required String? systemInstruction,
    required List<Tool> tools,
    required int? maxOutputTokens,
    String? jsonSchema,
  }) {
    return lm.ConversationConfig(
      systemInstruction: systemInstruction,
      tools: _nativeTools(tools),
      // Core runs the calls: every reply with calls reaches its parser.
      automaticToolCalling: false,
      samplerConfig: explicit.isEmpty ? null : _samplerConfig(sampling),
      maxOutputTokens: maxOutputTokens,
      responseFormat: jsonSchema == null
          ? null
          : lm.ResponseFormat.json(
              (jsonDecode(jsonSchema) as Map).cast<String, Object?>(),
            ),
    );
  }

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }

    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the .litertlm FFI path '
        '(loraPath=$loraPath). Track upstream LiteRT-LM C API support; '
        'remove loraPath or use a MediaPipe .task model on Android/iOS.',
      );
    }

    // Single-flight guard for genuinely *concurrent* callers only. The
    // completer is cleared in the `finally` below once creation settles,
    // so a *sequential* second call falls through and opens a fresh
    // conversation handle (closing the prior session first) instead of
    // returning the cached session. Without this, the cached completer
    // made every later createChat reuse the first session, so the
    // previous conversation's KV cache bled into the next chat. This is
    // the litert/FFI sibling of the MediaPipe fix in #309 (issue #308).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }

    final completer = _createCompleter = Completer<InferenceModelSession>();
    final sessionSw = Stopwatch()..start();

    try {
      // Resolved first: values it rejects must not cost the live session.
      final explicit = SamplingParams(
        temperature: temperature,
        topK: topK,
        topP: topP,
        randomSeed: randomSeed,
      );
      final sampling = _resolveSampling(explicit, thinking: enableThinking);

      // Legacy singleton lane: close the previous conversation BEFORE
      // opening a fresh one. createSession replaces the session it gave
      // before, and on LiteRT-LM 0.18 the engine held at most one live
      // conversation (upstream litert-lm #966); closing first also frees the
      // old conversation's KV cache before the new one is allocated. It also
      // means a
      // teardown error can't leak a handle that was created first and
      // then left unwrapped: each session owns its own conversation
      // pointer, so closing the old one can't touch the not-yet-created
      // new one. See PR #310 review.
      await _session?.close();

      final beforeConv = sessionSw.elapsedMilliseconds;
      final lm.Conversation conversation;
      try {
        // The singleton lane's conversation is always its own native one,
        // also where open sessions share one by replay.
        conversation = await createOwnConversation(
          engine,
          _conversationConfig(
            explicit: explicit,
            sampling: sampling,
            systemInstruction: systemInstruction,
            tools: tools,
            maxOutputTokens: maxOutputTokens,
          ),
          _defaultSampler(explicit, sampling),
        );
      } on StateError {
        if (_isClosed) {
          throw StateError('Model was closed while creating a session');
        }
        rethrow;
      } on lm.LiteRtLmNativeException catch (e, st) {
        // Core's apps have always caught a plain Exception here.
        Error.throwWithStackTrace(Exception(e.message), st);
      }
      runtimeLog(
        '[FfiInferenceModel/perf] createConversation (FFI): ${sessionSw.elapsedMilliseconds - beforeConv}ms',
      );

      // createConversationHandle now suspends across an isolate round trip, so
      // close() can have run while we were away. Without this the caller gets a
      // working-looking session whose conversation belongs to a dead engine.
      if (_isClosed) {
        await conversation.close();
        throw StateError('Model was closed while creating a session');
      }

      late final FfiInferenceModelSession session;
      session = FfiInferenceModelSession(
        conversation: conversation,
        multimodalOrder: multimodalOrder,
        thinkingTokenBudget: thinkingTokenBudget,
        modelType: modelType,
        fileType: fileType,
        supportImage: enableVisionModality ?? supportImage,
        supportAudio: enableAudioModality ?? supportAudio,
        enableThinking: enableThinking,
        maxOutputTokens: maxOutputTokens,
        // Identity-guarded so a late close of a superseded session can't
        // null a newer `_session`. Does NOT touch `_createCompleter` —
        // that is owned by the `finally` below, not by session teardown.
        onClose: () {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = session;

      completer.complete(session);
      runtimeLog(
        '[FfiInferenceModel/perf] createSession total: ${sessionSw.elapsedMilliseconds}ms',
      );
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      // Pure in-flight guard: clear once creation settles (success OR
      // failure) so the next call isn't blocked by a cached completer
      // (the issue #308 KV-cache bleed on success; a permanently cached
      // rejected future on failure).
      _createCompleter = null;
    }
    // Return `completer.future` (rather than the session / a rethrow) so
    // the caller stays the error listener after the completer field is
    // cleared above, and concurrent callers share the same result.
    return completer.future;
  }

  @override
  Future<InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    final SessionRequest(
      :temperature,
      :randomSeed,
      :topK,
      :topP,
      :loraPath,
      :enableVisionModality,
      :enableAudioModality,
      :systemInstruction,
      :enableThinking,
      :tools,
      :maxOutputTokens,
      :responseFormat,
      :toolChoice,
    ) = request;
    final jsonSchema = responseFormat?.schemaJson;
    // Core's tool choice on a model whose tool calls LiteRT-LM runs: none
    // opens the conversation without the tools, so the model never sees them
    // (with them declared, LiteRT-LM's none only keeps the call out of the
    // reply, and the model may write it as text); required goes with each
    // user turn (litertlm_dart's per-message ToolChoice, never with the turn
    // answering tool results, so it cannot loop). Other models get core's
    // own tools prompt, which already follows the choice.
    final sessionTools = toolChoice == ToolChoice.none ? const <Tool>[] : tools;
    final userTurnToolChoice =
        toolChoice == ToolChoice.required &&
            jsonSchema == null &&
            _nativeTools(tools).isNotEmpty
        ? lm.ToolChoice.required
        : null;
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the .litertlm FFI path '
        '(loraPath=$loraPath). Remove loraPath or use a MediaPipe .task '
        'model on Android/iOS.',
      );
    }
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length + _openSessionsPending >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }

    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);

    // Each session is a conversation of the engine: its own native one where
    // that backend runs several live conversations correctly, a turn of the
    // engine's shared one (its messages replayed) elsewhere. Every idle
    // native conversation keeps a snapshot of its KV cache, so a session
    // costs memory while open (litertlm README, "Open sessions").
    _openSessionsPending++;
    final lm.Conversation conversation;
    try {
      conversation = await createConversationWithDefault(
        engine,
        _conversationConfig(
          explicit: explicit,
          sampling: sampling,
          systemInstruction: systemInstruction,
          tools: sessionTools,
          maxOutputTokens: maxOutputTokens,
          jsonSchema: jsonSchema,
        ),
        _defaultSampler(explicit, sampling),
      );
    } on StateError {
      if (_isClosed) {
        throw StateError('Model was closed while opening a session');
      }
      rethrow;
    } on lm.LiteRtLmNativeException catch (e, st) {
      // Core's apps have always caught a plain Exception here.
      Error.throwWithStackTrace(Exception(e.message), st);
    } finally {
      _openSessionsPending--;
    }
    // The create suspends across an isolate round trip, so close() can have
    // run meanwhile.
    if (_isClosed) {
      await conversation.close();
      throw StateError('Model was closed while opening a session');
    }

    late final FfiInferenceModelSession session;
    session = FfiInferenceModelSession(
      conversation: conversation,
      multimodalOrder: multimodalOrder,
      thinkingTokenBudget: thinkingTokenBudget,
      modelType: modelType,
      fileType: fileType,
      supportImage: enableVisionModality ?? supportImage,
      supportAudio: enableAudioModality ?? supportAudio,
      enableThinking: enableThinking,
      maxOutputTokens: maxOutputTokens,
      userTurnToolChoice: userTurnToolChoice,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  /// [openChat]'s unset values are this model's own, as [createChat] fills
  /// them.
  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) =>
      ResolvedChatRequest(
        modelType: request.modelType ?? modelType,
        supportImage: request.supportImage ?? supportImage,
        supportAudio: request.supportAudio ?? supportAudio,
        supportsFunctionCalls: request.supportsFunctionCalls ?? false,
        tools: request.tools,
        maxFunctionBufferLength:
            request.maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
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
        responseFormat: request.responseFormat,
      );

  @override
  Future<InferenceChat> createChat({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    chat = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? this.supportImage,
        enableAudioModality: supportAudio ?? this.supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? this.supportImage,
      supportAudio: supportAudio ?? this.supportAudio,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      modelType: modelType ?? this.modelType,
      enableThinking: enableThinking,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    await chat!.initSession();
    return chat!;
  }

  /// `tools_json` for a model whose tool calling LiteRT-LM runs natively —
  /// Gemma 4, and FunctionGemma — and null for every other model, which gets a
  /// Dart-side tools prompt in chat.dart instead. The runtime renders the
  /// declarations from it, parses calls into `tool_calls` and takes results as
  /// role `tool`. Same predicate [InferenceChat] uses to skip its own prompt,
  /// so the declarations are rendered exactly once.
  List<lm.Tool> _nativeTools(List<Tool> tools) =>
      tools.isNotEmpty &&
          FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType)
      ? [
          for (final tool in tools)
            lm.Tool(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters,
            ),
        ]
      : const [];

  /// The teardown in progress, shared by every caller of [close]: a second
  /// call waits for it instead of returning at once, so core can tell when
  /// the model is really gone before it builds the next one.
  Future<void>? _closeFuture;

  @override
  Future<void> close() {
    final teardown = _closeFuture;
    if (teardown != null) return teardown;
    final attempt = _close();
    _closeFuture = attempt;
    unawaited(
      attempt.onError((_, _) {
        if (identical(_closeFuture, attempt)) _closeFuture = null;
      }),
    );
    return attempt;
  }

  Future<void> _close() async {
    _isClosed = true;
    try {
      await _session?.close();
      // Copy because close() mutates _openSessions via the onClose callback.
      for (final s in _openSessions.toList()) {
        await s.close();
      }
      _openSessions.clear();
    } finally {
      // Awaited: shutdown() defers engine_delete until any conversation create
      // suspended on its spawned isolate has finished.
      await engine.close();
      onClose(); // legacy hook (engine passes a no-op)
      fireCloseListeners(); // core's singleton-reset, registered via addCloseListener
    }
  }
}

/// FFI implementation of InferenceModelSession over one [lm.Conversation].
/// Buffers query chunks until [getResponse] is called.
class FfiInferenceModelSession extends InferenceModelSession
    with RawSdkResponseSession {
  FfiInferenceModelSession({
    required this.conversation,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    this.multimodalOrder = const MultimodalOrder(),
    this.enableThinking = false,
    this.thinkingTokenBudget,
    this.maxOutputTokens,
    this.userTurnToolChoice,
    required this.onClose,
  });

  /// The tool choice each user turn is sent with (core's
  /// [ToolChoice.required] on a model whose tool calls LiteRT-LM runs); null
  /// sends none. The turn answering tool results never carries it.
  final lm.ToolChoice? userTurnToolChoice;

  /// The session's conversation.
  final lm.Conversation conversation;

  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final bool supportAudio;

  /// Where a message's images and audio go around its text.
  final MultimodalOrder multimodalOrder;
  final bool enableThinking;

  /// The thinking budget of each generation with thinking on.
  final int? thinkingTokenBudget;

  /// The cap on each reply, which decides what a completed turn reports.
  final int? maxOutputTokens;
  final VoidCallback onClose;

  /// The turns not yet ended, each with its own stop: [stopGeneration] stops
  /// every one of them, the one streaming and those waiting for it.
  final _liveTurnStops = <_TurnStop>{};

  /// Completes at [close]: a turn waiting for the one before it stops
  /// waiting, since a paused turn might never end on its own.
  final _closedSignal = Completer<void>();

  Object _coreTurnError(Object error) => coreTurnError(error);

  void _closeAfterFormatRefusal() {
    if (_isClosed || _rejectFurtherSends) return;
    _rejectFurtherSends = true;
    _queryBuffer.clear();
    _pendingImages.clear();
    _pendingAudio = null;
    _pendingToolResponses.clear();
    unawaited(Future<void>.delayed(Duration.zero, close));
  }

  final StringBuffer _queryBuffer = StringBuffer();
  final List<Uint8List> _pendingImages = [];
  Uint8List? _pendingAudio;
  bool _isClosed = false;
  bool _rejectFurtherSends = false;

  /// Whether LiteRT-LM runs this model's tool calling natively (Gemma 4, and
  /// FunctionGemma); see [FunctionCallParser.usesSdkPassthrough].
  late final bool _nativeTools = FunctionCallParser.usesSdkPassthrough(
    modelType,
    fileType: fileType,
  );

  /// Tool results staged since the last generation, for [_nativeTools] models.
  final List<({String name, Object? response})> _pendingToolResponses = [];

  /// Whether anything other than a tool result was staged for this turn.
  bool _stagedNonToolContent = false;

  /// Last full raw JSON response. For native tool models this is the
  /// structured OpenAI Chat Completions object (with `tool_calls` if any).
  /// chat.dart reads it via [lastRawResponse] before fallback to text
  /// extraction.
  String? _lastRawResponse;

  /// Most recent raw SDK JSON. Returns the response of the last [getResponse]
  /// or [getResponseAsync]. For native tool models use
  /// [SdkResponseParser.extractToolCalls] on this string to surface tool calls.
  @override
  String? get lastRawResponse => _lastRawResponse;

  void _assertNotClosed() {
    if (_isClosed || _rejectFurtherSends) {
      throw StateError('Session is closed');
    }
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    _queryBuffer.write(prompt);

    if (_nativeTools && message.type == MessageType.toolResponse) {
      final name = message.toolName;
      if (name == null) {
        throw ArgumentError.value(
          message,
          'message',
          'A tool response needs toolName: the runtime formats the result as '
              'response:NAME{...}, and without a name it answers no call',
        );
      }
      _pendingToolResponses.add((
        name: name,
        response: SdkResponseParser.toolResponsePayload(message.text),
      ));
    } else if (prompt.isNotEmpty || message.hasImage || message.hasAudio) {
      _stagedNonToolContent = true;
    }

    if (message.hasImage && supportImage) {
      // A message's images are [Message.images] when it has any, else its
      // [Message.imageBytes] — the rule the MediaPipe, llama and built-in AI
      // sessions follow. The factories set both to the same photo, and a
      // message rebuilt from saved bytes holds two equal copies, so staging
      // both would show the model the photo twice.
      if (message.images.isNotEmpty) {
        _pendingImages.addAll(message.images);
      } else if (message.imageBytes case final image?) {
        _pendingImages.add(image);
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      _pendingAudio = message.audioBytes;
    }
  }

  /// This turn's message: the staged tool results as one role-`tool` message
  /// when they are the whole turn — LiteRT-LM's template continues the
  /// model's own turn only after a `tool` message; sent as user text, the
  /// model opens a new turn and calls the same function again — else the
  /// staged user message. A turn that also carries user text or media is a
  /// user message, so there the results stay in the text they were staged
  /// as; the history replay after a context trim stages exactly that mix.
  lm.Message _takeTurnMessage() {
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final images = List<Uint8List>.of(_pendingImages);
    final audio = _pendingAudio;
    _pendingAudio = null;
    _pendingImages.clear();
    final onlyTools =
        _pendingToolResponses.isNotEmpty && !_stagedNonToolContent;
    final message = onlyTools
        ? lm.Message.tool([
            for (final r in _pendingToolResponses)
              lm.Content.toolResponse(r.name, r.response),
          ])
        : liteRtLmUserMessage(
            text,
            images: images,
            audio: audio,
            order: multimodalOrder,
          );
    _pendingToolResponses.clear();
    _stagedNonToolContent = false;
    return message;
  }

  /// The last turn asked for: a turn asked for while it still streams waits
  /// for it, as core's sessions always have, since a conversation takes one
  /// message at a time. A stopped turn is not waited for: the conversation
  /// let it go at the stop and winds it down itself, within a bound, so a
  /// consumer that paused the stopped stream blocks nothing.
  ({Future<void> done, _TurnStop stop})? _lastTurn;

  /// One turn's reply, with core's errors.
  Stream<lm.Message> _turn(lm.Message message) => conversation
      .sendMessageStream(
        message,
        thinkingConfig: lm.ThinkingConfig(
          enableThinking: enableThinking,
          thinkingTokenBudget: thinkingTokenBudget,
        ),
        toolChoice: message.role == lm.Role.tool ? null : userTurnToolChoice,
      )
      .handleError((Object error, StackTrace stack) {
        if (error is lm.ConstraintUnsupportedException) {
          // Settle the failed turn before close changes reportedEngineTurn's
          // end to `closed`. CreateConstraint has already pushed a ghost user
          // message, so refuse another send immediately and delete the
          // conversation on the next event-loop turn.
          _closeAfterFormatRefusal();
        }
        Error.throwWithStackTrace(_coreTurnError(error), stack);
      });

  @override
  Future<String> getResponse() async {
    final buffer = StringBuffer();
    await for (final chunk in getResponseAsync()) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  void _logGenerationStats(Stopwatch sw, int? firstChunkMs, int chunks) {
    final total = sw.elapsedMilliseconds;
    if (firstChunkMs == null || chunks == 0) {
      runtimeLog(
        '[FfiInferenceModelSession/perf] generation total: ${total}ms (no chunks emitted)',
      );
      return;
    }
    final decodeMs = total - firstChunkMs;
    final decodeRate = chunks > 1 && decodeMs > 0
        ? ((chunks - 1) * 1000.0 / decodeMs).toStringAsFixed(1)
        : 'n/a';
    runtimeLog(
      '[FfiInferenceModelSession/perf] generation total: ${total}ms '
      '(prefill ${firstChunkMs}ms + decode ${decodeMs}ms over $chunks chunks, '
      '~$decodeRate chunks/sec)',
    );
  }

  /// The reply's text, chunk by chunk ([liteRtLmChunkText]). For a model
  /// whose tool calling LiteRT-LM runs natively, the reply's JSON is kept for
  /// [lastRawResponse], where chat.dart reads `tool_calls`.
  @override
  Stream<String> getResponseAsync() => _response(_TurnStop());

  /// The reply of the message staged now, sent once the turn before it
  /// lets it: that one has ended, or either is stopped, or the session
  /// closes, or this reply's consumer cancels. The wait is outside the
  /// `async*` body ([_reply]), which would not see a cancel until the turn
  /// before it ended; the forwarding is synchronous, so the body's events
  /// reach the listener as they always have.
  Stream<String> _response(_TurnStop stop) {
    StreamSubscription<String>? body;
    late final Completer<void> done;
    var listened = false;
    // This turn's consumer let it go while it waited.
    final abandoned = Completer<void>();
    // When the turn before this one lets go of the conversation.
    Future<void>? previousLetGo;
    void finish() {
      _liveTurnStops.remove(stop);
      if (!done.isCompleted) done.complete();
    }

    late final StreamController<String> out;
    out = StreamController<String>(
      sync: true,
      onListen: () async {
        listened = true;
        final previous = _lastTurn;
        done = Completer<void>();
        _lastTurn = (done: done.future, stop: stop);
        _liveTurnStops.add(stop);
        final lm.Message message;
        try {
          _assertNotClosed();
          message = _takeTurnMessage();
          if (previous != null && !previous.stop.asked) {
            previousLetGo = Future.any([
              previous.done,
              previous.stop.signal,
              _closedSignal.future,
            ]);
            await Future.any([previousLetGo!, stop.signal, abandoned.future]);
          }
          // Let go by its consumer while it waited: onCancel finished it.
          if (!out.hasListener) return;
          if (_isClosed) {
            throw LiteRtLmSessionClosedError(
              'The session was closed before this turn was sent.',
            );
          }
        } catch (error, stack) {
          finish();
          out
            ..addError(error, stack)
            ..close();
          return;
        }
        // Stopped while it waited: nothing reached the model.
        if (stop.asked) {
          finish();
          await out.close();
          return;
        }
        body = _reply(message).listen(
          out.add,
          // The body's error is its last event; its end follows once it has
          // let go of the conversation, which is when the queue moves on.
          onError: (Object error, StackTrace stack) {
            if (out.isClosed) return;
            out
              ..addError(error, stack)
              ..close();
          },
          onDone: () {
            finish();
            if (!out.isClosed) out.close();
          },
        );
        if (out.isPaused) body!.pause();
      },
      onPause: () => body?.pause(),
      onResume: () => body?.resume(),
      onCancel: () {
        if (!listened) return null;
        final sub = body;
        if (sub == null) {
          // Cancelled while it waited: it is never sent, and the turn after
          // it still waits for the one before it, which holds the
          // conversation, so the queue moves on only when that one lets go.
          abandoned.complete();
          final letGo = previousLetGo;
          if (letGo == null) {
            finish();
          } else {
            unawaited(letGo.then((_) => finish()));
          }
          return null;
        }
        return sub.cancel().whenComplete(finish);
      },
    );
    return out.stream;
  }

  /// The reply to [message], with the timings the perf log reports.
  Stream<String> _reply(lm.Message message) async* {
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;
    final raw = _nativeTools ? StringBuffer() : null;
    _lastRawResponse = null;
    await for (final chunk in _turn(message)) {
      if (firstChunkMs == null) {
        firstChunkMs = genSw.elapsedMilliseconds;
        runtimeLog(
          '[FfiInferenceModelSession/perf] time-to-first-chunk (prefill): ${firstChunkMs}ms',
        );
      }
      chunkCount++;
      raw?.write(liteRtLmChunkJson(chunk));
      yield liteRtLmChunkText(chunk);
    }
    if (raw != null) _lastRawResponse = raw.toString();
    _logGenerationStats(genSw, firstChunkMs, chunkCount);
  }

  @override
  SessionMetrics getSessionMetrics() => conversation.getBenchmarkInfo().toCore;

  @override
  Future<int> sizeInTokens(String text) async {
    // Ask the model's own tokenizer. This used to be `(text.length / 4).ceil()`
    // — a placeholder from the 0.14.0 FFI port that nothing ever measured,
    // while the MediaPipe path called the real tokenizer all along.
    //
    // Measured 2026-08-18 against gemma-4-E2B-it's own tokenizer, estimate over
    // actual (below 1.0 = UNDERCOUNT):
    //
    //   english   1.23x     russian  1.00x     repeated ru words  1.40x
    //   code      0.75x     chinese  0.44x
    //
    // InferenceChat budgets the context window with this, so an undercount
    // means it believes there is headroom while the native KV cache is
    // already full — the #318-class DYNAMIC_UPDATE_SLICE failure. Same
    // closed-session contract as every sibling method.
    _assertNotClosed();
    final exact = await conversationTokenCount(conversation, text);
    if (exact != null) return exact;

    // Engine down, or the native call failed. Fall back to an estimate that
    // errs HIGH — overcounting trims history early (cheap, visible);
    // undercounting overruns the KV cache. Two characters per token bounds
    // every case measured (densest ~1.8). Said once per session; runtimeLog
    // does not reach a release build, so the fallback has to be safe on its
    // own rather than merely announced.
    if (!_tokenFallbackWarned) {
      _tokenFallbackWarned = true;
      runtimeLog(
        '[LiteRtLmFfi] sizeInTokens: native tokenizer unavailable; estimating '
        'conservatively at 2 chars/token for the rest of this session. '
        'Context budgeting will over-count, trimming history earlier than '
        'necessary — the safe direction.',
      );
    }
    return (text.length / 2).ceil();
  }

  /// One-shot latch for the estimate warning.
  bool _tokenFallbackWarned = false;

  /// Stops the turn in flight: native stops at its next token and the text
  /// ends with what was generated; the conversation keeps the exchange
  /// (closed) before the next turn.
  @override
  Future<void> stopGeneration() async {
    for (final stop in _liveTurnStops) {
      stop.ask();
    }
    conversation.cancel();
  }

  /// How the turn ended, for core's chat: a close the consumer did not ask
  /// for ends [getResponseAsync] with a [LiteRtLmSessionClosedError];
  /// here the text ends cleanly and `end` is [TurnEnd.closed], so the chat
  /// keeps the partial reply before it raises (decision H).
  ///
  /// A turn's end is what native's turn-end record says
  /// ([liteRtLmCompletedTurnEnd]). A turn native ended `context_full` (the
  /// input did not fit what the window has left) fails its text with a
  /// [ContextLimitException], and its end is [TurnEnd.contextLimit]; core's
  /// chat then takes the refused message back out of its history. The
  /// conversation restores itself before the next turn (core 2.6.0 design
  /// §6.4b).
  @override
  EngineTurn startTurn() {
    final stop = _TurnStop();
    return reportedEngineTurn(
      _response(stop),
      stopped: () => stop.asked,
      closed: () => _isClosed,
      isCloseError: (error) => error is LiteRtLmSessionClosedError,
      completed: () => liteRtLmCompletedTurnEnd(
        conversationHandle(conversation).lastTurnEnd,
        maxOutputTokens,
      ),
    );
  }

  @override
  Future<void> close() async {
    // Idempotent: a superseded singleton session and the live one can both
    // be closed by a caller, and createSession also closes the prior
    // session before opening a new one — a second close must not re-run
    // conversation.close() / onClose(). See the createSession comment and
    // #308.
    if (_isClosed) return;
    _isClosed = true;
    _closedSignal.complete();
    _queryBuffer.clear();
    _pendingImages.clear();
    _pendingAudio = null;
    _pendingToolResponses.clear();
    await conversation.close();
    onClose();
  }
}

/// [call], with a failed native call thrown as the [StateError] core's
/// option scoring has always got.
@visibleForTesting
Future<T> liteRtLmAsStateError<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on lm.LiteRtLmNativeException catch (e, st) {
    Error.throwWithStackTrace(StateError(e.message), st);
  }
}

/// [OptionScorer] over the engine an [FfiInferenceModel] loaded. Holds no
/// native resource between calls: each scoring pass opens and deletes its own
/// session.
final class _LiteRtLmOptionScorer extends OptionScorer {
  _LiteRtLmOptionScorer(this._model);

  final FfiInferenceModel _model;
  bool _closed = false;

  /// Fired by [close]: stops this scorer's native runs, its share of the
  /// self-check included.
  final _closeSignal = _ScorerCloseSignal();

  /// Every call goes through here, so a scorer or model closed between calls
  /// is a stop, not a failure: a scorer waiting on this one's self-check runs
  /// it again for itself (see `_scoringCheckFor`).
  lm.Engine get _engine {
    if (_closed) throw ScoringStoppedError('The option scorer is closed.');
    if (_model.isClosed) throw ScoringStoppedError('The model is closed.');
    return _model.engine;
  }

  /// One scoring run, stopped by [close] or [cancelToken]; a stop by [close]
  /// is a [ScoringStoppedError], as a closed scorer's call is.
  Future<OptionScoringRun> _score(
    String prompt,
    List<String> targets, {
    CancelToken? cancelToken,
  }) async {
    final engine = _engine;
    final signals = [
      _closeSignal,
      if (cancelToken != null) CancelTokenSignal(cancelToken),
    ];
    try {
      // A native failure as option scoring has always reported it.
      return (await liteRtLmAsStateError(
        () => engine.scoreTargets(
          prompt,
          targets,
          cancel: _AnyCancelSignal(signals),
        ),
      )).toCore;
    } on lm.ScoringCancelledException {
      if (_closed) throw ScoringStoppedError('The option scorer is closed.');
      rethrow;
    }
  }

  @override
  Future<List<int>> tokenize(String text) =>
      liteRtLmAsStateError(() => _engine.tokenize(text));

  @override
  Future<String> detokenize(List<int> ids) =>
      liteRtLmAsStateError(() => _engine.detokenize(ids));

  @override
  Future<String> renderUserMessage(String content) =>
      liteRtLmAsStateError(() => engineRenderUserMessage(_engine, content));

  @override
  Future<void> prepare(List<String> targets) =>
      withCoreErrors(() => _model._scoringCheckFor(this, targets));

  @override
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    CancelToken? cancelToken,
  }) async {
    await withCoreErrors(() => _model._scoringCheckFor(this, targets));
    // The session adds BOS itself, so a prompt that starts with its text
    // would carry two.
    if (prompt.startsWith('<bos>')) {
      throw const DeciderUnsupportedException(
        'The rendered prompt starts with <bos>, which the scoring session '
        'adds itself.',
      );
    }
    return withCoreErrors(
      () => _score(prompt, targets, cancelToken: cancelToken),
    );
  }

  /// Also stops this scorer's native runs in flight — a decision's, or the
  /// self-check it started — at their next check, so a closed decider does
  /// not keep the engine busy scoring options nobody will read.
  @override
  Future<void> close() async {
    _closed = true;
    _closeSignal.fire();
  }
}

/// A scorer's close, as a cancel signal.
final class _ScorerCloseSignal implements lm.CancelSignal {
  final _fired = Completer<void>();

  void fire() {
    if (!_fired.isCompleted) _fired.complete();
  }

  @override
  bool get isCancelled => _fired.isCompleted;

  @override
  Future<void> get whenCancelled => _fired.future;
}

/// Cancelled when any of [signals] is.
final class _AnyCancelSignal implements lm.CancelSignal {
  _AnyCancelSignal(this.signals);

  final List<lm.CancelSignal> signals;

  @override
  bool get isCancelled => signals.any((s) => s.isCancelled);

  @override
  Future<void> get whenCancelled =>
      Future.any([for (final s in signals) s.whenCancelled]);
}

/// One turn's stop: asked by [FfiInferenceModelSession.stopGeneration] while
/// the turn streams or waits for the one before it.
final class _TurnStop {
  final _asked = Completer<void>();

  bool get asked => _asked.isCompleted;

  /// Completes when the stop is asked.
  Future<void> get signal => _asked.future;

  void ask() {
    if (!_asked.isCompleted) _asked.complete();
  }
}
