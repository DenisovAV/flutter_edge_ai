// The decider SPI (InferenceModel.readDecisionSection, openOptionScorer) is
// @experimental; this model is its LiteRT-LM implementation.
// The model also keeps the deprecated singleton chat API until 3.0.
// ignore_for_file: experimental_member_use, deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter_edge_ai/engine.dart';

import 'package:flutter/foundation.dart';

import '../litertlm_decision_section.dart';
import '../option_scoring_self_check.dart';
import 'channel_content_filter.dart';
import 'litert_lm_client.dart';
import 'open_session_backing.dart';
import '../reported_engine_turn.dart';
import 'native_turns.dart'
    show LiteRtLmTurnCancelledException, LiteRtLmTurnClosedException;

/// Whether the scoring self-check is skipped as in a release build:
/// [kReleaseMode] (`dart.vm.product`, a compile-time constant), set by tests,
/// which never run in release.
@visibleForTesting
bool liteRtLmScoringReleaseMode = kReleaseMode;

/// FFI implementation of InferenceModel using dart:ffi → LiteRT-LM C API.
/// Shared between desktop and mobile (iOS) for .litertlm models.
///
/// Scores options for `createDecider` ([openOptionScorer]) on the CPU and
/// GPU backends (not the NPU), from the decision litetune wrote into the
/// model file ([decisionRead], read when the model was loaded).
base class FfiInferenceModel extends InferenceModel with CloseNotifier {
  FfiInferenceModel({
    required this.ffiClient,
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
    this.openSessionBacking = OpenSessionBacking.virtual,
    this.linearAttentionState = false,
    this.structuredOutput = const StructuredOutputSupport.none(
      'This LiteRT-LM model was not loaded through LiteRtLmEngine.',
    ),
    required this.onClose,
  }) : multimodalOrder =
           multimodalOrder ?? MultimodalOrder.forModelType(modelType);

  final LiteRtLmFfiClient ffiClient;
  final ModelType modelType;

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

  /// How each [openSession] session holds its context, decided at load from
  /// the backend and the host ([liteRtLmOpenSessionBacking]): its own native
  /// conversation where that backend ran several live conversations
  /// correctly, a virtual one (full-message replay) elsewhere.
  final OpenSessionBacking openSessionBacking;

  /// The model keeps linear attention state (a hybrid model such as LFM2.5,
  /// `readLiteRtLmHasLinearAttentionState`): no conversation of it is ever
  /// rewound, since a rewind restores the KV cache but not that state. Null
  /// when the file could not be read to tell: `createSession` then rewinds
  /// as before, and `openSession` sessions are rebuilt from full messages.
  final bool? linearAttentionState;

  /// LLGuidance qualification for the exact host and backend that loaded the
  /// model. The engine computes it from the package's device-run allow-list.
  final StructuredOutputSupport structuredOutput;

  @override
  StructuredOutputSupport get engineStructuredOutputSupport => structuredOutput;

  @override
  ResponseFormatUnsupportedException? engineRefusalFor(
    JsonSchemaResponseFormat format,
  ) => ffiClient.thinkingTokenBudget == null
      ? null
      : const ResponseFormatUnsupportedException(
          'LiteRT-LM cannot combine a response format with a model loaded '
          'with thinkingTokenBudget. Register LiteRtLmEngine without a '
          'thinkingTokenBudget and load the model again.',
        );

  /// Why a [createSession] conversation of this model is rebuilt from history
  /// instead of being rewound after a stopped turn or a full context, or null
  /// when it rewinds.
  @visibleForTesting
  String? get noRewindReason => _noRewindReason;

  String? get _noRewindReason => activeBackend == PreferredBackend.npu
      ? 'the NPU executor rolls back one token at most'
      : linearAttentionState == true
      ? 'this model keeps linear attention state, which a rewind cannot '
            'restore'
      : null;

  /// Whether LiteRT-LM may strip a completed reply's channel content (a
  /// thought) from the KV cache, which it does by rewinding over the whole
  /// reply ([liteRtLmFiltersChannelContent], where the trade-off is
  /// described): only where every conversation is known to rewind, the rule
  /// of [openSessionNoRewindReason], since the native rewind runs before Dart
  /// could rebuild instead. The same for every conversation of this model,
  /// native or virtual.
  @visibleForTesting
  bool get filterChannelContent => liteRtLmFiltersChannelContent(
    npu: activeBackend == PreferredBackend.npu,
    linearAttentionState: linearAttentionState,
  );

  /// The same for an [openSession] conversation: also rebuilt when whether
  /// the model keeps linear attention state could not be read.
  @visibleForTesting
  String? get openSessionNoRewindReason =>
      _noRewindReason ??
      (linearAttentionState == null
          ? 'whether this model keeps linear attention state could not be '
                'read from its file'
          : null);
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
        scorer._client;
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
    // kReleaseMode is `dart.vm.product`, a compile-time constant: true in a
    // release build only (profile builds keep the check), and the check's
    // code is tree-shaken out of a release build.
    final check = liteRtLmScoringChecked(
      releaseMode: liteRtLmScoringReleaseMode,
      selfCheck: () => liteRtLmScoringSelfCheck(
        backend: activeBackend,
        targets: targets,
        tokenize: scorer.tokenize,
        detokenize: scorer.detokenize,
        scoreOneToken: (prompt, token) async => single(
          await scorer._client.scoreTargets(prompt, [
            token,
          ], stops: scorer._stops),
          [token],
        ).single,
        scoreInRun: (prompt, tokens) async => single(
          await scorer._client.scoreTargets(
            prompt,
            tokens,
            stops: scorer._stops,
          ),
          tokens,
        ),
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
    modelDefaults: ffiClient.bundleSampler,
  );

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

      final toolsJson = _nativeToolsJson(tools);

      final beforeConv = sessionSw.elapsedMilliseconds;
      // Same config every time, so a conversation rebuilt after a stopped turn
      // is this one again, plus its history.
      Future<LiteRtLmConversationHandle> open({String? messagesJson}) =>
          ffiClient.createConversationHandle(
            systemMessage: systemInstruction,
            toolsJson: toolsJson,
            messagesJson: messagesJson,
            sampling: sampling,
            samplingExplicit: !explicit.isEmpty,
            maxOutputTokens: maxOutputTokens,
            multimodalOrder: multimodalOrder,
            filterChannelContent: filterChannelContent,
          );
      final handle = RecoveringConversationHandle(
        await open(),
        reopen: (messagesJson) => open(messagesJson: messagesJson),
        noRewindReason: _noRewindReason,
      ).._multimodalOrder = multimodalOrder;
      edgeAiLog(
        '[FfiInferenceModel/perf] createConversation (FFI): ${sessionSw.elapsedMilliseconds - beforeConv}ms',
      );

      // createConversationHandle now suspends across an isolate round trip, so
      // close() can have run while we were away. Without this the caller gets a
      // working-looking session whose conversation belongs to a dead engine.
      if (_isClosed) {
        handle.close();
        throw StateError('Model was closed while creating a session');
      }

      late final FfiInferenceModelSession session;
      session = FfiInferenceModelSession(
        handle: handle,
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
      edgeAiLog(
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
    ) = request;
    final jsonSchema = responseFormat?.schemaJson;
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

    final toolsJson = _nativeToolsJson(tools);
    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);

    final ConversationHandle handle;
    switch (openSessionBacking) {
      case OpenSessionBacking.native:
        // LiteRT-LM 0.19 keeps several live conversations on one engine
        // (upstream #966 lifted; §22 on the NPU), so each session gets its
        // own, as createSession's: images and audio stay in it, and a stopped
        // turn or a full context is rewound where the backend can. Every idle
        // conversation keeps a snapshot of its KV cache, so a session costs
        // memory while open (litertlm README, "Open sessions").
        Future<LiteRtLmConversationHandle> open({String? messagesJson}) =>
            ffiClient.createConversationHandle(
              systemMessage: systemInstruction,
              toolsJson: toolsJson,
              messagesJson: messagesJson,
              sampling: sampling,
              samplingExplicit: !explicit.isEmpty,
              maxOutputTokens: maxOutputTokens,
              multimodalOrder: multimodalOrder,
              jsonSchema: jsonSchema,
              filterChannelContent: filterChannelContent,
            );
        _openSessionsPending++;
        final LiteRtLmConversationHandle first;
        try {
          first = await open();
        } finally {
          _openSessionsPending--;
        }
        // The create suspends across an isolate round trip, so close() can
        // have run meanwhile.
        if (_isClosed) {
          first.close();
          throw StateError('Model was closed while opening a session');
        }
        handle = RecoveringConversationHandle(
          first,
          reopen: (messagesJson) => open(messagesJson: messagesJson),
          noRewindReason: openSessionNoRewindReason,
        ).._multimodalOrder = multimodalOrder;
      case OpenSessionBacking.virtual:
        // Where several live conversations were not verified on this backend,
        // each session keeps its history in Dart and replays it into one
        // shared conversation on demand (serialized by the client mutex), as
        // on LiteRT-LM 0.18. Logically concurrent contexts, serialized
        // inference; openSession() itself makes no native call.
        handle = _VirtualConversationHandle(
          client: ffiClient,
          systemMessage: systemInstruction,
          toolsJson: toolsJson,
          sampling: sampling,
          samplingExplicit: !explicit.isEmpty,
          maxOutputTokens: maxOutputTokens,
          multimodalOrder: multimodalOrder,
          jsonSchema: jsonSchema,
          filterChannelContent: filterChannelContent,
        );
    }

    late final FfiInferenceModelSession session;
    session = FfiInferenceModelSession(
      handle: handle,
      modelType: modelType,
      fileType: fileType,
      supportImage: enableVisionModality ?? supportImage,
      supportAudio: enableAudioModality ?? supportAudio,
      enableThinking: enableThinking,
      maxOutputTokens: maxOutputTokens,
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
  String? _nativeToolsJson(List<Tool> tools) =>
      tools.isNotEmpty &&
          FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType)
      ? SdkResponseParser.serializeToolsForSdk(tools)
      : null;

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
      await ffiClient.shutdown();
      onClose(); // legacy hook (engine passes a no-op)
      fireCloseListeners(); // core's singleton-reset, registered via addCloseListener
    }
  }
}

