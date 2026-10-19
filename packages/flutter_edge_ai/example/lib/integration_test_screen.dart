import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as legacy;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_edge_ai_example/rag_demo_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:math';

/// Manual integration testing screen.
///
/// Installs inference and embedding models from every source type (network,
/// asset, bundled, file) through both `ModelFileManager` specs and the
/// `FlutterEdgeAi.installModel()` / `installEmbedder()` builders, then runs
/// them on a real device. Download reliability (progress, resume, temp-file
/// reclaim) is driven by `integration_test/download_reliability_test.dart`
/// and `download_temp_reclaim_device_test.dart`.
class IntegrationTestScreen extends StatefulWidget {
  const IntegrationTestScreen({super.key});

  @override
  State<IntegrationTestScreen> createState() => _IntegrationTestScreenState();
}

class _IntegrationTestScreenState extends State<IntegrationTestScreen> {
  final Map<String, int> _progress = {};
  bool _isTesting = false;
  String _testStatus = 'Ready';

  // Model readiness flags
  bool _inferenceModelReady = false;
  bool _embeddingModelReady = false;
  bool _bundledInferenceModelReady = false;
  bool _bundledEmbeddingModelReady = false;

  // Run All Tests state
  String _runAllTestsProgress = '';
  int _currentTestIndex = 0;
  int _totalTests = 0;

  // Custom path controllers
  final TextEditingController _customInferencePathController =
      TextEditingController();
  final TextEditingController _customEmbeddingModelPathController =
      TextEditingController();
  final TextEditingController _customEmbeddingTokenizerPathController =
      TextEditingController();
  final TextEditingController _huggingFaceTokenController =
      TextEditingController(
        text: const String.fromEnvironment(
          'HUGGINGFACE_TOKEN',
          defaultValue: '',
        ),
      );

  // Model URLs
  // Note: Gemma models require accepting license at https://huggingface.co/litert-community/gemma-3-270m-it
  static const inferenceModelUrl =
      'https://huggingface.co/litert-community/gemma-3-270m-it/resolve/main/gemma3-270m-it-q8.task';

  static const embeddingModelUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite';

  static const embeddingTokenizerUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model';

  // Asset paths (real files in example/assets/models/)
  static const inferenceAssetPath = 'assets/models/gemma3-270m-it-q8.task';
  static const embeddingModelAssetPath =
      'assets/models/embeddinggemma-300M_seq1024_mixed-precision.tflite';
  static const embeddingTokenizerAssetPath =
      'assets/models/sentencepiece.model';

  // Bundled resource names (android/src/main/assets/models/, Xcode resources)
  static const bundledInferenceResource = 'gemma3-270m-it-q8.task';
  static const bundledEmbeddingModelResource =
      'embeddinggemma-300M_seq1024_mixed-precision.tflite';
  static const bundledEmbeddingTokenizerResource = 'sentencepiece.model';

  // Specs for the ModelFileManager path, built with the public constructors
  // and an explicit ModelSource.
  static InferenceModelSpec _networkInferenceSpec(String name) =>
      InferenceModelSpec(
        name: name,
        modelSource: ModelSource.network(inferenceModelUrl),
        modelType: ModelType.general,
      );

  static InferenceModelSpec _assetInferenceSpec(String name) =>
      InferenceModelSpec(
        name: name,
        modelSource: ModelSource.asset(inferenceAssetPath),
        replacePolicy: ModelReplacePolicy.replace,
        modelType: ModelType.general,
      );

  static InferenceModelSpec _bundledInferenceSpec() => InferenceModelSpec(
    name: bundledInferenceResource.split('.').first,
    modelSource: ModelSource.bundled(bundledInferenceResource),
    replacePolicy: ModelReplacePolicy.replace,
    modelType: ModelType.general,
  );

  static EmbeddingModelSpec _networkEmbeddingSpec(String name) =>
      EmbeddingModelSpec(
        name: name,
        modelSource: ModelSource.network(embeddingModelUrl),
        tokenizerSource: ModelSource.network(embeddingTokenizerUrl),
      );

  static EmbeddingModelSpec _assetEmbeddingSpec(String name) =>
      EmbeddingModelSpec(
        name: name,
        modelSource: ModelSource.asset(embeddingModelAssetPath),
        tokenizerSource: ModelSource.asset(embeddingTokenizerAssetPath),
      );

  static EmbeddingModelSpec _bundledEmbeddingSpec() => EmbeddingModelSpec(
    name: bundledEmbeddingModelResource.split('.').first,
    modelSource: ModelSource.bundled(bundledEmbeddingModelResource),
    tokenizerSource: ModelSource.bundled(bundledEmbeddingTokenizerResource),
  );

  @override
  void initState() {
    super.initState();
    _setDefaultPaths();
    _checkInstalledModels();
  }

  /// Set platform-specific default paths for custom path fields
  Future<void> _setDefaultPaths() async {
    // Skip on web - FileSource not supported
    if (kIsWeb) return;

    if (Platform.isAndroid) {
      // Android: Use app's private storage (accessible via run-as in debug mode)
      _customInferencePathController.text =
          '/data/data/dev.flutterberlin.flutter_gemma_example/app_flutter/gemma3-270m-it-q8.task';
      _customEmbeddingModelPathController.text =
          '/data/data/dev.flutterberlin.flutter_gemma_example/app_flutter/embeddinggemma-300M_seq1024_mixed-precision.tflite';
      _customEmbeddingTokenizerPathController.text =
          '/data/data/dev.flutterberlin.flutter_gemma_example/app_flutter/sentencepiece.model';
    } else if (Platform.isIOS) {
      // iOS: Use Documents directory
      try {
        final documentsDir = await getApplicationDocumentsDirectory();
        _customInferencePathController.text =
            '${documentsDir.path}/gemma3-270m-it-q8.task';
        _customEmbeddingModelPathController.text =
            '${documentsDir.path}/embeddinggemma-300M_seq1024_mixed-precision.tflite';
        _customEmbeddingTokenizerPathController.text =
            '${documentsDir.path}/sentencepiece.model';
      } catch (e) {
        debugPrint('Failed to get Documents directory: $e');
      }
    }
  }

  /// Check if models are already installed and update UI flags
  Future<void> _checkInstalledModels() async {
    // Web uses different model management (WebModelManager, not ServiceRegistry)
    if (kIsWeb) {
      return;
    }

    try {
      // Modern API: List all installed models
      final installedModels = await FlutterEdgeAi.listInstalledModels();

      if (installedModels.isEmpty) {
        _log('📦 No installed models found');
        return;
      }

      _log('📦 Found ${installedModels.length} installed model(s):');
      for (final modelId in installedModels) {
        _log('  • $modelId');
      }

      // Check for inference models (typically end with .task or .bin)
      final inferenceModels = installedModels
          .where((id) => id.endsWith('.task') || id.endsWith('.bin'))
          .toList();

      if (inferenceModels.isNotEmpty) {
        setState(() => _inferenceModelReady = true);
        _log(
          '✅ ${inferenceModels.length} inference model(s) ready for testing',
        );
      }

      // Check for embedding models (typically .tflite and .model files)
      final embeddingModels = installedModels
          .where((id) => id.endsWith('.tflite') || id.endsWith('.model'))
          .toList();

      if (embeddingModels.length >= 2) {
        setState(() => _embeddingModelReady = true);
        _log('✅ Embedding model files ready for testing');
      }
    } catch (e) {
      _log('⚠️ Error checking installed models: $e');
    }
  }

  @override
  void dispose() {
    _customInferencePathController.dispose();
    _customEmbeddingModelPathController.dispose();
    _customEmbeddingTokenizerPathController.dispose();
    _huggingFaceTokenController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    debugPrint('[$timestamp] $message');
  }

