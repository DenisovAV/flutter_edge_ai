// Shared helpers for genkit_flutter_gemma integration tests.
// Not a test file — imported by *_test.dart files.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';
import 'package:integration_test/integration_test.dart';

/// Call once in main() of each test file.
void initIntegrationTest() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Initialize flutter_gemma with the opt-in engines/backends the tests need.
///
/// flutter_gemma 1.0.0 split engines and embedding backends into separate
/// packages; core registers none by default, so tests must register the
/// providers explicitly before installing or running any model.
Future<void> initializeGemmaForTest() async {
  await FlutterGemma.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  );
}

/// Model URLs for FunctionGemma 270M IT (284MB, no auth required).
const _taskUrl =
    'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task';
const _litertlmUrl =
    'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.litertlm';

/// Canonical model name used across all integration tests.
const kTestModelName = 'function-gemma-270m-it';

/// Timeout for a single inference call.
const kInferenceTimeout = Duration(minutes: 5);

/// Timeout for model download + install.
const kInstallTimeout = Duration(minutes: 10);

/// Platform-aware model configuration for integration tests.
class TestModelConfig {
  final String url;
  final String filename;
  final ModelFileType fileType;

  const TestModelConfig({
    required this.url,
    required this.filename,
    required this.fileType,
  });

  /// Default config for current platform:
  /// - Web/iOS/Android -> .task (MediaPipe)
  /// - Desktop (macOS/Windows/Linux) -> .litertlm (LiteRT-LM)
  static TestModelConfig forCurrentPlatform() {
    if (kIsWeb) return mediapipeConfig;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return litertlmConfig;
    }
    return mediapipeConfig; // Android, iOS
  }

  /// MediaPipe engine (.task)
  static const mediapipeConfig = TestModelConfig(
    url: _taskUrl,
    filename: 'functiongemma-270M-it.task',
    fileType: ModelFileType.task,
  );

  /// LiteRT-LM engine (.litertlm)
  static const litertlmConfig = TestModelConfig(
    url: _litertlmUrl,
    filename: 'functiongemma-270M-it.litertlm',
    fileType: ModelFileType.litertlm,
  );

  /// All engine configs to test on current platform.
  /// Android gets both engines, others get one.
  static List<({TestModelConfig config, String label})>
  allForCurrentPlatform() {
    final configs = [(config: forCurrentPlatform(), label: 'default engine')];
    if (!kIsWeb && Platform.isAndroid) {
      configs.add((config: litertlmConfig, label: 'LiteRT-LM'));
    }
    return configs;
  }
}

/// Idempotent model installation — skips download if already active.
Future<void> ensureModelInstalled([TestModelConfig? config]) async {
  config ??= TestModelConfig.forCurrentPlatform();

  if (FlutterGemma.hasActiveModel()) {
    debugPrint('[Test] Active model found, skipping download');
    return;
  }

  await forceInstallModel(config);
}

/// Force install a specific model config (always installs, even if another model is active).
Future<void> forceInstallModel(TestModelConfig config) async {
  debugPrint('[Test] Installing model: ${config.filename} from ${config.url}');

  await FlutterGemma.installModel(
        modelType: ModelType.functionGemma,
        fileType: config.fileType,
      )
      .fromNetwork(config.url)
      .withProgress(
        (progress) => debugPrint('[Test] Download progress: $progress%'),
      )
      .install();

  debugPrint('[Test] Model installed successfully');
}

/// Creates a fully configured [Genkit] instance for integration tests.
///
/// Uses real [DefaultFlutterGemmaRuntime] — no fakes.
Genkit createTestGenkit([TestModelConfig? config]) {
  config ??= TestModelConfig.forCurrentPlatform();

  return Genkit(
    plugins: [
      GenkitFlutterGemmaPlugin(
        models: [
          FlutterGemmaModelConfig(
            name: kTestModelName,
            modelType: ModelType.functionGemma,
            fileType: config.fileType,
          ),
        ],
      ),
    ],
  );
}

/// Creates a [Genkit] instance with both model and embedder configured.
Genkit createTestGenkitWithEmbedder([TestModelConfig? config]) {
  config ??= TestModelConfig.forCurrentPlatform();

  return Genkit(
    plugins: [
      GenkitFlutterGemmaPlugin(
        models: [
          FlutterGemmaModelConfig(
            name: kTestModelName,
            modelType: ModelType.functionGemma,
            fileType: config.fileType,
          ),
        ],
        embedders: [FlutterGemmaEmbedderConfig(name: 'embedding-gemma-300m')],
      ),
    ],
  );
}

/// Convenience [ModelRef] for the test model.
final testModelRef = flutterGemma.model(kTestModelName);

/// Convenience [EmbedderRef] for the test embedder.
final testEmbedderRef = flutterGemma.embedder('embedding-gemma-300m');