/// FFI implementation of InferenceModelSession.
/// Buffers query chunks until [getResponse] is called.
///
/// Routes all per-conversation native calls through [handle] — its own
/// [ConversationHandle] — so multiple sessions on one model are fully
/// isolated. [extractTextFromResponse] is a static helper on
/// [LiteRtLmFfiClient] and needs no instance.
class FfiInferenceModelSession extends InferenceModelSession
    with RawSdkResponseSession {
  FfiInferenceModelSession({
    required this.handle,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    this.enableThinking = false,
    this.maxOutputTokens,
    required this.onClose,
  });

  final ConversationHandle handle;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final bool supportAudio;
  final bool enableThinking;

  /// The cap on each reply, which decides what a completed turn reports.
  final int? maxOutputTokens;
  final VoidCallback onClose;

  /// [stopGeneration] was called during the current turn.
  bool _stopAsked = false;

  /// [turn] with a failure native ended `context_full` replaced by core's
  /// public [ContextLimitException], which says what happened and preserves
  /// native's token-count details; any other failure is passed on as it is.
  Stream<String> _namingContextFull(Stream<String> turn) => turn.transform(
    StreamTransformer.fromHandlers(
      handleError: (error, stack, sink) {
        sink.addError(
          handle.lastTurnEnd == NativeLastTurnEnd.contextFull
              ? ContextLimitException(
                  'The input token count does not fit the context window space '
                  'left; the session was restored to before this turn. Send a '
                  'shorter message, or close the session and open a new one. '
                  'Native token counts: $error',
                )
              : error,
          stack,
        );
        if (error is ResponseFormatUnsupportedException) {
          // Deliver and settle the failed turn before close changes
          // reportedEngineTurn's end to `closed`. CreateConstraint has already
          // pushed a ghost user message, so refuse another send immediately
          // and delete the conversation on the next event-loop turn.
          _closeAfterFormatRefusal();
        }
      },
    ),
  );

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

  /// Last full raw JSON response from SDK. For native tool models this is the
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
      if (message.imageBytes != null) {
        _pendingImages.add(message.imageBytes!);
      }
      for (final image in message.images) {
        if (!_pendingImages.contains(image)) {
          _pendingImages.add(image);
        }
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      _pendingAudio = message.audioBytes;
    }
  }

  /// The staged tool results as one role-`tool` message, when they are the
  /// whole turn. LiteRT-LM's template continues the model's own turn only after
  /// a `tool` message; sent as user text, the model opens a new turn and calls
  /// the same function again. A turn that also carries user text or media is a
  /// user message, so there the results stay in the text they were staged as —
  /// the history replay after a context trim stages exactly that mix.
  String? _takeToolResponseMessage() {
    final onlyTools =
        _pendingToolResponses.isNotEmpty && !_stagedNonToolContent;
    final message = onlyTools
        ? SdkResponseParser.buildToolResponsesJson(_pendingToolResponses)
        : null;
    _pendingToolResponses.clear();
    _stagedNonToolContent = false;
    return message;
  }

  /// This turn's raw SDK stream: the tool-result message when there is one,
  /// the staged user message otherwise.
  Stream<String> _rawTurn(
    String text,
    List<Uint8List>? images,
    Uint8List? audio,
    String? toolMessage,
  ) => toolMessage != null
      ? handle.chatRawMessage(toolMessage, enableThinking: enableThinking)
      : handle.chatRaw(
          text,
          imageBytes: images,
          audioBytes: audio,
          enableThinking: enableThinking,
        );

  @override
  Future<String> getResponse() async {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final audio = _pendingAudio;
    final images = _pendingImages.isNotEmpty
        ? List<Uint8List>.from(_pendingImages)
        : null;
    _pendingAudio = null;
    _pendingImages.clear();
    final toolMessage = _takeToolResponseMessage();

    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // Native tool models walk raw SDK JSON so chat.dart can read `tool_calls`
    // via [SdkResponseParser.extractToolCalls]. Other models keep the existing
    // text-only fast path (raw JSON cache stays null).
    if (_nativeTools) {
      final rawBuffer = StringBuffer();
      final textBuffer = StringBuffer();
      await for (final rawChunk in _namingContextFull(
        _rawTurn(text, images, audio, toolMessage),
      )) {
        if (firstChunkMs == null) {
          firstChunkMs = genSw.elapsedMilliseconds;
          edgeAiLog(
            '[FfiInferenceModelSession/perf] time-to-first-chunk (prefill): ${firstChunkMs}ms',
          );
        }
        chunkCount++;
        rawBuffer.write(rawChunk);
        textBuffer.write(LiteRtLmFfiClient.extractTextFromResponse(rawChunk));
      }
      _lastRawResponse = rawBuffer.toString();
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
      return textBuffer.toString();
    }

    _lastRawResponse = null;
    final buffer = StringBuffer();
    await for (final chunk in _namingContextFull(
      handle.chat(
        text,
        imageBytes: images,
        audioBytes: audio,
        enableThinking: enableThinking,
      ),
    )) {
      if (firstChunkMs == null) {
        firstChunkMs = genSw.elapsedMilliseconds;
        edgeAiLog(
          '[FfiInferenceModelSession/perf] time-to-first-chunk (prefill): ${firstChunkMs}ms',
        );
      }
      chunkCount++;
      buffer.write(chunk);
    }
    _logGenerationStats(genSw, firstChunkMs, chunkCount);
    return buffer.toString();
  }

  void _logGenerationStats(Stopwatch sw, int? firstChunkMs, int chunks) {
    final total = sw.elapsedMilliseconds;
    if (firstChunkMs == null || chunks == 0) {
      edgeAiLog(
        '[FfiInferenceModelSession/perf] generation total: ${total}ms (no chunks emitted)',
      );
      return;
    }
    final decodeMs = total - firstChunkMs;
    final decodeRate = chunks > 1 && decodeMs > 0
        ? ((chunks - 1) * 1000.0 / decodeMs).toStringAsFixed(1)
        : 'n/a';
    edgeAiLog(
      '[FfiInferenceModelSession/perf] generation total: ${total}ms '
      '(prefill ${firstChunkMs}ms + decode ${decodeMs}ms over $chunks chunks, '
      '~$decodeRate chunks/sec)',
    );
  }

  @override
  Stream<String> getResponseAsync() async* {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final audio = _pendingAudio;
    final images = _pendingImages.isNotEmpty
        ? List<Uint8List>.from(_pendingImages)
        : null;
    _pendingAudio = null;
    _pendingImages.clear();
    final toolMessage = _takeToolResponseMessage();

    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    if (_nativeTools) {
      final rawBuffer = StringBuffer();
      await for (final rawChunk in _namingContextFull(
        _rawTurn(text, images, audio, toolMessage),
      )) {
        if (firstChunkMs == null) {
          firstChunkMs = genSw.elapsedMilliseconds;
          edgeAiLog(
            '[FfiInferenceModelSession/perf] (async) time-to-first-chunk (prefill): ${firstChunkMs}ms',
          );
        }
        chunkCount++;
        rawBuffer.write(rawChunk);
        yield LiteRtLmFfiClient.extractTextFromResponse(rawChunk);
      }
      _lastRawResponse = rawBuffer.toString();
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
      return;
    }

    _lastRawResponse = null;
    await for (final chunk in _namingContextFull(
      handle.chat(
        text,
        imageBytes: images,
        audioBytes: audio,
        enableThinking: enableThinking,
      ),
    )) {
      if (firstChunkMs == null) {
        firstChunkMs = genSw.elapsedMilliseconds;
        edgeAiLog(
          '[FfiInferenceModelSession/perf] (async) time-to-first-chunk (prefill): ${firstChunkMs}ms',
        );
      }
      chunkCount++;
      yield chunk;
    }
    _logGenerationStats(genSw, firstChunkMs, chunkCount);
  }

  @override
  SessionMetrics getSessionMetrics() {
    return handle.getSessionMetrics();
  }

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
    // So the folklore is half right. Four chars per token is fine for English
    // and — surprisingly — near-exact for Russian, whose words this tokenizer
    // covers well. It is CJK that breaks it: Chinese runs ~1.8 characters per
    // token, so the estimate undercounts by more than half. Code undercounts by
    // a third.
    //
    // InferenceChat budgets the context window with this (chat.dart accumulates
    // `_currentTokens += await session.sizeInTokens(...)` and recreates the
    // session near `maxTokens`), so an undercount means it believes there is
    // headroom while the native KV cache is already full — surfacing as the
    // #318-class DYNAMIC_UPDATE_SLICE failure or silent truncation, and read as
    // a model problem rather than an estimator one. The same conversation on a
    // .task model trimmed correctly.
    //
    // The ratios are per-tokenizer, not universal: re-measure rather than
    // re-quote if the model family changes.
    // Same closed-session contract as every sibling method. Without it this
    // was the one call that survived close() — and it would have answered with
    // a plausible estimate instead of the use-after-close error the caller
    // gets everywhere else.
    _assertNotClosed();

    final exact = await handle.tokenCount(text);
    if (exact != null) return exact;

    // Engine down, or the native call failed. Fall back to the estimate rather
    // than throw — this feeds budgeting, not correctness — but say so, because
    // a silent estimate is what got us here.
    // Fall back, but err HIGH — and note that this warning does not reach a
    // release build at all (`gemmaLog` is `kDebugMode`-gated and
    // dead-code-eliminated), so the fallback has to be safe on its own rather
    // than merely announced.
    //
    // The two directions are not symmetric. Overcounting trims history and
    // recreates the session a little early — cheap, recoverable, visible.
    // Undercounting overruns the native KV cache, which is the #318-class
    // DYNAMIC_UPDATE_SLICE crash. `len/4` was measured at 0.44x on Chinese and
    // 0.75x on code, i.e. it errs in the crash direction on exactly the inputs
    // that break. Two characters per token bounds every case measured
    // (densest was ~1.8), so it over-counts English by roughly 2x and never
    // under-counts.
    if (!_tokenFallbackWarned) {
      _tokenFallbackWarned = true;
      edgeAiLog(
        '[LiteRtLmFfi] sizeInTokens: native tokenizer unavailable; estimating '
        'conservatively at 2 chars/token for the rest of this session. '
        'Context budgeting will over-count, trimming history earlier than '
        'necessary — the safe direction.',
      );
    }
    return (text.length / 2).ceil();
  }

  /// One-shot latch for the estimate warning. Without it the message fires
  /// once per turn and once per trimmed message, which is the volume that
  /// teaches people to scroll past it.
  bool _tokenFallbackWarned = false;

  @override
  Future<void> stopGeneration() async {
    _stopAsked = true;
    handle.cancelGeneration();
  }

  /// How the turn ended, for core's chat: a close the consumer did not ask
  /// for ends [getResponseAsync] with a [LiteRtLmTurnClosedException]; here
  /// the text ends cleanly and `end` is [TurnEnd.closed], so the chat keeps
  /// the partial reply before it raises (decision H).
  ///
  /// A turn's end is what native's turn-end record says
  /// ([liteRtLmCompletedTurnEnd]). A turn native ended `context_full` (the
  /// input did not fit what the window has left) fails its text with a
  /// [ContextLimitException], and its end is [TurnEnd.contextLimit];
  /// core's chat then takes the refused message back out of its history. The
  /// handle restores the conversation before the next turn (core 2.6.0
  /// design §6.4b).
  @override
  EngineTurn startTurn() {
    _stopAsked = false;
    return reportedEngineTurn(
      getResponseAsync(),
      stopped: () => _stopAsked,
      closed: () => _isClosed,
      isCloseError: (error) => error is LiteRtLmTurnClosedException,
      completed: () =>
          liteRtLmCompletedTurnEnd(handle.lastTurnEnd, maxOutputTokens),
    );
  }

  @override
  Future<void> close() async {
    // Idempotent: a superseded singleton session and the live one can both
    // be closed by a caller, and createSession also closes the prior
    // session before opening a new one — a second close must not re-run
    // handle.close() / onClose(). See the createSession comment and #308.
    if (_isClosed) return;
    _isClosed = true;
    _queryBuffer.clear();
    _pendingImages.clear();
    _pendingAudio = null;
    _pendingToolResponses.clear();
    handle.close();
    onClose();
  }
}

