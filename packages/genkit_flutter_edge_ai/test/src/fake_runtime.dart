import 'dart:async';

import 'package:flutter_edge_ai/engine.dart'
    show ChatTurnHooks, EngineTurn, ResolvedChatRequest, SessionRequest;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_runtime.dart';

/// Test double for [FlutterEdgeAiRuntime].
///
/// Allows tests to configure model and embedder responses
/// without depending on the real flutter_edge_ai static API.
class FakeRuntime implements FlutterEdgeAiRuntime {
  FakeRuntime({FakeInferenceModel? model, FakeEmbeddingModel? embedder})
    : modelToReturn = model ?? FakeInferenceModel(),
      embedderToReturn = embedder ?? FakeEmbeddingModel();

  /// What [getActiveModel] returns; a test swaps it to stand for a newly
  /// built model.
  FakeInferenceModel modelToReturn;

  /// What [getActiveEmbedder] returns once [embedderQueue] is empty.
  FakeEmbeddingModel embedderToReturn;

  /// Handed out, in order, before [embedderToReturn] — so a test can serve a
  /// model that is already closed and then a fresh one.
  final embedderQueue = <FakeEmbeddingModel>[];
  int getActiveModelCallCount = 0;
  int getActiveEmbedderCallCount = 0;

  bool? lastEnableSpeculativeDecoding;
  gemma.PreferredBackend? lastPreferredBackend;

  /// When set, [getActiveModel] and [getActiveEmbedder] throw it.
  Object? loadError;
  gemma.PreferredBackend? lastPreferredVisionBackend;
  gemma.PreferredBackend? lastPreferredAudioBackend;

  @override
  Future<gemma.InferenceModel> getActiveModel({
    int maxTokens = 1024,
    bool supportImage = false,
    bool supportAudio = false,
    bool? enableSpeculativeDecoding,
    gemma.PreferredBackend? preferredBackend,
    gemma.PreferredBackend? preferredVisionBackend,
    gemma.PreferredBackend? preferredAudioBackend,
  }) async {
    getActiveModelCallCount++;
    if (loadError case final error?) throw error;
    modelToReturn._maxTokens = maxTokens;
    lastEnableSpeculativeDecoding = enableSpeculativeDecoding;
    lastPreferredBackend = preferredBackend;
    lastPreferredVisionBackend = preferredVisionBackend;
    lastPreferredAudioBackend = preferredAudioBackend;
    return modelToReturn;
  }

  @override
  Future<gemma.EmbeddingModel> getActiveEmbedder({
    gemma.PreferredBackend? preferredBackend,
  }) async {
    getActiveEmbedderCallCount++;
    if (loadError case final error?) throw error;
    lastPreferredBackend = preferredBackend;
    return embedderQueue.isEmpty ? embedderToReturn : embedderQueue.removeAt(0);
  }
}

/// Fake inference model that backs each prompt-only [openChat] with a
/// [FakeInferenceChat].
class FakeInferenceModel extends gemma.InferenceModel {
  int _maxTokens = 1024;
  FakeInferenceChat? chatToReturn;
  int promptOpenChatCallCount = 0;

  /// Without [chatToReturn], each prompt-only [openChat] gets a fresh fake
  /// chat from this (a plain one when unset) and records it in [chats].
  FakeInferenceChat Function()? newChat;

  /// The fake chats backing prompt-only [openChat] calls, in order.
  final List<FakeInferenceChat> chats = [];
  final List<FakeInferenceChat> _pendingPlainChats = [];

  @override
  int get maxTokens => _maxTokens;

  @override
  gemma.ModelFileType get fileType => gemma.ModelFileType.task;

  @override
  gemma.PreferredBackend? get activeBackend => null;

  final List<void Function()> _closeListeners = [];

  @override
  void addCloseListener(void Function() listener) =>
      _closeListeners.add(listener);

  @override
  gemma.InferenceModelSession? get session => null;

  @override
  set chat(gemma.InferenceChat? chat) {}

  @override
  gemma.InferenceChat? get chat => null;

  gemma.ToolChoice? lastToolChoice;
  String? lastSystemInstruction;
  int? lastMaxFunctionBufferLength;
  int? lastMaxOutputTokens;
  ({double? temperature, int? topK, double? topP, int? randomSeed})?
  lastSampling;

