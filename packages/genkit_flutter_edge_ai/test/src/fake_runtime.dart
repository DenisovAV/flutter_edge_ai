import 'dart:async';

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

  final FakeInferenceModel modelToReturn;
  final FakeEmbeddingModel embedderToReturn;
  int getActiveModelCallCount = 0;
  int getActiveEmbedderCallCount = 0;

  bool? lastEnableSpeculativeDecoding;
  gemma.PreferredBackend? lastPreferredBackend;
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
    lastPreferredBackend = preferredBackend;
    return embedderToReturn;
  }
}

/// Fake inference model that returns a [FakeInferenceChat] from [createChat].
class FakeInferenceModel extends gemma.InferenceModel {
  int _maxTokens = 1024;
  FakeInferenceChat? chatToReturn;
  int createChatCallCount = 0;

  @override
  int get maxTokens => _maxTokens;

  @override
  gemma.ModelFileType get fileType => gemma.ModelFileType.task;

  @override
  gemma.PreferredBackend? get activeBackend => null;

  @override
  void addCloseListener(void Function() listener) {
    // No-op: the fake holds no native handle to close.
  }

  @override
  gemma.InferenceModelSession? get session => null;

  @override
  set chat(gemma.InferenceChat? chat) {}

  @override
  gemma.InferenceChat? get chat => null;

  gemma.ToolChoice? lastToolChoice;
  String? lastSystemInstruction;
  int? lastMaxFunctionBufferLength;

  @override
  Future<gemma.InferenceChat> createChat({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<gemma.Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    gemma.ModelType? modelType,
    gemma.ToolChoice toolChoice = gemma.ToolChoice.auto,
    String? systemInstruction,
    int? maxFunctionBufferLength,
    int? maxOutputTokens,
  }) async {
    createChatCallCount++;
    lastToolChoice = toolChoice;
    lastSystemInstruction = systemInstruction;
    lastMaxFunctionBufferLength = maxFunctionBufferLength;
    return chatToReturn ?? FakeInferenceChat();
  }

  @override
  Future<gemma.InferenceModelSession> createSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
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

  @override
  Future<void> close() async {}
}

/// Fake chat that returns preconfigured responses.
class FakeInferenceChat extends gemma.InferenceChat {
  FakeInferenceChat() : super(sessionCreator: null, maxTokens: 1024);

  /// Response returned by [generateChatResponse].
  gemma.ModelResponse blockingResponse = const gemma.TextResponse(
    'fake response',
  );

  /// Responses yielded by [generateChatResponseAsync].
  List<gemma.ModelResponse> streamingResponses = [
    const gemma.TextResponse('fake '),
    const gemma.TextResponse('response'),
  ];

  /// Messages received via [addQueryChunk].
  final List<gemma.Message> receivedMessages = [];

  int addQueryChunkCallCount = 0;

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
    receivedMessages.add(message);
  }

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

  /// Called as [generateChatResponse] starts.
  void Function()? onGenerate;

  @override
  Future<gemma.ModelResponse> generateChatResponse() async {
    onGenerate?.call();
    await generationGate?.future;
    if (generationError case final error?) {
      generationError = null;
      throw error;
    }
    return blockingResponse;
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

  @override
  Stream<gemma.ModelResponse> generateChatResponseAsync() async* {
    for (final (index, response) in streamingResponses.indexed) {
      yield response;
      // With a gate, the stream pauses after its first chunk until the gate
      // opens, so a test can cancel mid-stream.
      if (index == 0) await generationGate?.future;
    }
  }

  @override
  Future<void> close() async {}
}

/// Fake embedding model that returns preconfigured embeddings.
class FakeEmbeddingModel implements gemma.EmbeddingModel {
  /// Embeddings returned by [generateEmbeddings].
  List<List<double>> embeddingsToReturn = [];

  int generateEmbeddingCallCount = 0;
  int generateEmbeddingsCallCount = 0;
  List<String> lastTexts = [];

  /// `implements` does not inherit the interface's default, so this has to be
  /// spelled out. CPU matches every real embedder.
  @override
  gemma.PreferredBackend? get activeBackend => gemma.PreferredBackend.cpu;

  // `implements` does not inherit the interface's default, so this has to
  // be spelled out. The fake is never closed.
  @override
  bool get isClosed => false;

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    gemma.TaskType taskType = gemma.TaskType.retrievalQuery,
  }) async {
    generateEmbeddingCallCount++;
    lastTexts = [text];
    return embeddingsToReturn.isNotEmpty ? embeddingsToReturn.first : [];
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    gemma.TaskType taskType = gemma.TaskType.retrievalQuery,
  }) async {
    generateEmbeddingsCallCount++;
    lastTexts = texts;
    return embeddingsToReturn;
  }

  @override
  Future<int> getDimension() async => 256;

  @override
  void addCloseListener(void Function() listener) {
    // No-op: the fake holds no native handle to close.
  }

  @override
  Future<void> close() async {}
}