/// How a native turn whose text ran to its end ended, from native's turn-end
/// record ([NativeLastTurnEnd], §23): the end of the reply is
/// [TurnEnd.endOfSequence], `max_output_tokens` [TurnEnd.outputLimit], a
/// decode that filled the context window (and an input that did not fit,
/// should one ever end without an error) [TurnEnd.contextLimit]. Without a
/// record, or with one no completed send leaves, it is
/// [liteRtLmPlaceholderCompletedEnd]'s guess.
@visibleForTesting
TurnEnd liteRtLmCompletedTurnEnd(
  NativeLastTurnEnd? end,
  int? maxOutputTokens,
) => switch (end) {
  NativeLastTurnEnd.completed => TurnEnd.endOfSequence,
  NativeLastTurnEnd.outputLimit => TurnEnd.outputLimit,
  NativeLastTurnEnd.contextLimit ||
  NativeLastTurnEnd.contextFull => TurnEnd.contextLimit,
  NativeLastTurnEnd.none ||
  NativeLastTurnEnd.cancelled ||
  NativeLastTurnEnd.failed ||
  NativeLastTurnEnd.running ||
  NativeLastTurnEnd.refused ||
  null => liteRtLmPlaceholderCompletedEnd(maxOutputTokens),
};

/// How long a turn waits for a stopped one to wind down before going ahead —
/// the same bound VoiceSession gives a stopped reply to drain.
const _windDownTimeout = Duration(seconds: 5);