  @override
  ChatTurnHooks createChatTurnHooks(ResolvedChatRequest request) {
    if (request.responseFormat != null) {
      return super.createChatTurnHooks(request);
    }
    promptOpenChatCallCount++;
    lastToolChoice = request.toolChoice;
    lastSystemInstruction = request.systemInstruction;
    lastMaxFunctionBufferLength = request.maxFunctionBufferLength;
    lastMaxOutputTokens = request.maxOutputTokens;
    lastSampling = (
      temperature: request.temperature,
      topK: request.topK,
      topP: request.topP,
      randomSeed: request.randomSeed,
    );
    final chat = chatToReturn ?? newChat?.call() ?? FakeInferenceChat();
    chats.add(chat);
    _pendingPlainChats.add(chat);
    return chat._turns;
  }

  /// What the model enforces; null = core's default, which refuses every
  /// format.
  gemma.StructuredOutputSupport? structuredSupport;

  @override
  gemma.StructuredOutputSupport get engineStructuredOutputSupport =>
      structuredSupport ?? super.engineStructuredOutputSupport;

  /// The engine's own refusal, by call (1 for the first): core asks once in
  /// `refusalFor` and again in `openChat`.
  gemma.ResponseFormatUnsupportedException? Function(int call)? refusal;
  int refusalCalls = 0;

  @override
  gemma.ResponseFormatUnsupportedException? engineRefusalFor(
    gemma.JsonSchemaResponseFormat format,
  ) => refusal?.call(++refusalCalls);

  /// What core's `openChat` asked the engine for, one per session it opened.
  final List<SessionRequest> sessionRequests = [];

  /// The sessions core's `openChat` opened, in order.
  final List<FakeStructuredSession> openedSessions = [];

  /// Each session core's `openChat` opens comes from this (a session that
  /// answers `{}` when unset).
  FakeStructuredSession Function()? newSession;

