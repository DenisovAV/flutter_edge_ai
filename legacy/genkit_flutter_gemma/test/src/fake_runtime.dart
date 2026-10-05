import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit_flutter_gemma/src/flutter_gemma_runtime.dart';

/// Test double for [FlutterGemmaRuntime].
///
/// Allows tests to configure model and embedder responses
/// without depending on the real flutter_gemma static API.
class FakeRuntime implements FlutterGemmaRuntime {
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
    bool isThinking = false,
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

  @override
  Future<gemma.ModelResponse> generateChatResponse() async {
    return blockingResponse;
  }

  @override
  Stream<gemma.ModelResponse> generateChatResponseAsync() async* {
    for (final response in streamingResponses) {
      yield response;
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