/// How [LiteRtLmFfiClient.extractTextFromResponse] marks a thought chunk.
@visibleForTesting
const thoughtChunkPrefix = '<|channel>thought\n';

/// The handle of a session's own native conversation — [createSession]'s, and
/// each [openSession] session's where they are native
/// ([OpenSessionBacking.native]) — made to answer again after a turn is
/// stopped or its input did not fit.
///
/// A conversation whose generation was cancelled mid-turn answers every later
/// message with nothing — zero chunks in about a millisecond, on every turn
/// after, measured on native 0.16.0 through 0.17.1. So the first turn after a
/// stop first rewinds the conversation to before the stopped turn and puts that
/// turn back, partial reply included ([ConversationHandle.rewindStoppedTurn]):
/// the model keeps everything, images and audio too. Where it cannot — on the
/// NPU, whose executor rolls back one token at most, on a model with linear
/// attention state, which a rewind cannot restore, or on a libLiteRtLm without
/// the rewind — it replaces the conversation with a new one seeded with the
/// history this handle records, as a `messages_json` preface, including image
/// and audio parts.
///
/// A turn native ended `context_full` (§23: its input did not fit what the
/// window has left) leaves the conversation failing every later send. The
/// next turn first rewinds it to that turn's checkpoint, without the input
/// that did not fit, or rebuilds it where it cannot rewind. Nothing of the
/// history is dropped (core 2.6.0 design §6.4b, as decided for a raw
/// session): when the window has no room for any input left, every later
/// turn ends the same way, and the app decides — `InferenceChat` rotates its
/// session by its own token budget.
///
/// A cancel that arrives after a turn has finished does not count: Dart
/// delivers a stream's `done` by cancelling its subscription, which cancels
/// the native conversation on every normal turn, and that leaves it healthy.
///
/// Public, though nothing outside this library uses it, so that tests can drive
/// the recovery over fake handles with no engine.
class RecoveringConversationHandle implements ConversationHandle {
  RecoveringConversationHandle(
    this._live, {
    required this.reopen,
    this.noRewindReason,
    this.windDownTimeout = _windDownTimeout,
  });

