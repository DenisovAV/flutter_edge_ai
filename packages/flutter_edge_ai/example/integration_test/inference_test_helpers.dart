// Shared helpers for inference integration tests.
// Not a test file — imported by inference_*_test.dart files.
//
// Prerequisites: push models to device before running tests:
//   ./scripts/prepare_test_models.sh [device_id]
//
// Models are loaded from /data/local/tmp/flutter_gemma_test/ on device.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:integration_test/integration_test.dart';

/// Call once in main() of each test file.
void initIntegrationTest() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Registers the opt-in inference engine + embedding backend + STT backend
/// the tests need.
///
/// As of 1.0, `.litertlm` inference and LiteRT embeddings are provided by the
/// `flutter_edge_ai_litertlm` package (embedder decoupling, 1.5.0: the
/// `LiteRtEmbeddingBackend` moved there from `flutter_edge_ai_embeddings`,
/// which is now a runtime-agnostic pipeline with no concrete backend of its
/// own), NOT core; on-device STT is provided by `flutter_edge_ai_speech`. The
/// integration tests
/// drive the SDK directly, so each test must register the providers via the
/// public `FlutterEdgeAi.initialize` opt-in API. Registration is idempotent
/// (the registry dedups by instance), so calling this in every `setUpAll` —
/// even alongside a test's own `FlutterEdgeAi.initialize(...)` — is safe.
/// Forwards [maxDownloadRetries] so callers can replace their bare
/// `FlutterEdgeAi.initialize(maxDownloadRetries: N)` with this one call.
Future<void> registerTestEngines({int maxDownloadRetries = 3}) {
  return FlutterEdgeAi.initialize(
    maxDownloadRetries: maxDownloadRetries,
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    sttBackends: const [LiteRtSttBackend()],
  );
}

/// Device path where models are pushed via adb.
const _deviceModelDir = '/data/local/tmp/flutter_gemma_test';

/// Platform-aware model configuration for inference tests.
/// Models loaded from device filesystem (pushed via adb).
class TestModelConfig {
  final String filePath;
  final String filename;
  final ModelFileType fileType;

  const TestModelConfig({
    required this.filePath,
    required this.filename,
    required this.fileType,
  });

  /// Default config for current platform.
  static TestModelConfig forCurrentPlatform() {
    return mediapipeConfig;
  }

  /// MediaPipe engine (.task)
  static const mediapipeConfig = TestModelConfig(
    filePath: '$_deviceModelDir/functiongemma-270M-it.task',
    filename: 'functiongemma-270M-it.task',
    fileType: ModelFileType.task,
  );

  /// All engine configs to test on current platform.
  static List<({TestModelConfig config, String label})>
  allForCurrentPlatform() {
    return [(config: forCurrentPlatform(), label: 'default engine')];
  }
}

/// Idempotent model installation — skips if already active.
Future<void> ensureModelInstalled([TestModelConfig? config]) async {
  config ??= TestModelConfig.forCurrentPlatform();

  if (FlutterEdgeAi.hasActiveModel()) {
    debugPrint('[Test] Active model found, skipping install');
    return;
  }

  await forceInstallModel(config);
}

/// Force install a specific model config from device file.
Future<void> forceInstallModel(TestModelConfig config) async {
  debugPrint('[Test] Installing model from file: ${config.filePath}');

  await FlutterEdgeAi.installModel(
    modelType: ModelType.functionGemma,
    fileType: config.fileType,
  ).fromFile(config.filePath).install();

  debugPrint('[Test] Model installed successfully');
}

/// Create a test model with conservative settings.
Future<InferenceModel> createTestModel({int maxTokens = 512}) async {
  return await FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: PreferredBackend.cpu,
  );
}

/// Create a chat from a model with FunctionGemma model type.
Future<InferenceChat> createTestChat(InferenceModel model) async {
  return await model.createChat(modelType: ModelType.functionGemma);
}
