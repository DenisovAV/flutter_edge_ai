import 'package:pigeon/pigeon.dart';
// Command to generate: dart run pigeon --input pigeon.dart

/// Hardware backend for model inference. Redeclared here (pigeon generates
/// self-contained code per package and cannot import core's generated enum).
/// Same values/order as core's PreferredBackend → identical wire index. The
/// Dart MediaPipeEngine maps core.PreferredBackend → this enum at the boundary.
enum PreferredBackend {
  cpu,
  gpu,
  npu,
}

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/pigeon.g.dart',
  kotlinOut:
      'android/src/main/kotlin/dev/flutterberlin/flutter_gemma_mediapipe/PigeonInterface.g.kt',
  kotlinOptions:
      KotlinOptions(package: 'dev.flutterberlin.flutter_gemma_mediapipe'),
  swiftOut: 'ios/Classes/PigeonInterface.g.swift',
  swiftOptions: SwiftOptions(),
  dartPackageName: 'flutter_gemma_mediapipe',
))
@HostApi()
abstract class PlatformService {
  @async
  void createModel({
    required int maxTokens,
    required String modelPath,
    required List<int>? loraRanks,
    PreferredBackend? preferredBackend,
    // Add image support
    int? maxNumImages,
    // Add audio support (Gemma 3n E4B)
    bool? supportAudio,
  });

  @async
  void closeModel();

  @async
  void createSession({
    required double temperature,
    required int randomSeed,
    required int topK,
    double? topP,
    String? loraPath,
    // Add option to enable vision modality
    bool? enableVisionModality,
    // Add option to enable audio modality (Gemma 3n E4B)
    bool? enableAudioModality,
    // System instruction for LiteRT-LM native support
    String? systemInstruction,
    // Enable thinking mode (Gemma 4 via extraContext)
    bool? enableThinking,
  });

  @async
  void closeSession();

  @async
  int sizeInTokens(String prompt);

  @async
  void addQueryChunk(String prompt);

  // Add method for adding image
  @async
  void addImage(Uint8List imageBytes);

  // Add method for adding audio (Gemma 3n E4B)
  @async
  void addAudio(Uint8List audioBytes);

  @async
  String generateResponse();

  @async
  void generateResponseAsync();

  @async
  void stopGeneration();

  // === Multi-session (MediaPipe .task path) ===
  // Session-scoped twins of the singleton methods above, keyed by an int
  // [sessionId]. The legacy methods stay the singleton path (one implicit
  // session); these address one of N concurrently-open sessions. The native
  // side holds a Map<sessionId, session>. Generation is serialized in Dart
  // (a Mutex) so only one session generates at a time — concurrent contexts,
  // serialized inference (same model as the .litertlm FFI path). Async
  // results stream over the same `flutter_gemma_stream` EventChannel with a
  // `sessionId` key added to the payload so Dart can demux.

  @async
  void createSessionForId({
    required int sessionId,
    required double temperature,
    required int randomSeed,
    required int topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool? enableThinking,
  });

  @async
  void closeSessionId(int sessionId);

  @async
  int sizeInTokensForSession(int sessionId, String prompt);

  @async
  void addQueryChunkToSession(int sessionId, String prompt);

  @async
  void addImageToSession(int sessionId, Uint8List imageBytes);

  @async
  void addAudioToSession(int sessionId, Uint8List audioBytes);

  @async
  String generateResponseForSession(int sessionId);

  @async
  void generateResponseAsyncForSession(int sessionId);

  @async
  void stopGenerationForSession(int sessionId);

  // 0.15.2: embedding methods removed from the pigeon contract — Android
  // and iOS now run embedding inference in Dart via LitertEmbeddingModel
  // (see lib/core/litert/litert_embedding_model.dart). No platform channel
  // hop on either OS.
}