  /// Why this conversation is never rewound and is rebuilt from history instead
  /// (the NPU, a model with linear attention state), or null when a stopped
  /// turn and a full context are rewound before falling back to a rebuild.
  final String? noRewindReason;

  /// Whether a stopped turn or a full context is rewound before falling back
  /// to a rebuild.
  bool get canRewind => noRewindReason == null;

  /// How long a turn waits for a stopped one to record itself. See [_turn].
  final Duration windDownTimeout;

  ConversationHandle _live;

  /// Opens a conversation with this session's config, seeded with
  /// [messagesJson] when given.
  final Future<ConversationHandle> Function(String? messagesJson) reopen;

  /// Kept private so full-message recovery does not enlarge this test-facing
  /// class's public constructor. The owning model sets its configured order.
  MultimodalOrder _multimodalOrder = MultimodalOrder.imagesAudioText;

  /// Every turn so far, as the messages a rebuild replays.
  final List<Map<String, Object?>> _history = [];

  /// True from the start of a turn — rebuild included — to the end of its
  /// `finally`.
  bool _inFlight = false;

  /// A cancel landed inside the current turn. Reset when the next turn starts.
  bool _stopRequested = false;

  /// Completes when the latest turn to start has run its `finally`: each turn
  /// waits for the one before it, so turns take the conversation one at a
  /// time, and a stopped turn's end is known before the next one decides how
  /// to recover.
  Future<void>? _turnDone;

  /// The turn that holds the conversation — past its wait — and so owns
  /// [_inFlight], [_stopRequested] and the stop it may leave behind.
  Completer<void>? _current;

  /// Counts [cancelGeneration] calls, so a turn still waiting for the one
  /// before it can tell that a stop came meanwhile.
  int _stopEpoch = 0;

  /// Set when a turn that reached the model was cut off; the next turn
  /// recovers the conversation before it runs.
  bool _stopped = false;

  /// The reply the stopped turn had produced, which a rewind puts back after
  /// its message. Null when the next recovery must rebuild instead, unless
  /// [_takeBack] is set.
  Map<String, Object?>? _stoppedReply;

  /// The next recovery rewinds the last turn out, with nothing put back: a
  /// turn stopped before it produced anything (Rule A), or one whose input
  /// did not fit the window (§23). Where it cannot rewind, it rebuilds from
  /// the history, which the turn is not in.
  bool _takeBack = false;

  /// Why a conversation that can rewind is rebuilt instead.
  String? _rebuildBecause;

  /// True while the conversation is being rewound or rebuilt. Nothing is
  /// generating then, and a native cancel would abort the rewind's prefill.
  bool _recovering = false;

  bool _closed = false;

  Future<void> _rebuild() async {
    // Deleted first: the old conversation's KV cache is freed before the new
    // one is allocated (and on LiteRT-LM 0.18, upstream #966, the engine held
    // one live conversation).
    _live.close();
    _live = await reopen(
      _history.isEmpty ? null : LiteRtLmFfiClient.buildHistoryJson(_history),
    );
    // Only now: a reopen that throws leaves the old conversation closed and
    // this set, so the next turn tries again instead of using a dead handle.
    _stopped = false;
    if (_closed) {
      _live.close();
      throw StateError('Conversation handle is closed');
    }
    edgeAiLog(
      '[FfiInferenceModel] rebuilt the conversation after a stopped turn or '
      'a full context (${_history.length} messages replayed)',
    );
  }

  /// The recovery in progress. A turn that starts meanwhile waits for it, and
  /// its wind-down bound does not run out while a long rewind (an audio clip
  /// re-encoded on a phone CPU) still uses the conversation.
  Future<void>? _recovery;