  @override
  Future<gemma.InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    if (request.responseFormat == null && _pendingPlainChats.isNotEmpty) {
      return _FakeChatSession(_pendingPlainChats.removeAt(0));
    }
    sessionRequests.add(request);
    final session = newSession?.call() ?? FakeStructuredSession();
    openedSessions.add(session);
    return session;
  }

  @override
  List<gemma.InferenceModelSession> get engineSessions => [
    for (final session in openedSessions)
      if (!session.closed) session,
  ];

  @override
  Future<gemma.InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<gemma.Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    throw UnimplementedError('FakeInferenceModel.createSession');
  }

  /// Fires the close listeners, as a real model does when core closes it to
  /// build another.
  @override
  Future<void> close() async {
    final listeners = [..._closeListeners];
    _closeListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// Fake chat that returns preconfigured responses.
///
/// Core runs both generation paths through one [ChatTurnHooks.responses], so
/// whichever of [blockingResponse] and [streamingResponses] a test assigned
/// last is what every turn produces; [generateChatResponse] collects it.
class FakeInferenceChat extends gemma.InferenceChat {
  FakeInferenceChat() : this._(_FakeTurns());

  FakeInferenceChat._(this._turns)
    : super(sessionCreator: null, maxTokens: 1024, turnHooks: _turns) {
    _turns.chat = this;
  }

  final _FakeTurns _turns;

  /// The turn when a test scripted it as one response, as a blocking call
  /// returns it.
  gemma.ModelResponse get blockingResponse => _blockingResponse;
  set blockingResponse(gemma.ModelResponse response) {
    _blockingResponse = response;
    _streamed = false;
  }

  gemma.ModelResponse _blockingResponse = const gemma.TextResponse(
    'fake response',
  );

  /// The turn when a test scripted it as chunks, as a stream yields them.
  List<gemma.ModelResponse> get streamingResponses => _streamingResponses;
  set streamingResponses(List<gemma.ModelResponse> responses) {
    _streamingResponses = responses;
    _streamed = true;
  }

  List<gemma.ModelResponse> _streamingResponses = [
    const gemma.TextResponse('fake '),
    const gemma.TextResponse('response'),
  ];

  /// Which script was assigned last; the defaults read the same either way.
  bool _streamed = false;

  /// Messages received via [addQueryChunk].
  final List<gemma.Message> receivedMessages = [];

  int addQueryChunkCallCount = 0;

  /// What the chat's session reports after a generation; without it the
  /// session is unset, as on an engine that reports nothing. A closed chat
  /// has no session either.
  gemma.SessionMetrics? sessionMetrics;

  @override
  gemma.InferenceModelSession get session =>
      _MetricsSession(sessionMetrics, closed: closeCallCount > 0);

  @override
  Future<void> initSession() async {
    // No-op: no real session needed.
  }

  @override
  Future<void> addQueryChunk(
    gemma.Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) async {
    addQueryChunkCallCount++;
    if (addQueryChunkError case final error?) throw error;
    receivedMessages.add(message);
  }

  /// When set, [addQueryChunk] fails with it.
  Object? addQueryChunkError;

  /// When set, [generateChatResponse] waits on it, so a test can cancel in
  /// the middle of a generation; [stopGeneration] completes it.
  Completer<void>? generationGate;

  int stopGenerationCallCount = 0;

  /// When set, [stopGeneration] stays in flight until it completes.
  Completer<void>? stopLanding;

  /// When set, [stopGeneration] fails with it.
  Object? stopError;

  /// When set, the next [generateChatResponse] fails with it (once).
  Object? generationError;

  /// Called as a turn scripted with [blockingResponse] starts.
  void Function()? onGenerate;

  Stream<gemma.ModelResponse> _turn() async* {
    if (_streamed) {
      for (final (index, response) in streamingResponses.indexed) {
        yield response;
        // With a gate, the stream pauses after its first chunk until the
        // gate opens, so a test can cancel mid-stream.
        if (index == 0) await generationGate?.future;
      }
      return;
    }
    onGenerate?.call();
    await generationGate?.future;
    if (generationError case final error?) {
      generationError = null;
      throw error;
    }
    yield blockingResponse;
  }

  /// When true, [stopGeneration] throws before returning its future.
  bool stopThrowsSynchronously = false;

  @override
  Future<void> stopGeneration() {
    stopGenerationCallCount++;
    final gate = generationGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (stopThrowsSynchronously) {
      throw StateError('stop failed synchronously');
    }
    return _landStop();
  }

  Future<void> _landStop() async {
    await stopLanding?.future;
    if (stopError case final error?) throw error;
  }

  /// Closes that have completed, failed ones included. A close completes a
  /// turn of the event loop after it is called, so a caller that does not
  /// await it is caught counting zero.
  int closeCallCount = 0;

  /// When set, [close] fails with it.
  Object? closeError;

  @override
  Future<void> close() async {
    await Future<void>.delayed(Duration.zero);
    closeCallCount++;
    if (closeError case final error?) throw error;
  }
}

/// The engine session under a prompt-only core [gemma.InferenceModel.openChat].
/// Its turn hooks use [chat] for replies; the remaining operations delegate so
/// existing tests can script and inspect the same fake chat.
final class _FakeChatSession extends gemma.InferenceModelSession {
  _FakeChatSession(this.chat);

  final FakeInferenceChat chat;

  @override
  EngineTurn startTurn() =>
      throw StateError('The fake chat supplies responses');

  @override
  Stream<String> getResponseAsync() =>
      throw StateError('The fake chat supplies responses');

  @override
  Future<String> getResponse() =>
      throw StateError('The fake chat supplies responses');

  @override
  Future<int> sizeInTokens(String text) async => text.length;

  @override
  Future<void> addQueryChunk(gemma.Message message) =>
      chat.addQueryChunk(message);

  @override
  Future<void> stopGeneration() => chat.stopGeneration();

  @override
  gemma.SessionMetrics getSessionMetrics() =>
      chat.sessionMetrics ?? gemma.SessionMetrics();

  @override
  Future<void> close() => chat.close();
}

/// An engine session for core's `openChat`: each turn streams [tokens] and
/// ends with [end], as an engine that reports how its turns end does.
final class FakeStructuredSession extends gemma.InferenceModelSession {
  FakeStructuredSession({
    this.tokens = const ['{}'],
    this.end = gemma.TurnEnd.endOfSequence,
  });

  List<String> tokens;
  gemma.TurnEnd end;

  /// When set, a turn pauses after its first token until it completes;
  /// [stopGeneration] completes it and ends the turn as stopped.
  Completer<void>? gate;

  final List<gemma.Message> received = [];
  int turns = 0;
  int stops = 0;
  bool closed = false;

  /// When set, the next turn fails with it before any text.
  Object? startError;

  /// When set, a turn's text fails with it before any token, as an engine
  /// that refused the input does.
  Object? errorBeforeText;

  /// When set, a turn fails with it after its first token.
  Object? errorAfterFirst;

  /// When true, a stopped turn still ends with [end], as an engine whose
  /// stop raced another end reports it.
  bool endIgnoresStop = false;

  @override
  EngineTurn startTurn() {
    if (startError case final error?) {
      startError = null;
      throw error;
    }
    turns++;
    final ended = Completer<gemma.TurnEnd>();
    Stream<String> text() async* {
      try {
        if (errorBeforeText case final error?) throw error;
        for (final (index, token) in tokens.indexed) {
          yield token;
          if (index == 0) {
            await gate?.future;
            if (errorAfterFirst case final error?) throw error;
          }
          if (stops > 0) break;
        }
      } finally {
        // At the end of the text, also when the consumer cancels it.
        if (!ended.isCompleted) {
          ended.complete(
            stops > 0 && !endIgnoresStop ? gemma.TurnEnd.stopped : end,
          );
        }
      }
    }

    return EngineTurn(text: text(), end: ended.future);
  }

  @override
  Stream<String> getResponseAsync() => startTurn().text;

  @override
  Future<String> getResponse() => getResponseAsync().join();

  @override
  Future<int> sizeInTokens(String text) async => text.length;

  @override
  Future<void> addQueryChunk(gemma.Message message) async =>
      received.add(message);

  @override
  Future<void> stopGeneration() async {
    stops++;
    final gate = this.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  gemma.SessionMetrics getSessionMetrics() =>
      gemma.SessionMetrics(outputTokens: tokens.length);

  @override
  Future<void> close() async => closed = true;
}

/// The turns of a [FakeInferenceChat], as core's chat asks for them.
final class _FakeTurns extends ChatTurnHooks {
  late final FakeInferenceChat chat;

  @override
  Stream<gemma.ModelResponse> responses(
    gemma.InferenceModelSession session, {
    required int tokenBuffer,
  }) => chat._turn();

  @override
  Future<void>? addQueryChunk(
    gemma.InferenceModelSession session,
    gemma.Message message,
  ) => chat.addQueryChunk(message);
}

/// Fake embedding model in the shape core 2.3 requires of a fake: a `final
/// class` extending `EmbeddingModel` that implements `dimension`, `isClosed`,
/// `embed`, `addCloseListener` and `close`. A closed one fails every request
/// with `EmbedderClosedException`, as core's model does.
final class FakeEmbeddingModel extends gemma.EmbeddingModel {
  FakeEmbeddingModel({this.vectorFor});

  /// When set, every input's vector is computed from its text and task, the
  /// way a real model's is; [embeddingsToReturn] is then ignored.
  final List<double> Function(String text, gemma.TaskType taskType)? vectorFor;

  /// What [embedAll] returns when [vectorFor] is null.
  List<List<double>> embeddingsToReturn = [];

  /// When set, every request fails with it.
  Object? failWith;

  int embedAllCallCount = 0;
  gemma.CancelToken? lastCancelToken;

  /// Called as [embedAll] starts, before anything else.
  void Function()? onEmbedAll;
  List<String> lastTexts = [];
  gemma.TaskType? lastTaskType;
  bool closed = false;
  final _closeListeners = <void Function()>[];

  @override
  int get dimension => 256;

  @override
  bool get isClosed => closed;

  /// CPU, as every real embedder answers.
  @override
  gemma.PreferredBackend? get activeBackend => gemma.PreferredBackend.cpu;

  @override
  Future<List<double>> embed(
    gemma.EmbeddingInput input, {
    required gemma.TaskType taskType,
  }) async {
    _refuseIfUnusable();
    final compute = vectorFor;
    if (compute != null) return compute(input.text ?? '', taskType);
    return embeddingsToReturn.isNotEmpty ? embeddingsToReturn.first : [];
  }

  @override
  Future<List<List<double>>> embedAll(
    List<gemma.EmbeddingInput> inputs, {
    required gemma.TaskType taskType,
    gemma.CancelToken? cancelToken,
  }) async {
    embedAllCallCount++;
    onEmbedAll?.call();
    lastCancelToken = cancelToken;
    lastTexts = [for (final input in inputs) input.text ?? ''];
    lastTaskType = taskType;
    _refuseIfUnusable();
    if (vectorFor != null) {
      return super.embedAll(
        inputs,
        taskType: taskType,
        cancelToken: cancelToken,
      );
    }
    return embeddingsToReturn;
  }

  void _refuseIfUnusable() {
    if (closed) throw const gemma.EmbedderClosedException();
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  void addCloseListener(void Function() listener) =>
      _closeListeners.add(listener);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final listener in _closeListeners) {
      listener();
    }
  }
}

/// A session that only reports its metrics, and fails to when it has none,
/// as on an engine that reports nothing.
class _MetricsSession implements gemma.InferenceModelSession {
  _MetricsSession(this.metrics, {required this.closed});

  final gemma.SessionMetrics? metrics;

  /// The chat was closed: a closed session reports nothing.
  final bool closed;

  @override
  gemma.SessionMetrics getSessionMetrics() {
    if (closed) throw StateError('FakeInferenceChat is closed');
    return metrics ??
        (throw StateError('FakeInferenceChat has no session metrics'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_MetricsSession: ${invocation.memberName}');
}