  Future<void> _runTest(String testName, Future<void> Function() testFn) async {
    if (_isTesting) {
      _log('⚠️  Another test is running, please wait...');
      return;
    }

    setState(() {
      _isTesting = true;
      _testStatus = 'Test is running';
    });

    _log('🔵 Starting test: $testName');

    try {
      await testFn();
      _log('✅ Test completed: $testName');
      setState(() {
        _testStatus = 'Passed';
      });
    } catch (e, st) {
      _log('❌ Test failed: $testName');
      _log('Error: $e');
      _log('Stack: ${st.toString().split('\n').take(3).join('\n')}');
      setState(() {
        _testStatus = 'Failed';
      });
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  // === STORAGE MANAGEMENT METHODS ===

  Future<void> _showOrphanedFiles() async {
    await _runTest('Show Orphaned Files', () async {
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      final orphanedFiles = await manager.getOrphanedFiles();

      _log('📋 Orphaned Files:');
      if (orphanedFiles.isEmpty) {
        _log('✅ No orphaned files found');
      } else {
        for (final file in orphanedFiles) {
          _log('  • ${file.filename} - ${file.sizeMB.toStringAsFixed(2)} MB');
        }
        _log('Total orphaned: ${orphanedFiles.length} files');
      }
    });
  }

  Future<void> _cleanupOrphanedFiles() async {
    await _runTest('Cleanup Orphaned Files', () async {
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

      // First show what will be deleted
      final orphanedFiles = await manager.getOrphanedFiles();
      if (orphanedFiles.isEmpty) {
        _log('✅ No orphaned files to cleanup');
        return;
      }

      _log('⚠️  Will delete ${orphanedFiles.length} files:');
      for (final file in orphanedFiles) {
        _log('  • ${file.filename} - ${file.sizeMB.toStringAsFixed(2)} MB');
      }

      // Perform cleanup
      final deletedCount = await manager.cleanupStorage();
      _log('✅ Cleaned up $deletedCount files');
    });
  }

  Future<void> _showStorageStats() async {
    await _runTest('Show Storage Stats', () async {
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      final stats = await manager.getStorageInfo();

      _log('📊 Storage Statistics:');
      _log('  Total files: ${stats.totalFiles}');
      _log('  Total size: ${stats.totalSizeMB.toStringAsFixed(2)} MB');
      _log('  Orphaned files: ${stats.orphanedFiles.length}');
      _log('  Orphaned size: ${stats.orphanedSizeMB.toStringAsFixed(2)} MB');

      if (stats.orphanedFiles.isNotEmpty) {
        _log('  Orphaned list:');
        for (final file in stats.orphanedFiles) {
          _log('    • ${file.filename} - ${file.sizeMB.toStringAsFixed(2)} MB');
        }
      }
    });
  }

  // === INFERENCE MODEL TEST METHODS ===

  // === BUNDLED MODELS ===

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testBundledInferenceLegacy_internal() async {
    _log('📦 [LEGACY] Testing bundled inference model (zero-copy)...');

    // Clean all bundled-related SharedPreferences to ensure fresh start
    _log('🧹 Cleaning SharedPreferences to ensure fresh start...');
    final prefs = await SharedPreferences.getInstance();
    final allKeys = prefs.getKeys();
    final bundledKeys = allKeys
        .where(
          (key) =>
              key.startsWith('bundled_path_') ||
              key == 'installed_models' ||
              key == 'installed_loras' ||
              key == 'installed_model_file_name' ||
              key == 'installed_lora_file_name',
        )
        .toList();

    for (final key in bundledKeys) {
      final oldValue = prefs.get(key);
      await prefs.remove(key);
      _log('  🗑️  Removed: $key = $oldValue');
    }
    _log('✅ SharedPreferences cleaned (${bundledKeys.length} keys removed)');

    try {
      const resourceName = bundledInferenceResource;

      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

      _log('🔧 Creating BundledSource spec...');

      final spec = _bundledInferenceSpec();

      _log('🔍 Created BundledSource spec: ${spec.name}');
      _log('🔍 Model source type: ${spec.files.first.source.runtimeType}');

      // Cleanup: Delete model if already installed (for honest testing)
      if (await manager.isModelInstalled(spec)) {
        _log('🧹 Cleaning up existing model before test...');
        await manager.deleteModel(spec);
      }

      // Legacy API: Ensure model ready
      await manager.ensureModelReadyFromSpec(spec);

      _log('✅ [LEGACY] Bundled model installed (zero-copy!)');

      // Check what path was saved to SharedPreferences
      final savedPath = prefs.getString('bundled_path_$resourceName');
      _log('🔍 Path saved to SharedPreferences: $savedPath');
      if (savedPath != null && savedPath.startsWith('assets/')) {
        _log('⚠️  WARNING: Path has "assets/" prefix! This is the bug!');
      }

      // Verify installation
      final isInstalled = await manager.isModelInstalled(spec);
      if (!isInstalled) {
        throw Exception('Model not marked as installed');
      }

      _log('✅ [LEGACY] Model verification passed');

      setState(() {
        _bundledInferenceModelReady = true;
        _inferenceModelReady = true; // Also set main flag for _testInference()
      });

      _log('🎉 [LEGACY] Bundled inference model ready for testing!');
    } catch (e, stack) {
      _log('❌ Bundled inference failed: $e');
      _log('Stack: $stack');
      rethrow;
    }
  }

  Future<void> _testBundledInferenceLegacy() async {
    await _runTest(
      'Bundled Inference Model (Legacy)',
      _testBundledInferenceLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper
  Future<void> _testBundledInferenceModern_internal() async {
    _log('📦 [MODERN] Testing bundled inference model (zero-copy)...');

    try {
      const resourceName = bundledInferenceResource;

      // Cleanup: Delete model if already installed (for honest testing)
      if (await FlutterEdgeAi.isModelInstalled(resourceName)) {
        _log('🧹 Cleaning up existing model before test...');
        final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
        await manager.deleteModel(_bundledInferenceSpec());
      }

      _log(
        '🔧 Installing via Modern API: FlutterEdgeAi.installModel().fromBundled()',
      );

      // Modern API: Install bundled model
      await FlutterEdgeAi.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromBundled(resourceName).withProgress((progress) {
        _log('📊 Installation progress: $progress%');
      }).install();

      _log('✅ [MODERN] Bundled model installed (zero-copy!)');
      _log('📁 Model ID: $resourceName');

      // Modern API: Verify installation
      final isInstalled = await FlutterEdgeAi.isModelInstalled(resourceName);
      if (!isInstalled) {
        throw Exception('Model not marked as installed');
      }

      _log('✅ [MODERN] Model verification passed');

      setState(() {
        _bundledInferenceModelReady = true;
        _inferenceModelReady = true; // Also set main flag for _testInference()
      });

      _log('🎉 [MODERN] Bundled inference model ready for testing!');
    } catch (e, stack) {
      _log('❌ Bundled inference failed: $e');
      _log('Stack: $stack');
      rethrow;
    }
  }

  Future<void> _testBundledInferenceModern() async {
    await _runTest(
      'Bundled Inference Model (Modern)',
      _testBundledInferenceModern_internal,
    );
  }

  /// Internal version without _runTest wrapper
  Future<void> _testBundledEmbeddingLegacy_internal() async {
    _log('📦 [LEGACY] Testing bundled embedding model (zero-copy)...');

    try {
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

      _log('🔧 Creating BundledSource embedding spec...');

      final spec = _bundledEmbeddingSpec();

      _log('🔍 Created BundledSource spec with ${spec.files.length} files');

      // Cleanup: Delete model if already installed (for honest testing)
      if (await manager.isModelInstalled(spec)) {
        _log('🧹 Cleaning up existing model before test...');
        await manager.deleteModel(spec);
      }

      // Legacy API: Ensure model ready
      await manager.ensureModelReadyFromSpec(spec);

      _log('✅ [LEGACY] Bundled embedding model installed');

      // Verify installation
      final isInstalled = await manager.isModelInstalled(spec);
      if (!isInstalled) {
        throw Exception('Model not marked as installed');
      }

      _log('✅ [LEGACY] Embedding model verified');

      setState(() {
        _bundledEmbeddingModelReady = true;
        _embeddingModelReady = true; // Also set main flag for _testEmbedding()
      });

      _log('🎉 [LEGACY] Bundled embedding model ready for testing!');
    } catch (e, stack) {
      _log('❌ Bundled embedding failed: $e');
      _log('Stack: $stack');
      rethrow;
    }
  }

  Future<void> _testBundledEmbeddingLegacy() async {
    await _runTest(
      'Bundled Embedding Model (Legacy)',
      _testBundledEmbeddingLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper
  Future<void> _testBundledEmbeddingModern_internal() async {
    _log('📦 [MODERN] Testing bundled embedding model (zero-copy)...');

    try {
      const modelResourceName = bundledEmbeddingModelResource;
      const tokenizerResourceName = bundledEmbeddingTokenizerResource;

      // Cleanup: Delete model if already installed (for honest testing)
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      final spec = _bundledEmbeddingSpec();
      if (await manager.isModelInstalled(spec)) {
        _log('🧹 Cleaning up existing model before test...');
        await manager.deleteModel(spec);
      }

      _log('🔧 Installing Model + Tokenizer via Modern API...');

      // Modern API: Install embedding model (model + tokenizer together)
      await FlutterEdgeAi.installEmbedder()
          .modelFromBundled(modelResourceName)
          .tokenizerFromBundled(tokenizerResourceName)
          .install();

      _log('✅ [MODERN] Embedding model + tokenizer installed');

      // Modern API: Verify both files installed
      final modelInstalled = await FlutterEdgeAi.isModelInstalled(
        modelResourceName,
      );
      final tokenizerInstalled = await FlutterEdgeAi.isModelInstalled(
        tokenizerResourceName,
      );

      if (!modelInstalled || !tokenizerInstalled) {
        throw Exception('Model or tokenizer not marked as installed');
      }

      _log('✅ [MODERN] Both files verified');

      setState(() {
        _bundledEmbeddingModelReady = true;
        _embeddingModelReady = true; // Also set main flag for _testEmbedding()
      });

      _log('🎉 [MODERN] Bundled embedding model ready for testing!');
    } catch (e, stack) {
      _log('❌ Bundled embedding failed: $e');
      _log('Stack: $stack');
      rethrow;
    }
  }

  Future<void> _testBundledEmbeddingModern() async {
    await _runTest(
      'Bundled Embedding Model (Modern)',
      _testBundledEmbeddingModern_internal,
    );
  }

  // === NETWORK DOWNLOAD ===

  /// Internal version without _runTest wrapper
  Future<void> _testInferenceDownloadLegacy_internal() async {
    _log('📥 [LEGACY] Downloading Gemma 3 270M IT model...');

    final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
    final token = _huggingFaceTokenController.text.trim();

    if (token.isEmpty) {
      _log('⚠️  WARNING: No HuggingFace token provided!');
      _log('⚠️  Gemma models require:');
      _log(
        '   1. Accept license at https://huggingface.co/litert-community/gemma-3-270m-it',
      );
      _log('   2. Create token at https://huggingface.co/settings/tokens');
      _log('   3. Enter token in Configuration section above');
    } else {
      _log('✅ Using HuggingFace token: ${token.substring(0, 10)}...');
    }

    final spec = _networkInferenceSpec('gemma3-270m-it-q8.task');

    // Cleanup: Delete model if already installed (for honest testing)
    if (await manager.isModelInstalled(spec)) {
      _log('🧹 Cleaning up existing model before test...');
      await manager.deleteModel(spec);
    }

    await for (final progress in manager.downloadModelWithProgress(
      spec,
      token: token.isEmpty ? null : token,
    )) {
      setState(
        () => _progress['inference_download_legacy'] =
            progress.currentFileProgress,
      );
      if (progress.currentFileProgress % 10 == 0) {
        _log('Progress: ${progress.currentFileProgress}%');
      }
    }

    _log('✅ [LEGACY] Inference model downloaded successfully');
    setState(() => _inferenceModelReady = true);
  }

  Future<void> _testInferenceDownloadLegacy() async {
    await _runTest(
      'Download Inference Model (Legacy)',
      _testInferenceDownloadLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper
  Future<void> _testInferenceDownloadModern_internal() async {
    _log('📥 [MODERN] Downloading Gemma 3 270M IT model...');

    final token = _huggingFaceTokenController.text.trim();

    if (token.isEmpty) {
      _log('⚠️  WARNING: No HuggingFace token provided!');
      _log('⚠️  Gemma models require:');
      _log(
        '   1. Accept license at https://huggingface.co/litert-community/gemma-3-270m-it',
      );
      _log('   2. Create token at https://huggingface.co/settings/tokens');
      _log('   3. Enter token in Configuration section above');
    } else {
      _log('✅ Using HuggingFace token: ${token.substring(0, 10)}...');
    }

    // Cleanup: Delete model if already installed (for honest testing)
    const filename = 'gemma3-270m-it-q8.task';
    if (await FlutterEdgeAi.isModelInstalled(filename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      await manager.deleteModel(_networkInferenceSpec(filename));
    }

    // Modern API: Install model from network
    await FlutterEdgeAi.installModel(modelType: legacy.ModelType.gemmaIt)
        .fromNetwork(inferenceModelUrl, token: token.isEmpty ? null : token)
        .withProgress((progress) {
          setState(() => _progress['inference_download_modern'] = progress);
          if (progress % 10 == 0) {
            _log('Progress: $progress%');
          }
        })
        .install();

    _log('✅ [MODERN] Inference model downloaded');
    setState(() => _inferenceModelReady = true);
  }

  Future<void> _testInferenceDownloadModern() async {
    await _runTest(
      'Download Inference Model (Modern)',
      _testInferenceDownloadModern_internal,
    );
  }

  // === ASSET LOADING ===

  /// Internal version without _runTest wrapper
  Future<void> _testInferenceFromAssetsLegacy_internal() async {
    _log('📦 [LEGACY] Loading inference model from assets...');

    final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

    final spec = _assetInferenceSpec('gemma3-270m-it-q8');

    // Cleanup: Delete model if already installed (for honest testing)
    if (await manager.isModelInstalled(spec)) {
      _log('🧹 Cleaning up existing model before test...');
      await manager.deleteModel(spec);
    }

    _log('📦 Copying model file from assets...');
    setState(() => _progress['inference_asset_legacy'] = 0);

    // For assets, use ensureModelReadyFromSpec (routing handles AssetSource)
    await manager.ensureModelReadyFromSpec(spec);

    setState(() => _progress['inference_asset_legacy'] = 100);
    _log('✅ [LEGACY] Inference model loaded from assets');
    setState(() => _inferenceModelReady = true);
  }

  Future<void> _testInferenceFromAssetsLegacy() async {
    await _runTest(
      'Load Inference from Assets (Legacy)',
      _testInferenceFromAssetsLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testInferenceFromAssetsModern_internal() async {
    _log('📦 [MODERN] Loading inference model from assets...');

    // Cleanup: Delete model if already installed (for honest testing)
    final filename = inferenceAssetPath.split('/').last;
    if (await FlutterEdgeAi.isModelInstalled(filename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      await manager.deleteModel(_assetInferenceSpec(filename.split('.').first));
    }

    setState(() => _progress['inference_asset_modern'] = 0);

    // Modern API: Install model from asset
    await FlutterEdgeAi.installModel(
      modelType: legacy.ModelType.gemmaIt,
    ).fromAsset(inferenceAssetPath).withProgress((progress) {
      setState(() => _progress['inference_asset_modern'] = progress);
      _log('📊 Asset copy progress: $progress%');
    }).install();

    setState(() => _progress['inference_asset_modern'] = 100);
    _log('✅ [MODERN] Inference model loaded from assets');
    setState(() => _inferenceModelReady = true);
  }

  Future<void> _testInferenceFromAssetsModern() async {
    await _runTest(
      'Load Inference from Assets (Modern)',
      _testInferenceFromAssetsModern_internal,
    );
  }

  // === CUSTOM FILE PATH ===

  Future<void> _setCustomInferencePathModern() async {
    await _runTest('Set Custom Inference Path (Modern)', () async {
      final path = _customInferencePathController.text.trim();
      if (path.isEmpty) {
        throw Exception('Path is empty');
      }

      _log('📁 [MODERN] Setting custom inference path: $path');

      final file = File(path);
      if (!await file.exists()) {
        throw Exception('File does not exist: $path');
      }

      // Modern API: Install model from file path
      await FlutterEdgeAi.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromFile(path).install();

      _log('✅ [MODERN] Custom inference path set successfully');
      setState(() => _inferenceModelReady = true);
    });
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _runInferenceTest() async {
    if (!_inferenceModelReady) {
      throw Exception('Inference model not ready. Load a model first.');
    }

    _log('🧠 Testing inference model...');
    _log('📋 Using Modern API with active inference model...');

    final startInit = DateTime.now();
    final inferenceModel = await legacy.FlutterEdgeAi.getActiveModel(
      maxTokens: 512,
    );
    final initDuration = DateTime.now().difference(startInit);
    _log('✅ Model initialized in ${initDuration.inMilliseconds}ms');

    final session = await inferenceModel.createSession();
    _log('✅ Session created');
    _log('');

    _log('💬 Prompt: "What is the capital of France?"');
    await session.addQueryChunk(
      const legacy.Message(
        text: 'What is the capital of France?',
        isUser: true,
      ),
    );

    _log('⏳ Generating response...');
    final startGen = DateTime.now();
    final response = await session.getResponse();
    final genDuration = DateTime.now().difference(startGen);

    _log('');
    _log('🤖 Response: $response');
    _log('');
    _log('⏱️  Generation time: ${genDuration.inMilliseconds}ms');
    _log('📊 Response length: ${response.length} chars');
    _log('✅ Inference test successful!');

    await session.close();
    await inferenceModel.close();
  }

  Future<void> _testInference() async {
    await _runTest('Test Inference', _runInferenceTest);
  }

  // === EMBEDDING MODEL TEST METHODS ===

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testEmbeddingDownloadLegacy_internal() async {
    _log('📥 [LEGACY] Downloading embedding model and tokenizer...');

    final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
    final token = _huggingFaceTokenController.text.trim();

    if (token.isEmpty) {
      _log(
        '⚠️  Note: No HuggingFace token provided. Some models may require authentication.',
      );
    }

    // One spec carries both the model and its tokenizer
    final spec = _networkEmbeddingSpec('embeddinggemma-300m');

    // Cleanup: Delete model if already installed (for honest testing)
    if (await manager.isModelInstalled(spec)) {
      _log('🧹 Cleaning up existing model before test...');
      await manager.deleteModel(spec);
    }

    // Download will handle both files
    await for (final progress in manager.downloadModelWithProgress(
      spec,
      token: token.isEmpty ? null : token,
    )) {
      setState(
        () => _progress['embedding_download_legacy'] =
            progress.currentFileProgress,
      );
      if (progress.currentFileProgress % 10 == 0) {
        _log(
          'File ${progress.currentFileIndex + 1}/${progress.totalFiles}: ${progress.currentFileProgress}%',
        );
      }
    }

    _log('✅ [LEGACY] Embedding model and tokenizer downloaded successfully');
    setState(() => _embeddingModelReady = true);
  }

  Future<void> _testEmbeddingDownloadLegacy() async {
    await _runTest(
      'Download Embedding Model (Legacy)',
      _testEmbeddingDownloadLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testEmbeddingDownloadModern_internal() async {
    _log('📥 [MODERN] Downloading embedding model and tokenizer...');

    final token = _huggingFaceTokenController.text.trim();

    if (token.isEmpty) {
      _log(
        '⚠️  Note: No HuggingFace token provided. Some models may require authentication.',
      );
    }

    final authToken = token.isEmpty ? null : token;
    int modelProgress = 0;
    int tokenizerProgress = 0;

    // Cleanup: Delete model if already installed (for honest testing)
    final modelFilename = embeddingModelUrl.split('/').last;
    final tokenizerFilename = embeddingTokenizerUrl.split('/').last;
    if (await FlutterEdgeAi.isModelInstalled(modelFilename) ||
        await FlutterEdgeAi.isModelInstalled(tokenizerFilename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      await manager.deleteModel(
        _networkEmbeddingSpec(modelFilename.split('.').first),
      );
    }

    // Modern API: Download model + tokenizer together
    _log('📥 Downloading model and tokenizer...');
    await FlutterEdgeAi.installEmbedder()
        .modelFromNetwork(embeddingModelUrl, token: authToken)
        .tokenizerFromNetwork(embeddingTokenizerUrl, token: authToken)
        .withModelProgress((progress) {
          modelProgress = progress;
          setState(
            () => _progress['embedding_download_modern'] = modelProgress ~/ 2,
          );
          if (progress % 10 == 0) {
            _log('Model: $progress%');
          }
        })
        .withTokenizerProgress((progress) {
          tokenizerProgress = progress;
          setState(
            () => _progress['embedding_download_modern'] =
                50 + tokenizerProgress ~/ 2,
          );
          if (progress % 10 == 0) {
            _log('Tokenizer: $progress%');
          }
        })
        .install();

    _log('✅ [MODERN] Embedding model and tokenizer downloaded successfully');
    setState(() => _embeddingModelReady = true);
  }

  Future<void> _testEmbeddingDownloadModern() async {
    await _runTest(
      'Download Embedding Model (Modern)',
      _testEmbeddingDownloadModern_internal,
    );
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testEmbeddingFromAssetsLegacy_internal() async {
    _log('📦 [LEGACY] Loading embedding model from assets...');

    final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

    // One spec carries both the model and its tokenizer
    final spec = _assetEmbeddingSpec('embeddinggemma-300M');

    // Cleanup: Delete model if already installed (for honest testing)
    if (await manager.isModelInstalled(spec)) {
      _log('🧹 Cleaning up existing model before test...');
      await manager.deleteModel(spec);
    }

    _log('📦 Copying model and tokenizer files from assets...');
    setState(() => _progress['embedding_asset_legacy'] = 0);

    // For assets, use ensureModelReadyFromSpec (routing handles AssetSource)
    await manager.ensureModelReadyFromSpec(spec);

    setState(() => _progress['embedding_asset_legacy'] = 100);
    _log('✅ [LEGACY] Embedding model and tokenizer loaded from assets');
    setState(() => _embeddingModelReady = true);
  }

  Future<void> _testEmbeddingFromAssetsLegacy() async {
    await _runTest(
      'Load Embedding from Assets (Legacy)',
      _testEmbeddingFromAssetsLegacy_internal,
    );
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _testEmbeddingFromAssetsModern_internal() async {
    _log('📦 [MODERN] Loading embedding model from assets...');

    // Cleanup: Delete model if already installed (for honest testing)
    final modelFilename = embeddingModelAssetPath.split('/').last;
    final tokenizerFilename = embeddingTokenizerAssetPath.split('/').last;
    if (await FlutterEdgeAi.isModelInstalled(modelFilename) ||
        await FlutterEdgeAi.isModelInstalled(tokenizerFilename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;
      await manager.deleteModel(
        _assetEmbeddingSpec(modelFilename.split('.').first),
      );
    }

    setState(() => _progress['embedding_asset_modern'] = 0);

    // Modern API: Install model + tokenizer together from assets
    await FlutterEdgeAi.installEmbedder()
        .modelFromAsset(embeddingModelAssetPath)
        .tokenizerFromAsset(embeddingTokenizerAssetPath)
        .withModelProgress((progress) {
          setState(() => _progress['embedding_asset_modern'] = progress ~/ 2);
          _log('📊 Model copy progress: $progress%');
        })
        .withTokenizerProgress((progress) {
          setState(
            () => _progress['embedding_asset_modern'] = 50 + progress ~/ 2,
          );
          _log('📊 Tokenizer copy progress: $progress%');
        })
        .install();

    setState(() => _progress['embedding_asset_modern'] = 100);
    _log('✅ [MODERN] Embedding model and tokenizer loaded from assets');
    setState(() => _embeddingModelReady = true);
  }

  Future<void> _testEmbeddingFromAssetsModern() async {
    await _runTest(
      'Load Embedding from Assets (Modern)',
      _testEmbeddingFromAssetsModern_internal,
    );
  }

  Future<void> _setCustomEmbeddingPaths() async {
    await _runTest('Set Custom Embedding Paths', () async {
      final modelPath = _customEmbeddingModelPathController.text.trim();
      final tokenizerPath = _customEmbeddingTokenizerPathController.text.trim();

      if (modelPath.isEmpty || tokenizerPath.isEmpty) {
        throw Exception('Both paths are required');
      }

      _log('📁 Setting custom embedding paths...');
      _log('  Model: $modelPath');
      _log('  Tokenizer: $tokenizerPath');

      final modelFile = File(modelPath);
      if (!await modelFile.exists()) {
        throw Exception('Model file does not exist: $modelPath');
      }

      final tokenizerFile = File(tokenizerPath);
      if (!await tokenizerFile.exists()) {
        throw Exception('Tokenizer file does not exist: $tokenizerPath');
      }

      // Note: For embedding models, we'll store paths for later use
      // The actual loading happens in _testEmbedding()
      _log('✅ Custom embedding paths validated');
      setState(() => _embeddingModelReady = true);
    });
  }

  /// Internal version without _runTest wrapper (for use in _runAllTests)
  Future<void> _runEmbeddingTest() async {
    if (!_embeddingModelReady) {
      throw Exception('Embedding model not ready. Load a model first.');
    }

    _log('🧠 Testing embedding model...');
    _log('📋 Using Modern API with active embedding model...');

    // Modern API: Use active embedding model (no paths needed!)
    final embeddingModel = await legacy.FlutterEdgeAiPlugin.instance
        .createEmbeddingModel();

    _log('✅ Embedding model created successfully');
    _log('');

    // Test 1: Simple embedding
    _log('💬 Test 1: Generating embedding for: "Hello, world!"');
    final startTime1 = DateTime.now();
    final embedding1 = await embeddingModel.embed(
      EmbeddingInput.text('Hello, world!'),
      taskType: TaskType.retrievalQuery,
    );
    final duration1 = DateTime.now().difference(startTime1);

    _log('🔢 Embedding dimensions: ${embedding1.length}');
    _log('🔢 First 5 values: ${embedding1.take(5).toList()}');
    _log('⏱️  Generation time: ${duration1.inMilliseconds}ms');
    _log('');

    // Test 2: Different text
    _log('💬 Test 2: Generating embedding for: "Artificial Intelligence"');
    final startTime2 = DateTime.now();
    final embedding2 = await embeddingModel.embed(
      EmbeddingInput.text('Artificial Intelligence'),
      taskType: TaskType.retrievalQuery,
    );
    final duration2 = DateTime.now().difference(startTime2);

    _log('🔢 Embedding dimensions: ${embedding2.length}');
    _log('🔢 First 5 values: ${embedding2.take(5).toList()}');
    _log('⏱️  Generation time: ${duration2.inMilliseconds}ms');
    _log('');

    // Test 3: Calculate similarity
    _log('💬 Test 3: Calculating cosine similarity...');
    final similarity = _cosineSimilarity(embedding1, embedding2);
    _log(
      '📊 Similarity between texts: ${(similarity * 100).toStringAsFixed(2)}%',
    );
    _log('');

    _log('✅ Embedding test successful!');
    _log(
      '📈 Performance: avg ${((duration1.inMilliseconds + duration2.inMilliseconds) / 2).toStringAsFixed(0)}ms per embedding',
    );

    await embeddingModel.close();
  }

  Future<void> _testEmbedding() async {
    await _runTest('Test Embedding', _runEmbeddingTest);
  }

  /// Calculate cosine similarity between two embeddings
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;

    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  Future<void> _runAllTests() async {
    if (_isTesting) {
      _log('⚠️ Test already running');
      return;
    }

    setState(() {
      _isTesting = true;
      _testStatus = 'Running All Tests';
      _currentTestIndex = 0;
      _totalTests = 30; // Download(8) + Assets(8) + Bundled(8) + FileSource(6)
      _runAllTestsProgress = '';
    });

    _log('🚀 Running all integration tests...');
    _log('📋 Total: $_totalTests tests');
    _log('📋 Plan:');
    _log('  1. Cleanup all downloaded models');
    _log('  2. Download tests (with cleanup after each): 8 tests');
    _log('  3. Assets tests (with cleanup after each): 8 tests');
    _log('  4. Bundled tests (NO cleanup): 8 tests');
    _log('  5. FileSource tests (pre-placed files, NO cleanup): 6 tests');
    _log('');

    try {
      final manager = legacy.FlutterEdgeAiPlugin.instance.modelManager;

      // ═══════════════════════════════════════════════════════════════
      // STEP 0: CLEANUP ALL DOWNLOADED MODELS
      // ═══════════════════════════════════════════════════════════════
      _log('═══════════════════════════════════════════');
      _log('🧹 CLEANUP: Deleting all installed models');
      _log('═══════════════════════════════════════════');

      // Cleanup inference models
      final inferenceModels = await manager.getInstalledModels(
        ModelManagementType.inference,
      );
      for (final modelName in inferenceModels) {
        _log('  🗑️  Deleting inference: $modelName');
      }

      // Cleanup embedding models
      final embeddingModels = await manager.getInstalledModels(
        ModelManagementType.embedding,
      );
      for (final modelName in embeddingModels) {
        _log('  🗑️  Deleting embedding: $modelName');
      }

      // Perform cleanup
      await manager.performCleanup();
      _log('✅ Cleanup complete');
      _log('');
      await Future.delayed(const Duration(seconds: 1));

      // ═══════════════════════════════════════════════════════════════
      // SECTION 1: DOWNLOAD TESTS (with cleanup after each)
      // ═══════════════════════════════════════════════════════════════
      _log('═══════════════════════════════════════════');
      _log('📥 SECTION 1: DOWNLOAD TESTS (8 tests)');
      _log('═══════════════════════════════════════════');

      final token = _huggingFaceTokenController.text.trim();
      if (token.isEmpty) {
        _log('⚠️  No HuggingFace token - downloads may fail');
      }

      // TEST 1-2: Inference Legacy (download + run + delete)
      _currentTestIndex++;
      _log(
        '▶️  [$_currentTestIndex/$_totalTests] Download Inference (Legacy) - Install',
      );

      final inferenceSpec = _networkInferenceSpec('gemma3-270m-it-q8');

      _log('  📥 Downloading from network...');
      await for (final progress in manager.downloadModelWithProgress(
        inferenceSpec,
        token: token.isEmpty ? null : token,
      )) {
        setState(
          () => _progress['inference_download_legacy'] =
              progress.currentFileProgress,
        );
        if (progress.currentFileProgress % 10 == 0) {
          _log('  Progress: ${progress.currentFileProgress}%');
        }
      }
      _log('✅ [$_currentTestIndex/$_totalTests] Download complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      _log('  🔧 Creating model...');
      final inferenceModel1 = await legacy.FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
      );
      _log('  ✅ Model created');
      _log('  🔧 Creating session...');
      final session1 = await inferenceModel1.createSession();
      _log('  ✅ Session created');
      _log('  📤 Adding query: "What is the capital of France?"');
      await session1.addQueryChunk(
        const legacy.Message(
          text: 'What is the capital of France?',
          isUser: true,
        ),
      );
      _log('  🤖 Generating response...');
      final response1 = await session1.getResponse();
      _log('  ✅ Got response: length=${response1.length}');
      if (response1.isEmpty) {
        throw Exception('Model returned empty response');
      }
      _log(
        '  📝 Response (${response1.length} chars): ${response1.length > 100 ? "${response1.substring(0, 100)}..." : response1}',
      );
      await session1.close();
      await inferenceModel1.close();
      _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');

      _log('  🗑️  Deleting model...');
      await manager.deleteModel(inferenceSpec);
      await Future.delayed(const Duration(milliseconds: 500));

      // TEST 3-4: Inference Modern (download + run + delete)
      _currentTestIndex++;
      _log(
        '▶️  [$_currentTestIndex/$_totalTests] Download Inference (Modern) - Install',
      );

      _log('  📥 Downloading with Modern API...');
      await FlutterEdgeAi.installModel(modelType: legacy.ModelType.gemmaIt)
          .fromNetwork(inferenceModelUrl, token: token.isEmpty ? null : token)
          .withProgress((progress) {
            setState(() => _progress['inference_download_modern'] = progress);
            if (progress % 10 == 0) {
              _log('  Progress: $progress%');
            }
          })
          .install();
      _log('✅ [$_currentTestIndex/$_totalTests] Download complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      _log('  🔧 Getting active model with Modern API...');
      final inferenceModel2 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
      );
      _log('  ✅ Model ready');
      _log('  🔧 Creating session...');
      final session2 = await inferenceModel2.createSession();
      await session2.addQueryChunk(
        const legacy.Message(
          text: 'What is the capital of France?',
          isUser: true,
        ),
      );
      final response2 = await session2.getResponse();
      if (response2.isEmpty) {
        throw Exception('Model returned empty response');
      }
      _log(
        '  📝 Response (${response2.length} chars): ${response2.length > 100 ? "${response2.substring(0, 100)}..." : response2}',
      );
      await session2.close();
      await inferenceModel2.close();
      _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');

      _log('  🗑️  Deleting model...');
      await manager.deleteModel(inferenceSpec);
      await Future.delayed(const Duration(milliseconds: 500));

      // TEST 5-8: Embedding Legacy/Modern - SKIP ON WEB (not implemented)
      if (kIsWeb) {
        _log('');
        _log(
          '⏭️  [5-8/30] Skipping Network Embedding tests (not implemented on web)',
        );
        _log('💡 Web platform does not yet support embedding models');
        _currentTestIndex += 4;
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        // TEST 5-6: Embedding Legacy (download + run + delete)
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Download Embedding (Legacy) - Install',
        );

        final embeddingSpec = _networkEmbeddingSpec('embeddinggemma-300m');

        _log('  📥 Downloading model and tokenizer...');
        await for (final progress in manager.downloadModelWithProgress(
          embeddingSpec,
          token: token.isEmpty ? null : token,
        )) {
          setState(
            () => _progress['embedding_download_legacy'] =
                progress.currentFileProgress,
          );
          if (progress.currentFileProgress % 10 == 0) {
            _log(
              '  File ${progress.currentFileIndex + 1}/${progress.totalFiles}: ${progress.currentFileProgress}%',
            );
          }
        }
        _log('✅ [$_currentTestIndex/$_totalTests] Download complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        final embeddingModel1 = await legacy.FlutterEdgeAiPlugin.instance
            .createEmbeddingModel();
        final emb1 = await embeddingModel1.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb1.length}');
        _log('  🔢 First 5 values: ${emb1.take(5).toList()}');
        await embeddingModel1.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');

        _log('  🗑️  Deleting model...');
        await manager.deleteModel(embeddingSpec);
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 7-8: Embedding Modern (download + run + delete)
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Download Embedding (Modern) - Install',
        );

        _log('  📥 Downloading with Modern API...');
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(
              embeddingModelUrl,
              token: token.isEmpty ? null : token,
            )
            .tokenizerFromNetwork(
              embeddingTokenizerUrl,
              token: token.isEmpty ? null : token,
            )
            .withModelProgress((progress) {
              if (progress % 10 == 0) {
                _log('  Model: $progress%');
              }
            })
            .withTokenizerProgress((progress) {
              if (progress % 10 == 0) {
                _log('  Tokenizer: $progress%');
              }
            })
            .install();
        _log('✅ [$_currentTestIndex/$_totalTests] Download complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        _log('  🔧 Getting active embedding model with Modern API...');
        final embeddingModel2 = await FlutterEdgeAi.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb2 = await embeddingModel2.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb2.length}');
        _log('  🔢 First 5 values: ${emb2.take(5).toList()}');
        await embeddingModel2.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');

        _log('  🗑️  Deleting model...');
        await manager.deleteModel(embeddingSpec);
      } // End of if (!kIsWeb) for Network Embedding tests

      // ═══════════════════════════════════════════════════════════════
      // SECTION 2: ASSETS TESTS (with cleanup after each)
      // ═══════════════════════════════════════════════════════════════
      _log('');
      _log('═══════════════════════════════════════════');
      _log('📦 SECTION 2: ASSETS TESTS (8 tests)');
      _log('═══════════════════════════════════════════');

      // Check if asset files exist (they may not exist in development)
      bool assetsAvailable = true;
      try {
        await rootBundle.load(inferenceAssetPath);
      } catch (e) {
        assetsAvailable = false;
        _log('⚠️  Asset files not found in assets/models/');
        _log(
          '💡 To run Assets tests, add model files to example/assets/models/',
        );
      }

      if (!assetsAvailable) {
        _log('⏭️  [9-16/30] Skipping all Assets tests (files not available)');
        _log('');
        _currentTestIndex += 8;
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        // TEST 9-10: Inference Assets Legacy
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Assets Inference (Legacy) - Install',
        );

        final assetInferenceSpec = _assetInferenceSpec('gemma3-270m-it-q8');

        _log('  📦 Installing from assets...');
        await manager.ensureModelReadyFromSpec(assetInferenceSpec);
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        final inferenceModel3 = await legacy.FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
        );
        final session3 = await inferenceModel3.createSession();
        await session3.addQueryChunk(
          const legacy.Message(
            text: 'What is the capital of France?',
            isUser: true,
          ),
        );
        final response3 = await session3.getResponse();
        if (response3.isEmpty) {
          throw Exception('Model returned empty response');
        }
        _log(
          '  📝 Response (${response3.length} chars): ${response3.length > 100 ? "${response3.substring(0, 100)}..." : response3}',
        );
        await session3.close();
        await inferenceModel3.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');

        _log('  🗑️  Deleting model...');
        await manager.deleteModel(assetInferenceSpec);
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 11-12: Inference Assets Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Assets Inference (Modern) - Install',
        );

        _log('  📦 Installing with Modern API...');
        await FlutterEdgeAi.installModel(
          modelType: legacy.ModelType.gemmaIt,
        ).fromAsset(inferenceAssetPath).install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        _log('  🔧 Getting active model with Modern API...');
        final inferenceModel4 = await FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
        );
        _log('  ✅ Model ready');
        _log('  🔧 Creating session...');
        final session4 = await inferenceModel4.createSession();
        await session4.addQueryChunk(
          const legacy.Message(
            text: 'What is the capital of France?',
            isUser: true,
          ),
        );
        final response4 = await session4.getResponse();
        if (response4.isEmpty) {
          throw Exception('Model returned empty response');
        }
        _log(
          '  📝 Response (${response4.length} chars): ${response4.length > 100 ? "${response4.substring(0, 100)}..." : response4}',
        );
        await session4.close();
        await inferenceModel4.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');

        _log('  🗑️  Deleting model...');
        await manager.deleteModel(assetInferenceSpec);
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 13-16: Embedding Assets Legacy/Modern - SKIP ON WEB (not implemented)
        if (kIsWeb) {
          _log('');
          _log(
            '⏭️  [13-16/30] Skipping Assets Embedding tests (not implemented on web)',
          );
          _log('💡 Web platform does not yet support embedding models');
          _currentTestIndex += 4;
          await Future.delayed(const Duration(milliseconds: 300));
        } else {
          // TEST 13-14: Embedding Assets Legacy
          _currentTestIndex++;
          _log(
            '▶️  [$_currentTestIndex/$_totalTests] Assets Embedding (Legacy) - Install',
          );

          final assetEmbeddingSpec = _assetEmbeddingSpec('embeddinggemma-300M');

          _log('  📦 Installing model and tokenizer from assets...');
          await manager.ensureModelReadyFromSpec(assetEmbeddingSpec);
          _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
          setState(() => _embeddingModelReady = true);
          await Future.delayed(const Duration(milliseconds: 500));

          _currentTestIndex++;
          _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
          final embeddingModel3 = await legacy.FlutterEdgeAiPlugin.instance
              .createEmbeddingModel();
          final emb3 = await embeddingModel3.embed(
            EmbeddingInput.text('Hello, world!'),
            taskType: TaskType.retrievalQuery,
          );
          _log('  🔢 Dimensions: ${emb3.length}');
          _log('  🔢 First 5 values: ${emb3.take(5).toList()}');
          await embeddingModel3.close();
          _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');

          _log('  🗑️  Deleting model...');
          await manager.deleteModel(assetEmbeddingSpec);
          await Future.delayed(const Duration(milliseconds: 500));

          // TEST 15-16: Embedding Assets Modern
          _currentTestIndex++;
          _log(
            '▶️  [$_currentTestIndex/$_totalTests] Assets Embedding (Modern) - Install',
          );

          _log('  📦 Installing with Modern API...');
          await FlutterEdgeAi.installEmbedder()
              .modelFromAsset(embeddingModelAssetPath)
              .tokenizerFromAsset(embeddingTokenizerAssetPath)
              .install();
          _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
          setState(() => _embeddingModelReady = true);
          await Future.delayed(const Duration(milliseconds: 500));

          _currentTestIndex++;
          _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
          _log('  🔧 Getting active embedding model with Modern API...');
          final embeddingModel4 = await FlutterEdgeAi.getActiveEmbedder();
          _log('  ✅ Model ready');
          _log('  🔧 Generating embedding...');
          final emb4 = await embeddingModel4.embed(
            EmbeddingInput.text('Hello, world!'),
            taskType: TaskType.retrievalQuery,
          );
          _log('  🔢 Dimensions: ${emb4.length}');
          _log('  🔢 First 5 values: ${emb4.take(5).toList()}');
          await embeddingModel4.close();
          _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');

          _log('  🗑️  Deleting model...');
          await manager.deleteModel(assetEmbeddingSpec);
          await Future.delayed(const Duration(milliseconds: 500));
        } // End of if (!kIsWeb) for Assets Embedding tests
      } // End of if (assetsAvailable) for Assets tests

      // ═══════════════════════════════════════════════════════════════
      // SECTION 3: BUNDLED TESTS (NO cleanup - models stay in bundled resources)
      // ═══════════════════════════════════════════════════════════════
      _log('');
      _log('═══════════════════════════════════════════');
      _log('📲 SECTION 3: BUNDLED TESTS (8 tests)');
      _log('═══════════════════════════════════════════');

      // TEST 17-18: Bundled Inference Legacy
      _currentTestIndex++;
      _log(
        '▶️  [$_currentTestIndex/$_totalTests] Bundled Inference (Legacy) - Install',
      );

      final bundledInferenceSpec = _bundledInferenceSpec();

      _log('  📲 Installing from bundled resources...');
      await manager.ensureModelReadyFromSpec(bundledInferenceSpec);
      _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      final inferenceModel5 = await legacy.FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
      );
      final session5 = await inferenceModel5.createSession();
      await session5.addQueryChunk(
        const legacy.Message(
          text: 'What is the capital of France?',
          isUser: true,
        ),
      );
      final response5 = await session5.getResponse();
      if (response5.isEmpty) {
        throw Exception('Model returned empty response');
      }
      _log(
        '  📝 Response (${response5.length} chars): ${response5.length > 100 ? "${response5.substring(0, 100)}..." : response5}',
      );
      await session5.close();
      await inferenceModel5.close();
      _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');
      await Future.delayed(const Duration(milliseconds: 500));

      // TEST 19-20: Bundled Inference Modern
      _currentTestIndex++;
      _log(
        '▶️  [$_currentTestIndex/$_totalTests] Bundled Inference (Modern) - Install',
      );

      _log('  📲 Installing with Modern API...');
      await FlutterEdgeAi.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromBundled('gemma3-270m-it-q8.task').install();
      _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      _log('  🔧 Getting active model with Modern API...');
      final inferenceModel6 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
      );
      _log('  ✅ Model ready');
      _log('  🔧 Creating session...');
      final session6 = await inferenceModel6.createSession();
      await session6.addQueryChunk(
        const legacy.Message(
          text: 'What is the capital of France?',
          isUser: true,
        ),
      );
      final response6 = await session6.getResponse();
      if (response6.isEmpty) {
        throw Exception('Model returned empty response');
      }
      _log(
        '  📝 Response (${response6.length} chars): ${response6.length > 100 ? "${response6.substring(0, 100)}..." : response6}',
      );
      await session6.close();
      await inferenceModel6.close();
      _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');
      await Future.delayed(const Duration(milliseconds: 500));

      // TEST 21-24: Bundled Embedding Legacy/Modern - SKIP ON WEB (not implemented)
      if (kIsWeb) {
        _log('');
        _log(
          '⏭️  [21-24/30] Skipping Bundled Embedding tests (not implemented on web)',
        );
        _log('💡 Web platform does not yet support embedding models');
        _currentTestIndex += 4;
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        // TEST 21-22: Bundled Embedding Legacy
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Bundled Embedding (Legacy) - Install',
        );

        final bundledEmbeddingSpec = _bundledEmbeddingSpec();

        _log('  📲 Installing from bundled resources...');
        await manager.ensureModelReadyFromSpec(bundledEmbeddingSpec);
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        final embeddingModel5 = await legacy.FlutterEdgeAiPlugin.instance
            .createEmbeddingModel();
        final emb5 = await embeddingModel5.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb5.length}');
        _log('  🔢 First 5 values: ${emb5.take(5).toList()}');
        await embeddingModel5.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 23-24: Bundled Embedding Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Bundled Embedding (Modern) - Install',
        );

        _log('  📲 Installing with Modern API...');
        await FlutterEdgeAi.installEmbedder()
            .modelFromBundled(
              'embeddinggemma-300M_seq1024_mixed-precision.tflite',
            )
            .tokenizerFromBundled('sentencepiece.model')
            .install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        _log('  🔧 Getting active embedding model with Modern API...');
        final embeddingModel6 = await FlutterEdgeAi.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb6 = await embeddingModel6.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb6.length}');
        _log('  🔢 First 5 values: ${emb6.take(5).toList()}');
        await embeddingModel6.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');
      } // End of if (!kIsWeb) for Bundled Embedding tests

      // ═══════════════════════════════════════════════════════════════
      // SECTION 4: FILE SOURCE TESTS (using pre-placed model files)
      // ═══════════════════════════════════════════════════════════════
      _log('');
      _log('═══════════════════════════════════════════');
      _log('📁 SECTION 4: FILE SOURCE TESTS (6 tests)');
      _log('═══════════════════════════════════════════');

      // TEST 25-30: All FileSource tests - SKIP ON WEB (local paths not supported)
      if (kIsWeb) {
        _log(
          '⏭️  [25-30/30] Skipping all FileSource tests (local file paths not available)',
        );
        _log(
          '💡 Web: FileSource works with URLs/assets, but these tests use local paths',
        );
        _currentTestIndex += 6;
      } else {
        // TEST 25-26: FileSource Inference Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Inference (Modern) - Install',
        );

        final inferenceFilePath = _customInferencePathController.text.trim();
        if (inferenceFilePath.isEmpty) {
          throw Exception('Inference file path not configured in controller');
        }

        _log('  📁 Using file path: $inferenceFilePath');
        final inferenceFile = File(inferenceFilePath);
        if (!await inferenceFile.exists()) {
          throw Exception('Inference file does not exist: $inferenceFilePath');
        }

        _log('  📁 [MODERN] Installing from file...');
        await FlutterEdgeAi.installModel(
          modelType: legacy.ModelType.gemmaIt,
        ).fromFile(inferenceFilePath).install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        _log('  🔧 Getting active model with Modern API...');
        final inferenceModel8 = await FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
        );
        _log('  ✅ Model ready');
        _log('  🔧 Creating session...');
        final session8 = await inferenceModel8.createSession();
        await session8.addQueryChunk(
          const legacy.Message(
            text: 'What is the capital of France?',
            isUser: true,
          ),
        );
        final response8 = await session8.getResponse();
        if (response8.isEmpty) {
          throw Exception('Model returned empty response');
        }
        _log(
          '  📝 Response (${response8.length} chars): ${response8.length > 100 ? "${response8.substring(0, 100)}..." : response8}',
        );
        await session8.close();
        await inferenceModel8.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 27-28: FileSource Embedding Legacy
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Embedding (Legacy) - Install',
        );

        final embeddingModelPath = _customEmbeddingModelPathController.text
            .trim();
        final embeddingTokenizerPath = _customEmbeddingTokenizerPathController
            .text
            .trim();

        if (embeddingModelPath.isEmpty || embeddingTokenizerPath.isEmpty) {
          throw Exception('Embedding paths not configured in controllers');
        }

        _log('  📁 Model: $embeddingModelPath');
        _log('  📁 Tokenizer: $embeddingTokenizerPath');

        final embeddingModelFile = File(embeddingModelPath);
        if (!await embeddingModelFile.exists()) {
          throw Exception(
            'Embedding model file does not exist: $embeddingModelPath',
          );
        }

        final embeddingTokenizerFile = File(embeddingTokenizerPath);
        if (!await embeddingTokenizerFile.exists()) {
          throw Exception(
            'Embedding tokenizer file does not exist: $embeddingTokenizerPath',
          );
        }

        // createEmbeddingModel no longer takes explicit paths (2.3.0): the
        // platform interface builds the ACTIVE embedder, so install the files
        // first — the same install the Modern test below repeats.
        _log(
          '  📁 [LEGACY] Installing from files for the platform interface...',
        );
        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(embeddingModelPath)
            .tokenizerFromFile(embeddingTokenizerPath)
            .install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        final embeddingModel7 = await legacy.FlutterEdgeAiPlugin.instance
            .createEmbeddingModel();
        final emb7 = await embeddingModel7.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb7.length}');
        _log('  🔢 First 5 values: ${emb7.take(5).toList()}');
        await embeddingModel7.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 29-30: FileSource Embedding Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Embedding (Modern) - Install',
        );

        _log('  📁 [MODERN] Installing from files...');
        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(embeddingModelPath)
            .tokenizerFromFile(embeddingTokenizerPath)
            .install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        _log('  🔧 Getting active embedding model with Modern API...');
        final embeddingModel8 = await FlutterEdgeAi.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb8 = await embeddingModel8.embed(
          EmbeddingInput.text('Hello, world!'),
          taskType: TaskType.retrievalQuery,
        );
        _log('  🔢 Dimensions: ${emb8.length}');
        _log('  🔢 First 5 values: ${emb8.take(5).toList()}');
        await embeddingModel8.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');
      } // End of if (!kIsWeb) for FileSource tests

      // ═══════════════════════════════════════════════════════════════
      // COMPLETE
      // ═══════════════════════════════════════════════════════════════
      _log('');
      _log('═══════════════════════════════════════════');
      _log('🎉 ALL TESTS COMPLETED SUCCESSFULLY!');
      _log('═══════════════════════════════════════════');
      _log('📊 Summary: $_totalTests/$_totalTests tests passed');
      _log('');
      _log('✅ Section 1 - Download: 4 installs, 4 runs, 4 cleanups');
      _log('✅ Section 2 - Assets: 4 installs, 4 runs, 4 cleanups');
      _log('✅ Section 3 - Bundled: 4 installs, 4 runs (inference + embedding)');
      _log(
        '✅ Section 4 - FileSource: 3 installs, 3 runs (inference + embedding)',
      );
      _log('🎯 All source types and APIs verified!');
      _log('');

      setState(() {
        _testStatus = 'All tests passed! ✅';
        _runAllTestsProgress = 'Complete: $_totalTests/$_totalTests';
      });
    } catch (e, stackTrace) {
      _log('');
      _log('❌ TEST SUITE FAILED');
      _log('Failed at test $_currentTestIndex/$_totalTests');
      _log('Error: $e');
      _log('Stack trace: $stackTrace');

      setState(() {
        _testStatus = 'Tests failed at $_currentTestIndex/$_totalTests ❌';
        _runAllTestsProgress =
            'Failed: $_currentTestIndex/$_totalTests completed';
      });
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  // Helper methods for UI
  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: ExpansionTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        initiallyExpanded: false,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(spacing: 8, runSpacing: 8, children: children),
          ),
        ],
      ),
    );
  }

  Widget _buildButton(String text, VoidCallback? onPressed, [Color? color]) {
    return ElevatedButton(
      onPressed: _isTesting ? null : onPressed,
      style: color != null
          ? ElevatedButton.styleFrom(backgroundColor: color)
          : null,
      child: Text(text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Integration Tests')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Test status
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _testStatus,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _testStatus == 'Test is running'
                      ? Colors.blue
                      : _testStatus == 'Passed'
                      ? Colors.green
                      : _testStatus == 'Failed'
                      ? Colors.red
                      : Colors.grey,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            // Run All Tests progress indicator
            if (_runAllTestsProgress.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  border: Border.all(color: Colors.blue, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      _runAllTestsProgress,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (_totalTests > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _currentTestIndex / _totalTests,
                        backgroundColor: Colors.grey.shade300,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.blue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(_currentTestIndex / _totalTests * 100).toStringAsFixed(0)}% Complete',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            // === SECTION 0: Configuration ===
            _buildSection(
              title: 'Configuration',
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'HuggingFace Token:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _huggingFaceTokenController,
                        decoration: const InputDecoration(
                          hintText:
                              'hf_... (paste your HuggingFace token here)',
                          border: OutlineInputBorder(),
                          isDense: true,
                          helperText:
                              'IMPORTANT: Use Classic token OR fine-grained with "Access public gated repositories" enabled',
                          helperMaxLines: 3,
                        ),
                        // Don't obscure so user can verify they pasted correctly
                        obscureText: false,
                        autocorrect: false,
                        enableSuggestions: false,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          border: Border.all(color: Colors.orange),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '⚠️ Token Requirements:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '1. Go to: https://huggingface.co/settings/tokens',
                            ),
                            Text('2. Create CLASSIC token (recommended)'),
                            Text('   OR fine-grained token with:'),
                            Text(
                              '   - "Access public gated repositories" enabled',
                            ),
                            Text('3. Accept model license at:'),
                            Text(
                              '   https://huggingface.co/litert-community/gemma-3-270m-it',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // === SECTION 0.5: Run All Tests ===
            _buildSection(
              title: 'Automated Testing',
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    border: Border.all(color: Colors.green, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🚀 Automated Test Suite',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text('Runs all tests from:'),
                      Text('  • Download (4 install + 4 run = 8)'),
                      Text('  • Assets (4 install + 4 run = 8)'),
                      Text('  • Bundled (4 install + 4 run = 8)'),
                      Text('  • FileSource (3 install + 3 run = 6)'),
                      SizedBox(height: 4),
                      Text(
                        'Total: 30 tests',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Each model is tested after installation!',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _buildButton(
                  '▶️  RUN ALL TESTS (30 tests)',
                  _isTesting ? null : _runAllTests,
                  _isTesting ? Colors.grey : Colors.green,
                ),
              ],
            ),

            // === SECTION 2: Storage Management ===
            _buildSection(
              title: 'Storage Management',
              children: [
                _buildButton(
                  'Show Orphaned Files',
                  _showOrphanedFiles,
                  Colors.blue,
                ),
                _buildButton(
                  'Cleanup Orphaned Files',
                  _cleanupOrphanedFiles,
                  Colors.red,
                ),
                _buildButton(
                  'Show Storage Stats',
                  _showStorageStats,
                  Colors.blue,
                ),
              ],
            ),

            // === SECTION 2.5: Bundled Models (Native Assets) ===
            _buildSection(
              title: 'Bundled Models (Production/Native Assets)',
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    border: Border.all(color: Colors.purple),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '📦 Native Assets Testing',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Android: Place models in android/src/main/assets/models/',
                      ),
                      Text('iOS: Add models to Xcode Bundle Resources'),
                      Text(
                        '✅ Zero-copy - models used directly without copying!',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Inference:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testBundledInferenceLegacy,
                        Colors.purple[300]!,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testBundledInferenceModern,
                        Colors.purple,
                      ),
                    ),
                  ],
                ),
                _buildButton(
                  'Run Bundled Inference',
                  _bundledInferenceModelReady ? _testInference : null,
                  _bundledInferenceModelReady ? Colors.green : Colors.grey,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Embedding:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testBundledEmbeddingLegacy,
                        Colors.purple[300]!,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testBundledEmbeddingModern,
                        Colors.purple,
                      ),
                    ),
                  ],
                ),
                _buildButton(
                  'Run Bundled Embedding',
                  _bundledEmbeddingModelReady ? _testEmbedding : null,
                  _bundledEmbeddingModelReady ? Colors.green : Colors.grey,
                ),
              ],
            ),

            // === SECTION 3: Inference Model Tests ===
            _buildSection(
              title: 'Inference Model Tests',
              children: [
                const Text(
                  'Network Download:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testInferenceDownloadLegacy,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testInferenceDownloadModern,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Asset Loading:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testInferenceFromAssetsLegacy,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testInferenceFromAssetsModern,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Custom File Path:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _customInferencePathController,
                        decoration: const InputDecoration(
                          hintText: '/path/to/model.task',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildButton(
                        'Install from File',
                        _setCustomInferencePathModern,
                      ),
                    ],
                  ),
                ),
                _buildButton(
                  'Test Inference',
                  _inferenceModelReady ? _testInference : null,
                  _inferenceModelReady ? Colors.green : Colors.grey,
                ),
              ],
            ),

            // === SECTION 4: Embedding Model Tests ===
            _buildSection(
              title: 'Embedding Model Tests',
              children: [
                const Text(
                  'Network Download:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testEmbeddingDownloadLegacy,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testEmbeddingDownloadModern,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Asset Loading:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        'Legacy',
                        _testEmbeddingFromAssetsLegacy,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildButton(
                        'Modern',
                        _testEmbeddingFromAssetsModern,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Custom File Paths:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _customEmbeddingModelPathController,
                        decoration: const InputDecoration(
                          hintText: 'Model: /path/to/embedding.bin',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _customEmbeddingTokenizerPathController,
                        decoration: const InputDecoration(
                          hintText: 'Tokenizer: /path/to/tokenizer.json',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildButton(
                        'Set Custom Paths (Legacy only)',
                        _setCustomEmbeddingPaths,
                      ),
                    ],
                  ),
                ),
                _buildButton(
                  'Test Embedding',
                  _embeddingModelReady ? _testEmbedding : null,
                  _embeddingModelReady ? Colors.green : Colors.grey,
                ),
              ],
            ),

            // === SECTION 5: VectorStore Tests ===
            _buildSection(
              title: 'RAG Demo',
              children: [
                _buildButton('Open RAG Demo', () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const RagDemoScreen(),
                    ),
                  );
                }, Colors.deepPurple),
              ],
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