  /// Makes the conversation answer again after a stopped turn: rewinds it when
  /// it can, and rebuilds it when it cannot or the rewind fails.
  Future<void> _recover() async {
    final reply = _stoppedReply;
    final takeBack = _takeBack;
    final rebuildBecause = _rebuildBecause;
    _stoppedReply = null;
    _takeBack = false;
    _rebuildBecause = null;
    _recovering = true;
    try {
      if (canRewind && (reply != null || takeBack)) {
        StoppedTurnRewind? result;
        StoppedTurnRewindException? failure;
        try {
          result = await _live.rewindStoppedTurn(takeBack ? null : reply);
        } on StoppedTurnRewindException catch (e) {
          failure = e;
        } catch (_) {
          // Not a rewind failure (a closed client, a bug): the conversation is
          // as the stop left it, so the next turn tries again from the start.
          _stoppedReply = reply;
          _takeBack = takeBack;
          _rebuildBecause = rebuildBecause;
          rethrow;
        }
        if (_closed) throw StateError('Conversation handle is closed');
        switch (result) {
          case StoppedTurnRewind.rewound:
            _stopped = false;
            edgeAiLog(
              '[FfiInferenceModel] rewound the conversation after a stopped '
              'turn or a full context',
            );
            return;
          case StoppedTurnRewind.notCancelled when !takeBack:
            _stopped = false;
            edgeAiLog(
              '[FfiInferenceModel] the stopped turn had ended natively before '
              'the stop; the conversation is kept as it is',
            );
            return;
          case StoppedTurnRewind.notCancelled:
            // The turn to take out had ended natively, so native keeps it:
            // only a rebuild leaves it out.
            break;
          case StoppedTurnRewind.unsupported:
          case null:
            break;
        }
        // Printed in release builds too. An unsupported rewind (an older
        // libLiteRtLm) is not a failure and rebuilds quietly.
        if (failure != null) {
          // ignore: avoid_print
          print(
            '[flutter_edge_ai_litertlm] could not rewind the conversation '
            'after a stopped turn or a full context ($failure); rebuilding it',
          );
        }
      } else if (canRewind && rebuildBecause != null) {
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] rebuilding the conversation: '
          '$rebuildBecause',
        );
      }
      await _rebuild();
    } finally {
      _recovering = false;
    }
  }

  /// Runs one turn on the live conversation, recovering it first if the
  /// previous turn was stopped, and records the turn for the next rebuild.
  /// [raw] says whether [send] yields raw SDK JSON or plain text.
  Stream<String> _turn(
    Map<String, Object?> message,
    Stream<String> Function(ConversationHandle live) send, {
    required bool raw,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    final epoch = _stopEpoch;
    final previous = _turnDone;
    final done = Completer<void>();
    _turnDone = done.future;
    // What the reply showed: thought chunks are left out, as native leaves a
    // finished turn's thoughts out of the context.
    final visible = StringBuffer();
    final rawReply = StringBuffer();
    // Any non-empty chunk, thoughts included, as core's chat counts text.
    var streamed = false;
    var sent = false;
    var finished = false;
    var failed = false;
    var poisoned = false;
    try {
      if (previous != null) {
        // The turn before this one decides whether this one recovers first,
        // and a rebuild must replay its exchange, so wait for its `finally`.
        // Bounded: a consumer that pauses a stream and never resumes it would
        // otherwise block every later turn. Past the bound, a stopped turn is
        // treated as having damaged the conversation, which is rebuilt without
        // its exchange; a turn that is still generating normally is left
        // alone, and the native lock queues this one behind it.
        await previous.timeout(
          windDownTimeout,
          onTimeout: () {
            if (!_stopRequested) {
              edgeAiLog(
                '[FfiInferenceModel] the previous turn is still generating '
                'after ${windDownTimeout.inSeconds}s; this one waits for it',
              );
              return;
            }
            _stopped = true;
            _stoppedReply = null;
            _rebuildBecause =
                'the previous turn did not wind down within '
                '${windDownTimeout.inSeconds}s';
            edgeAiLog(
              '[FfiInferenceModel] a stopped turn did not wind down within '
              '${windDownTimeout.inSeconds}s (is its stream paused?); '
              'rebuilding without it',
            );
          },
        );
      }
      // A recovery cannot be cut short (native bounds it); one that started
      // while this turn waited is still using the conversation.
      for (var r = _recovery; r != null; r = _recovery) {
        await r.catchError((Object _) {});
      }
      if (_closed) throw StateError('Conversation handle is closed');
      _current = done;
      _inFlight = true;
      _stopRequested = false;
      _latestSent = false;
      if (_stopped) {
        final recovery = _recovery = _recover();
        try {
          await recovery;
        } finally {
          if (identical(_recovery, recovery)) _recovery = null;
        }
      }
      // Stopped while this turn waited for the one before it, or while the
      // conversation was being recovered: nothing has reached the model, so
      // there is nothing to generate and nothing to record.
      if (_stopEpoch != epoch) return;
      sent = true;
      _latestSent = true;
      await for (final chunk in send(_live)) {
        final text = raw
            ? LiteRtLmFfiClient.extractTextFromResponse(chunk)
            : chunk;
        if (text.isNotEmpty) streamed = true;
        if (!text.startsWith(thoughtChunkPrefix)) visible.write(text);
        if (raw) rawReply.write(chunk);
        yield chunk;
      }
      finished = true;
    } on LiteRtLmTurnCancelledException {
      // Native cancelled a turn nobody stopped: an earlier cancel poisoned the
      // conversation. The model saw nothing of this turn; the next one rebuilds.
      poisoned = true;
      rethrow;
    } catch (_) {
      // An error after the consumer asked to stop is the stop's: the turn
      // ends cleanly as stopped, as core's reportedEngineTurn ends it (a stop
      // wins over a failure).
      if (_stopRequested) return;
      // Any other failure is taken back (decision W): see the `finally`.
      failed = true;
      rethrow;
    } finally {
      // A turn that winds down after the next one took the conversation (past
      // its bound) leaves the shared state to that one.
      final latest = identical(_current, done);
      if (latest) _inFlight = false;
      if (poisoned) {
        if (latest) {
          _stopped = true;
          _stoppedReply = null;
          _rebuildBecause = 'native cancelled a turn that was not stopped';
        }
      } else if (sent) {
        // Stopped by cancelGeneration, or abandoned mid-turn — which cancels
        // native the same way — leaves the conversation answering nothing.
        final stopped = _stopRequested || (!finished && !failed);
        final reply = _VirtualConversationHandle._assistantTurn(
          visible.toString(),
          rawReply.toString(),
        );
        final end = _live.lastTurnEnd;
        if (failed) {
          // Decision W: a failed turn is taken back on both sides, never
          // replayed. One native ended context_full (section 23) is rewound
          // out (native drops its input; it fails every later send until
          // then); one native refused before it started left nothing to undo;
          // any other (a decode error, a resource other than the window) is
          // rebuilt without it, as native does not rewind a failed send.
          if (latest && end != NativeLastTurnEnd.refused) {
            _stopped = true;
            _stoppedReply = null;
            if (end == NativeLastTurnEnd.contextFull) {
              _takeBack = true;
              _rebuildBecause = 'the context window was full';
            } else {
              _rebuildBecause = 'the last turn failed';
            }
          }
        } else if (stopped && !streamed) {
          // Rule A: a turn stopped before it produced anything is taken back
          // on both sides, rewound out of the conversation.
          if (latest) {
            _stopped = true;
            _stoppedReply = null;
            _takeBack = true;
          }
        } else {
          if (stopped && latest) {
            _stopped = true;
            _stoppedReply = reply;
          }
          // The message reached the model, so it belongs in the history a
          // rebuild replays — with whatever of the reply was produced.
          _history
            ..add(message)
            ..add(reply);
        }
      }
      done.complete();
    }
  }

  /// The complete user message a rebuild replays, including media.
  Map<String, Object?> _message(
    String text,
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
  ) =>
      jsonDecode(
            LiteRtLmFfiClient.buildMessageJson(
              text,
              imagesBytes: imageBytes,
              audioBytes: audioBytes,
              order: _multimodalOrder,
            ),
          )
          as Map<String, Object?>;

  @override
  Future<int?> tokenCount(String text) => _live.tokenCount(text);

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _message(text, imageBytes, audioBytes),
    (live) => live.chat(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: false,
  );

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _message(text, imageBytes, audioBytes),
    (live) => live.chatRaw(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: true,
  );

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) => _turn(
    jsonDecode(messageJson) as Map<String, Object?>,
    (live) => live.chatRawMessage(messageJson, enableThinking: enableThinking),
    raw: true,
  );

  @override
  void cancelGeneration() {
    // A turn still waiting for the one before it hears of this and does not
    // start.
    _stopEpoch++;
    // Only a cancel that lands inside a turn damages the conversation. The
    // turn's `finally` turns this into a recovery if generation had begun.
    if (_inFlight) _stopRequested = true;
    // The turn returns after the recovery instead of generating.
    if (_recovering) return;
    _live.cancelGeneration();
  }

  /// Recovery after a stop is this handle's own job, done at the next turn.
  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  SessionMetrics getSessionMetrics() => _live.getSessionMetrics();

  /// The latest turn reached its send, so native's record is that turn's
  /// end; a turn that failed before it (a recovery that threw) has none.
  bool _latestSent = false;

  @override
  NativeLastTurnEnd? get lastTurnEnd => _latestSent ? _live.lastTurnEnd : null;

  @override
  int? get lastTurnCode => _latestSent ? _live.lastTurnCode : null;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _history.clear();
    // The native handle waits for an operation still running on it (a rewind,
    // a generation) before it deletes the conversation.
    _live.close();
  }
}

/// A [ConversationHandle] backed by the virtual-session multiplexer.
///
/// On LiteRT-LM 0.18 the engine allowed only ONE live conversation at a time
/// (upstream #966); 0.19 lifts it, but only where several live conversations
/// were verified does an [openSession] session get its own
/// ([OpenSessionBacking.native]). Everywhere else each virtual handle keeps
/// its full multimodal turn history in Dart and, on every generate, asks the
/// client to (re)materialize the single shared conversation seeded with THIS
/// session's history via a `messages_json` preface. The client serializes turns
/// with a mutex, so the sessions are logically concurrent (independent
/// contexts) but inference is serialized (one generation at a time) — verified by the
/// session_switch / messages_preface smoke tests.
///
/// Same-session follow-up turns reuse the live conversation (no rebuild);
/// only switching to a different session pays the teardown+replay cost.
class _VirtualConversationHandle implements ConversationHandle {
  _VirtualConversationHandle({
    required this.client,
    required this.systemMessage,
    required this.toolsJson,
    required this.sampling,
    required this.samplingExplicit,
    required this.multimodalOrder,
    required this.filterChannelContent,
    this.maxOutputTokens,
    this.jsonSchema,
  });

  final LiteRtLmFfiClient client;
  final String? systemMessage;
  final String? toolsJson;
  final ResolvedSampling sampling;
  final bool samplingExplicit;
  final MultimodalOrder multimodalOrder;
  final int? maxOutputTokens;
  final String? jsonSchema;
  final bool filterChannelContent;

  /// The tokenizer belongs to the engine, not to a conversation, so a virtual
  /// session answers this as accurately as a live one.
  @override
  Future<int?> tokenCount(String text) => client.tokenCount(text);

  /// Unique identity for this virtual session — the client uses it to tell
  /// whether the live conversation already holds this session's history.
  final Object token = Object();

  /// Completed turns, replayed as a `messages_json` preface to rebuild this
  /// session's context when it next becomes active. Whole messages rather than
  /// role and text, because a tool round is an assistant turn with
  /// `tool_calls` followed by a role-`tool` message, and neither survives being
  /// flattened to text.
  final List<Map<String, Object?>> _history = [];

  bool _closed = false;

  /// This session's own turn is running. See [cancelGeneration].
  bool _inFlight = false;

  /// A cancel landed inside this session's current turn.
  bool _stopRequested = false;

  /// Completes when the current turn has recorded its history.
  Future<void>? _turnDone;

  /// Drive one turn through the multiplexer, then record the sent [message]
  /// and the generated assistant reply so the NEXT turn replays them as
  /// preface. [raw] decides what the caller gets per chunk (raw SDK JSON or its
  /// text); history records the reply the same way either way.
  Stream<String> _run(
    Map<String, Object?> message, {
    required bool raw,
    bool enableThinking = false,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    // After a stop the client rebuilds the conversation from this snapshot,
    // so a turn that starts before the stopped one has recorded itself waits
    // for it — otherwise the rebuild would leave the stopped exchange out.
    if (_stopRequested) {
      // Bounded for the reason given in RecoveringConversationHandle._turn.
      await _turnDone?.timeout(_windDownTimeout, onTimeout: () {});
    }
    final done = Completer<void>();
    _turnDone = done.future;
    _inFlight = true;
    _stopRequested = false;
    final messageJson = jsonEncode(message);
    final extraContext = thinkingExtraContext(enableThinking);
    // Snapshot history BEFORE this turn — the live message is sent separately.
    final historySnapshot = List<Map<String, Object?>>.from(_history);
    final assistantText = StringBuffer();
    final assistantRaw = StringBuffer();
    var recorded = false;
    var failed = false;
    void record() {
      if (recorded) return;
      recorded = true;
      // Record both turns so the next switch back replays the full context.
      _history.add(message);
      _history.add(
        _assistantTurn(assistantText.toString(), assistantRaw.toString()),
      );
    }

    _latestStarted = true;
    try {
      await for (final rawChunk in client.startVirtualTurn(
        conversationToken: token,
        messageJson: messageJson,
        history: historySnapshot,
        systemMessage: systemMessage,
        toolsJson: toolsJson,
        sampling: sampling,
        samplingExplicit: samplingExplicit,
        extraContext: extraContext,
        thinking: enableThinking,
        maxOutputTokens: maxOutputTokens,
        jsonSchema: jsonSchema,
        filterChannelContent: filterChannelContent,
      )) {
        final chunkText = LiteRtLmFfiClient.extractTextFromResponse(rawChunk);
        assistantText.write(chunkText);
        assistantRaw.write(rawChunk);
        yield raw ? rawChunk : chunkText;
      }
      // A stop ends the stream cleanly: a stopped turn that produced nothing
      // is not recorded (Rule A).
      if (!_stopRequested || assistantText.isNotEmpty) record();
    } catch (_) {
      // Decision W: a failed turn is taken back on both sides; the shared
      // conversation is rebuilt from this history, which it is not in.
      failed = true;
      rethrow;
    } finally {
      // A stopped or abandoned turn keeps what it produced, as core's chat
      // does; one that produced nothing is taken back (Rule A).
      if (!failed && assistantText.isNotEmpty) record();
      client.finishVirtualStoppedTurn(
        token,
        messageJson: messageJson,
        // Decision W takes a failed turn back even if it streamed text.
        partialReply: failed || assistantText.isEmpty
            ? null
            : _assistantTurn(assistantText.toString(), assistantRaw.toString()),
        extraContext: extraContext,
      );
      _inFlight = false;
      done.complete();
    }
  }

  /// The assistant turn to replay: its tool calls when it made any, so the
  /// tool results recorded after it still answer something, and its text
  /// otherwise.
  static Map<String, Object?> _assistantTurn(String text, String raw) {
    final calls = SdkResponseParser.extractToolCalls(raw);
    if (calls.isEmpty) {
      return {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      };
    }
    return {
      'role': 'assistant',
      'tool_calls': [
        for (final call in calls)
          {
            'type': 'function',
            'function': {'name': call.name, 'arguments': call.args},
          },
      ],
    };
  }

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _latestStarted = false;
    return _run(
      _userMessage(text, imageBytes, audioBytes),
      raw: false,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _latestStarted = false;
    return _run(
      _userMessage(text, imageBytes, audioBytes),
      raw: true,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) => _run(
    jsonDecode(messageJson) as Map<String, Object?>,
    raw: true,
    enableThinking: enableThinking,
  );

  Map<String, Object?> _userMessage(
    String text,
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
  ) =>
      jsonDecode(
            LiteRtLmFfiClient.buildMessageJson(
              text,
              imagesBytes: imageBytes,
              audioBytes: audioBytes,
              order: multimodalOrder,
            ),
          )
          as Map<String, Object?>;

  @override
  void cancelGeneration() {
    if (_inFlight) _stopRequested = true;
    client.cancelVirtualTurn(token);
  }

  /// The multiplexer rebuilds a stopped conversation from this session's full
  /// multimodal history at its next turn.
  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  SessionMetrics getSessionMetrics() => client.virtualSessionMetrics(token);

  /// The latest turn reached native; a turn refused before it has no end of
  /// its own to report.
  bool _latestStarted = false;

  @override
  NativeLastTurnEnd? get lastTurnEnd =>
      _latestStarted ? client.virtualLastTurnEnd(token) : null;

  @override
  int? get lastTurnCode =>
      _latestStarted ? client.virtualLastTurnCode(token) : null;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _history.clear();
    client.releaseVirtualConversation(token);
  }
}

/// Test seam for the history a virtual session would replay on its next turn.
@visibleForTesting
List<Map<String, Object?>> virtualConversationHistoryForTest(
  ConversationHandle handle,
) {
  if (handle is! _VirtualConversationHandle) {
    throw ArgumentError.value(handle, 'handle', 'is not a virtual session');
  }
  return List.unmodifiable(handle._history);
}

/// Test seam for driving the client's side of a consumer cancellation without
/// calling [_VirtualConversationHandle.cancelGeneration], which deliberately
/// marks the turn as an explicit stop instead.
@visibleForTesting
Object virtualConversationTokenForTest(ConversationHandle handle) {
  if (handle is! _VirtualConversationHandle) {
    throw ArgumentError.value(handle, 'handle', 'is not a virtual session');
  }
  return handle.token;
}

/// [OptionScorer] over the engine an [FfiInferenceModel] loaded. Holds no
/// native resource between calls: each scoring pass opens and deletes its own
/// session.
final class _LiteRtLmOptionScorer extends OptionScorer {
  _LiteRtLmOptionScorer(this._model);

  final FfiInferenceModel _model;
  bool _closed = false;

  /// The stop flags of this scorer's native runs, its share of the self-check
  /// included: [close] stops them.
  final ScoringStops _stops = ScoringStops();

  /// Every call goes through here, so a scorer or model closed between calls
  /// is a stop, not a failure: a scorer waiting on this one's self-check runs
  /// it again for itself (see `_scoringCheckFor`).
  LiteRtLmFfiClient get _client {
    if (_closed) throw ScoringStoppedError('The option scorer is closed.');
    if (_model.isClosed) throw ScoringStoppedError('The model is closed.');
    return _model.ffiClient;
  }

  @override
  Future<List<int>> tokenize(String text) => _client.tokenIds(text);

  @override
  Future<String> detokenize(List<int> ids) => _client.detokenizeIds(ids);

  @override
  Future<String> renderUserMessage(String content) =>
      _client.renderUserMessage(content);

  @override
  Future<void> prepare(List<String> targets) =>
      _model._scoringCheckFor(this, targets);

  @override
  Future<OptionScoringRun> score(
    String prompt,
    List<String> targets, {
    CancelToken? cancelToken,
  }) async {
    await _model._scoringCheckFor(this, targets);
    // The session adds BOS itself, so a prompt that starts with its text
    // would carry two.
    if (prompt.startsWith('<bos>')) {
      throw const DeciderUnsupportedException(
        'The rendered prompt starts with <bos>, which the scoring session '
        'adds itself.',
      );
    }
    return _client.scoreTargets(
      prompt,
      targets,
      cancelToken: cancelToken,
      stops: _stops,
    );
  }

  /// Also stops this scorer's native runs in flight — a decision's, or the
  /// self-check it started — at their next check, so a closed decider does
  /// not keep the engine busy scoring options nobody will read.
  @override
  Future<void> close() async {
    _closed = true;
    _stops.stopAll();
  }
}
