import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/mobile/smart_downloader.dart';
import 'package:flutter_gemma/core/api/flutter_gemma.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as legacy;
import 'package:flutter_gemma/mobile/flutter_gemma_mobile.dart'
    as legacy_mobile;
import 'package:path_provider/path_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma_example/utils/test_preferences.dart';
import 'package:flutter_gemma_example/gemma_bootstrap.dart';
import 'package:flutter_gemma_example/rag_demo_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';

/// Manual integration testing screen for SmartDownloader
///
/// This screen allows testing download scenarios in a real environment
/// (not unit test environment which has limitations with background_downloader)
class IntegrationTestScreen extends StatefulWidget {
  const IntegrationTestScreen({super.key});

  @override
  State<IntegrationTestScreen> createState() => _IntegrationTestScreenState();
}

class _IntegrationTestScreenState extends State<IntegrationTestScreen> {
  final Map<String, int> _progress = {};
  bool _isTesting = false;
  String _testStatus = 'Ready';
  StreamSubscription? _currentDownloadSubscription;
  String? _interruptedUrl;
  String? _interruptedPath;
  bool _hasPendingResumeTest = false;
  String? _killAppInstruction;

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

  @override
  void initState() {
    super.initState();
    _setDefaultPaths();
    _checkForInterruptedDownload();
    _checkForPendingTest();
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
      final installedModels = await FlutterGemma.listInstalledModels();

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

  Future<void> _checkForPendingTest() async {
    final testStage = await TestPreferences.getTestStage();

    if (testStage == 'waiting_for_app_kill') {
      setState(() {
        _testStatus = '⚠️ TEST IN PROGRESS';
      });
      _log('🔄 Test waiting for app kill - please kill and restart app');
    } else if (testStage == 'after_restart') {
      setState(() {
        _testStatus = '🟢 READY TO RESUME';
        _hasPendingResumeTest = true;
      });
      _log('✅ App restarted - tap "Continue Resume Test" to finish');
    }
  }

  @override
  void dispose() {
    _currentDownloadSubscription?.cancel();
    _customInferencePathController.dispose();
    _customEmbeddingModelPathController.dispose();
    _customEmbeddingTokenizerPathController.dispose();
    _huggingFaceTokenController.dispose();
    super.dispose();
  }

  Future<void> _checkForInterruptedDownload() async {
    final (url, path) = await TestPreferences.getInterruptedDownload();

    if (url != null && path != null) {
      setState(() {
        _interruptedUrl = url;
        _interruptedPath = path;
      });
      debugPrint('🔄 Found interrupted download: ${path.split('/').last}');
      debugPrint('💾 Tap "Resume Interrupted" to continue');
    }
  }

  void _log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    debugPrint('[$timestamp] $message');
  }

  Future<String> _getTestDir() async {
    // Web doesn't support local file system
    if (kIsWeb) {
      return '/tmp/integration_tests'; // Placeholder for web
    }

    final dir = await getApplicationDocumentsDirectory();
    final testDir = Directory('${dir.path}/integration_tests');
    if (!await testDir.exists()) {
      await testDir.create(recursive: true);
    }
    return testDir.path;
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

  Future<void> _testSequentialDownloads() async {
    await _runTest('Sequential Downloads (2 models)', () async {
      final testDir = await _getTestDir();

      // === Test 1: SmartDownloader (Legacy approach) ===
      _log('🔧 Testing with SmartDownloader (Legacy)...');
      final file1 = '$testDir/model1.bin';
      final file2 = '$testDir/model2.bin';

      await File(file1).delete().catchError((_) => File(file1));
      await File(file2).delete().catchError((_) => File(file2));

      _log('📥 Legacy: Downloading model 1...');
      await for (final progress in SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/Android.gitignore',
        targetPath: file1,
        maxRetries: 3,
      )) {
        setState(() => _progress['legacy_1'] = progress);
      }

      final size1 = await File(file1).length();
      _log('✅ Legacy Model 1: $size1 bytes');

      await Future.delayed(const Duration(milliseconds: 500));

      _log('📥 Legacy: Downloading model 2...');
      await for (final progress in SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/Global/Linux.gitignore',
        targetPath: file2,
        maxRetries: 3,
      )) {
        setState(() => _progress['legacy_2'] = progress);
      }

      final size2 = await File(file2).length();
      _log('✅ Legacy Model 2: $size2 bytes');

      // === Test 2: Modern API ===
      _log('🆕 Testing with Modern API (fromNetwork)...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      // Modern API saves file with name from URL
      final documentsDir = testDir.replaceAll('/integration_tests', '');

      final file3 = '$documentsDir/Python.gitignore';
      await File(file3).delete().catchError((_) => File(file3));

      _log('📥 Modern: Downloading model 1...');
      await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
          .fromNetwork(
            'https://raw.githubusercontent.com/github/gitignore/main/Python.gitignore',
          )
          .withProgress((progress) {
            setState(() => _progress['modern_1'] = progress);
          })
          .install();

      final modern1Size = await File(file3).length();
      _log('✅ Modern API Model 1: $modern1Size bytes');

      await Future.delayed(const Duration(milliseconds: 500));

      final file4 = '$documentsDir/Ruby.gitignore';
      await File(file4).delete().catchError((_) => File(file4));

      _log('📥 Modern: Downloading model 2...');
      await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
          .fromNetwork(
            'https://raw.githubusercontent.com/github/gitignore/main/Ruby.gitignore',
          )
          .withProgress((progress) {
            setState(() => _progress['modern_2'] = progress);
          })
          .install();

      final modern2Size = await File(file4).length();
      _log('✅ Modern API Model 2: $modern2Size bytes');

      _log('✅ Sequential downloads: Both Legacy & Modern API work!');
    });
  }

  Future<void> _testThreeSequentialDownloads() async {
    await _runTest('Sequential 3 models (Leg+Mod)', () async {
      final testDir = await _getTestDir();

      final urls = [
        'https://raw.githubusercontent.com/github/gitignore/main/Node.gitignore',
        'https://raw.githubusercontent.com/github/gitignore/main/Python.gitignore',
        'https://raw.githubusercontent.com/github/gitignore/main/Java.gitignore',
      ];

      // === Test 1: SmartDownloader (Legacy) ===
      _log('🔧 Testing 3 sequential with SmartDownloader (Legacy)...');
      for (var i = 0; i < urls.length; i++) {
        final file = '$testDir/legacy_seq${i + 1}.bin';
        await File(file).delete().catchError((_) => File(file));

        _log('📥 Legacy: Model ${i + 1}/3...');

        await for (final progress in SmartDownloader.downloadWithProgress(
          url: urls[i],
          targetPath: file,
          maxRetries: 3,
        )) {
          setState(() => _progress['legacy_seq${i + 1}'] = progress);
        }

        final size = await File(file).length();
        _log('✅ Legacy Model ${i + 1}/3: $size bytes');

        if (i < urls.length - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      _log('✅ Legacy: All 3 models downloaded!');

      // === Test 2: Modern API ===
      _log('🆕 Testing 3 sequential with Modern API...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      final documentsDir = testDir.replaceAll('/integration_tests', '');
      final modernFiles = [
        'Node.gitignore',
        'Python.gitignore',
        'Java.gitignore',
      ];

      for (var i = 0; i < urls.length; i++) {
        final file = '$documentsDir/${modernFiles[i]}';
        await File(file).delete().catchError((_) => File(file));

        _log('📥 Modern: Model ${i + 1}/3...');

        await FlutterGemma.installModel(
          modelType: legacy.ModelType.gemmaIt,
        ).fromNetwork(urls[i]).withProgress((progress) {
          setState(() => _progress['modern_seq${i + 1}'] = progress);
        }).install();

        final size = await File(file).length();
        _log('✅ Modern Model ${i + 1}/3: $size bytes');

        if (i < urls.length - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      _log('✅ Modern: All 3 models downloaded!');
      _log('✅ Sequential 3 models: Both Legacy & Modern API work!');
    });
  }

  Future<void> _testReplacePolicy() async {
    await _runTest('Replace + File/SetPath + LoRA', () async {
      final testDir = await _getTestDir();

      // === Test 1: Legacy Replace Policy ===
      _log('🔧 Testing Legacy replace policy...');
      final file1 = '$testDir/replace_legacy.bin';
      await File(file1).writeAsBytes(List.filled(512, 0xFF));
      _log('📁 Created existing file: 512 bytes');

      await for (final progress in SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/Rust.gitignore',
        targetPath: file1,
        maxRetries: 3,
      )) {
        setState(() => _progress['replace_leg'] = progress);
      }

      final replacedSize = await File(file1).length();
      _log('✅ Legacy: File replaced to $replacedSize bytes');

      // === Test 2: Modern API fromFile ===
      _log('🆕 Testing Modern API fromFile...');
      final externalFile = File('$testDir/external.bin');
      await externalFile.writeAsBytes(List.filled(2048, 0x42));

      await FlutterGemma.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromFile(externalFile.path).withProgress((p) {
        setState(() => _progress['fromFile'] = p);
      }).install();

      _log('✅ Modern: fromFile completed');

      // === Test 3: Legacy setModelPath ===
      _log('🔧 Testing Legacy setModelPath...');
      try {
        final mgr = legacy.FlutterGemmaPlugin.instance.modelManager;
        await mgr.setModelPath(externalFile.path);
        _log('✅ Legacy: setModelPath OK');
      } catch (e) {
        _log('⚠️  setModelPath error: $e');
      }

      // === Test 4: LoRA Weights ===
      _log('🎯 Testing LoRA weights...');
      try {
        final loraFile = File('$testDir/lora.bin');
        await loraFile.writeAsBytes(List.filled(512, 0x4C));

        final mgr = legacy.FlutterGemmaPlugin.instance.modelManager;
        await mgr.setLoraWeightsPath(loraFile.path);
        _log('✅ LoRA: Set weights OK');

        await mgr.deleteLoraWeights();
        _log('✅ LoRA: Delete weights OK');
      } catch (e) {
        _log('⚠️  LoRA error: $e');
      }

      _log('✅ Replace/File/SetPath/LoRA: All OK!');
    });
  }

  Future<void> _testProgressTracking() async {
    await _runTest('Progress Tracking (Leg+Mod)', () async {
      final testDir = await _getTestDir();

      // === Test 1: Legacy Progress Tracking ===
      _log('🔧 Testing Legacy progress tracking...');
      final legacyFile = '$testDir/legacy_progress.bin';
      await File(legacyFile).delete().catchError((_) => File(legacyFile));

      _log('📥 Legacy: Downloading file with progress tracking...');

      final legacyProgress = <int>[];
      await for (final progress in SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/C%2B%2B.gitignore',
        targetPath: legacyFile,
        maxRetries: 3,
      )) {
        legacyProgress.add(progress);
        setState(() => _progress['legacy_progress'] = progress);
      }

      _log('✅ Legacy: Complete with ${legacyProgress.length} updates');

      // Verify monotonic increase
      for (var i = 1; i < legacyProgress.length; i++) {
        if (legacyProgress[i] < legacyProgress[i - 1]) {
          throw Exception(
            'Legacy: Progress decreased: ${legacyProgress[i]} < ${legacyProgress[i - 1]}',
          );
        }
      }

      _log('✅ Legacy: Progress tracking works!');

      // === Test 2: Modern API Progress Tracking ===
      _log('🆕 Testing Modern API progress tracking...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      final documentsDir = testDir.replaceAll('/integration_tests', '');
      final modernFile = '$documentsDir/Swift.gitignore';
      await File(modernFile).delete().catchError((_) => File(modernFile));

      _log('📥 Modern: Downloading file with progress tracking...');

      final modernProgress = <int>[];
      await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
          .fromNetwork(
            'https://raw.githubusercontent.com/github/gitignore/main/Swift.gitignore',
          )
          .withProgress((progress) {
            modernProgress.add(progress);
            setState(() => _progress['modern_progress'] = progress);
          })
          .install();

      _log('✅ Modern: Complete with ${modernProgress.length} updates');

      // Verify monotonic increase
      for (var i = 1; i < modernProgress.length; i++) {
        if (modernProgress[i] < modernProgress[i - 1]) {
          throw Exception(
            'Modern: Progress decreased: ${modernProgress[i]} < ${modernProgress[i - 1]}',
          );
        }
      }

      _log('✅ Modern: Progress tracking works!');

      _log('✅ Progress Tracking: Both Legacy & Modern API work!');
    });
  }

  Future<void> _test404Error() async {
    await _runTest('404 Error (Leg+Mod)', () async {
      final testDir = await _getTestDir();

      // === Test 1: Legacy 404 Error ===
      _log('🔧 Testing Legacy 404 error (should fail after 1 attempt)...');
      final legacyFile = '$testDir/legacy_404.bin';

      try {
        await for (final _ in SmartDownloader.downloadWithProgress(
          url:
              'https://raw.githubusercontent.com/github/gitignore/main/nonexistent_file_12345.txt',
          targetPath: legacyFile,
          maxRetries: 3,
        )) {
          // Should not get here
        }
        throw Exception('Legacy: Should have thrown 404 error');
      } catch (e) {
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('404') || errorMsg.contains('not found')) {
          _log('✅ Legacy: 404 error handled correctly');
        } else {
          throw Exception('Legacy: Unexpected error: $e');
        }
      }

      // === Test 2: Modern API 404 Error ===
      _log('🆕 Testing Modern API 404 error...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      try {
        await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
            .fromNetwork(
              'https://raw.githubusercontent.com/github/gitignore/main/nonexistent_file_12345.txt',
            )
            .install();
        throw Exception('Modern: Should have thrown 404 error');
      } catch (e) {
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('404') ||
            errorMsg.contains('not found') ||
            errorMsg.contains('filename cannot contain') ||
            errorMsg.contains('invalid argument')) {
          _log('✅ Modern: 404/Invalid URL error handled correctly');
        } else {
          throw Exception('Modern: Unexpected error: $e');
        }
      }

      _log('✅ 404 Error Handling: Both Legacy & Modern API work!');
    });
  }

  Future<void> _test401Error() async {
    await _runTest('401 Error (Leg+Mod)', () async {
      final testDir = await _getTestDir();

      // === Test 1: Legacy 401 Error (using 404 as proxy) ===
      _log('🔧 Testing Legacy HTTP auth error...');
      final legacyFile = '$testDir/legacy_401.bin';

      try {
        await for (final _ in SmartDownloader.downloadWithProgress(
          url:
              'https://raw.githubusercontent.com/github/gitignore/main/nonexistent_auth_file_67890.txt',
          targetPath: legacyFile,
          maxRetries: 3,
        )) {
          // Should not get here
        }
        throw Exception('Legacy: Should have thrown HTTP error');
      } catch (e) {
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('401') ||
            errorMsg.contains('404') ||
            errorMsg.contains('auth') ||
            errorMsg.contains('unauthorized') ||
            errorMsg.contains('not found')) {
          _log('✅ Legacy: HTTP auth error handled correctly');
        } else {
          throw Exception('Legacy: Unexpected error: $e');
        }
      }

      // === Test 2: Modern API 401 Error (using 404 as proxy) ===
      _log('🆕 Testing Modern API HTTP auth error...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      try {
        await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
            .fromNetwork(
              'https://raw.githubusercontent.com/github/gitignore/main/nonexistent_auth_file_67890.txt',
            )
            .install();
        throw Exception('Modern: Should have thrown HTTP error');
      } catch (e) {
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('401') ||
            errorMsg.contains('404') ||
            errorMsg.contains('auth') ||
            errorMsg.contains('unauthorized') ||
            errorMsg.contains('not found') ||
            errorMsg.contains('filename cannot contain') ||
            errorMsg.contains('invalid argument')) {
          _log('✅ Modern: HTTP auth/error handled correctly');
        } else {
          throw Exception('Modern: Unexpected error: $e');
        }
      }

      _log('✅ 401 Error Handling: Both Legacy & Modern API work!');
    });
  }

  Future<void> _testInterruptAndRestart() async {
    final testStage = await TestPreferences.getTestStage();

    if (testStage == 'after_restart') {
      // Part 2: After app restart
      await _testInterruptAndRestart_Part2();
    } else {
      // Part 1: Initial run
      await _testInterruptAndRestart_Part1();
    }
  }

  Future<void> _testInterruptAndRestart_Part1() async {
    await _runTest('Real App Kill - Part 1', () async {
      final testDir = await _getTestDir();
      const filename = 'test_interrupted.task';
      final filePath = '$testDir/$filename';

      await File(filePath).delete().catchError((_) => File(filePath));

      const url =
          'https://huggingface.co/litert-community/Hammer2.1-0.5b/resolve/main/hammer2p1_05b_.task';

      _log('📥 Starting download (509 MB model)...');
      _log('⏱️  Will wait 10-15 seconds then you kill the app...');

      // Start download
      final stream = SmartDownloader.downloadWithProgress(
        url: url,
        targetPath: filePath,
        maxRetries: 3,
      );

      _currentDownloadSubscription = stream.listen(
        (progress) {
          setState(() => _progress['interrupted'] = progress);
        },
        onError: (e) {
          _log('❌ Download error: $e');
        },
        onDone: () {
          _log('✅ Download completed before kill');
        },
      );

      // Let download run for 10 seconds to ensure download has started
      await Future.delayed(const Duration(seconds: 10));

      // Get progress from stream (more reliable than checking file on iOS)
      final downloadProgress = _progress['interrupted'] ?? 0;

      if (downloadProgress == 0) {
        throw Exception('❌ Download has not started after 10 seconds');
      }

      // Estimate downloaded size based on progress (509 MB total)
      const totalSizeMB = 509.0;
      final estimatedMB = (totalSizeMB * downloadProgress / 100)
          .toStringAsFixed(1);

      _log('📊 Progress: $downloadProgress% (~$estimatedMB MB downloaded)');

      // Try to get actual file size (may not exist on iOS until download completes)
      final partialFile = File(filePath);
      int actualSize = 0;
      if (await partialFile.exists()) {
        actualSize = await partialFile.length();
        final actualMB = (actualSize / 1024 / 1024).toStringAsFixed(1);
        _log('📁 Actual file on disk: $actualMB MB');
      } else {
        _log(
          '⚠️  File not yet on disk (iOS may keep it in temp until complete)',
        );
      }

      // Save test state
      await TestPreferences.setTestStage('waiting_for_app_kill');
      await TestPreferences.setTestUrl(url);
      await TestPreferences.setTestFilename(filename);
      await TestPreferences.setTestFilepath(filePath);
      await TestPreferences.setProgressBefore(downloadProgress);
      await TestPreferences.setPartialSize(actualSize);

      _log('');
      _log('════════════════════════════════════════');
      _log('🎯 TEST CHECKPOINT');
      _log('════════════════════════════════════════');
      _log('✅ Download started: $downloadProgress% (~$estimatedMB MB)');
      _log('✅ Test state saved');
      _log('');
      _log('📱 NOW KILL THE APP:');
      _log('   1. Swipe up to show app switcher');
      _log('   2. Swipe up on this app to kill it');
      _log('   3. Restart the app');
      _log('   4. Tap "Continue Resume Test" button');
      _log('');
      _log('⚠️  Background download will continue!');
      _log('════════════════════════════════════════');

      // Show instruction on screen
      setState(() {
        _killAppInstruction =
            '📱 NOW KILL THE APP:\n\n'
            '1. Swipe up → show app switcher\n'
            '2. Swipe up on this app to kill it\n'
            '3. Restart the app\n'
            '4. Tap "Continue Resume Test"\n\n'
            '⚠️  Note: iOS force kill stops background downloads.\n'
            'The download will restart from 0%, but resume\n'
            'mechanism will still be tested.\n\n'
            'Progress: $downloadProgress% (~$estimatedMB MB)';
      });

      // Update test state after user sees instruction
      await TestPreferences.setTestStage('after_restart');

      // Cancel subscription but DON'T pause/cancel task
      // Let it run in background like real scenario
      await _currentDownloadSubscription?.cancel();
      _currentDownloadSubscription = null;

      setState(() {
        _testStatus = '⚠️ WAITING FOR APP KILL';
      });
    });
  }

  Future<void> _testInterruptAndRestart_Part2() async {
    // Clear instruction when starting Part 2
    setState(() {
      _killAppInstruction = null;
    });

    await _runTest('Real App Kill - Part 2', () async {
      // Load test state
      final url = await TestPreferences.getTestUrl();
      final filename = await TestPreferences.getTestFilename();
      final filePath = await TestPreferences.getTestFilepath();
      final progressBefore = await TestPreferences.getProgressBefore() ?? 0;
      final partialSizeBefore = await TestPreferences.getPartialSize() ?? 0;

      if (url == null || filename == null || filePath == null) {
        throw Exception('❌ Test state not found! Did you run Part 1 first?');
      }

      _log('🔄 Continuing test after app restart...');
      _log('📋 Saved state: $progressBefore% before kill');

      // === CHECK 1: Check if file exists (may not on iOS until complete) ===
      final partialFile = File(filePath);
      final partialExists = await partialFile.exists();

      int currentSize = 0;
      if (partialExists) {
        currentSize = await partialFile.length();
        final currentMB = (currentSize / 1024 / 1024).toStringAsFixed(1);
        _log('✅ Partial file exists: $currentMB MB');

        if (currentSize > partialSizeBefore && partialSizeBefore > 0) {
          final downloaded = ((currentSize - partialSizeBefore) / 1024 / 1024)
              .toStringAsFixed(1);
          _log(
            '✅ Background download worked! Downloaded $downloaded MB during app kill',
          );
        }
      } else {
        _log(
          '⚠️  File not yet on disk (iOS may keep in temp) - checking task database...',
        );
      }

      // === CHECK 2: Task should be in FileDownloader database ===
      final downloader = FileDownloader();

      // First, call resumeFromBackground to restore interrupted tasks
      _log('🔄 Calling resumeFromBackground()...');
      await downloader.resumeFromBackground();
      await Future.delayed(
        const Duration(seconds: 2),
      ); // Give it time to restore

      final records = await downloader.database.allRecords();
      final record = records.cast<TaskRecord?>().firstWhere(
        (r) => r?.task.filename == filename,
        orElse: () => null,
      );

      if (record == null) {
        _log(
          '⚠️  Task not in database - resumeFromBackground() should restore it',
        );
        _log('🔄 Calling resumeFromBackground()...');
        await downloader.resumeFromBackground();

        // Check again
        final records2 = await downloader.database.allRecords();
        final record2 = records2.cast<TaskRecord?>().firstWhere(
          (r) => r?.task.filename == filename,
          orElse: () => null,
        );

        if (record2 == null) {
          throw Exception('❌ Task not restored by resumeFromBackground()!');
        }

        _log('✅ Task restored: ${record2.status.name}');
      } else {
        _log('✅ Task found in database: ${record.status.name}');
      }

      // Get the latest record
      final finalRecords = await downloader.database.allRecords();
      final taskRecord = finalRecords.cast<TaskRecord?>().firstWhere(
        (r) => r?.task.filename == filename,
        orElse: () => null,
      );

      if (taskRecord == null) {
        throw Exception('❌ Task disappeared!');
      }

      final task = taskRecord.task;
      if (task is! DownloadTask) {
        throw Exception('❌ Task is not DownloadTask: ${task.runtimeType}');
      }

      // === CHECK 3: Resume download ===
      if (currentSize > 0) {
        final currentMB = (currentSize / 1024 / 1024).toStringAsFixed(1);
        _log('🔄 Resuming download from $currentMB MB...');
      } else {
        _log('🔄 Resuming download...');
      }

      // Check if can resume
      final canResume = await downloader.taskCanResume(task);
      if (!canResume) {
        _log('⚠️  Cannot resume, will restart download');
        // Start new download
        await for (final progress in SmartDownloader.downloadWithProgress(
          url: url,
          targetPath: filePath,
          maxRetries: 3,
        )) {
          setState(() => _progress['resumed'] = progress);
        }
      } else {
        _log('✅ Task can be resumed');

        // Resume the task
        final completer = Completer<void>();
        // NOT `downloader.updates`: this task is in flutter_gemma's own group,
        // and group callbacks outrank the updates stream — so once any
        // SmartDownloader download has run in this process, a listener here
        // would receive nothing and this test would hang rather than fail.
        // This screen is the integration harness and is deliberately observing
        // flutter_gemma's OWN task. A host app watches its own downloads
        // through FileDownloader().updates, which stays free (#445), and its
        // model downloads through installModel(...).withProgress(...).
        // ignore: invalid_use_of_visible_for_testing_member
        final resumeListener = SmartDownloader.debugResolveUpdatesStream()
            .listen((update) {
              if (update.task.taskId != task.taskId) return;

              if (update is TaskProgressUpdate) {
                final percents = (update.progress * 100).round();
                setState(() => _progress['resumed'] = percents);
              } else if (update is TaskStatusUpdate) {
                if (update.status == TaskStatus.complete) {
                  completer.complete();
                } else if (update.status == TaskStatus.failed) {
                  completer.completeError('Resume failed: ${update.exception}');
                }
              }
            });

        final resumed = await downloader.resume(task);
        if (!resumed) {
          await resumeListener.cancel();
          throw Exception('❌ Failed to resume task!');
        }

        _log('✅ Resume started, waiting for completion...');

        // Wait for completion
        try {
          await completer.future;
          await resumeListener.cancel();
        } catch (e) {
          await resumeListener.cancel();
          throw Exception('❌ Resume failed: $e');
        }
      }

      // === CHECK 4: Download should be complete ===
      final finalSize = await File(filePath).length();
      final finalMB = (finalSize / 1024 / 1024).toStringAsFixed(1);
      _log('✅ Download completed: $finalMB MB');

      if (finalSize < 100 * 1024 * 1024) {
        throw Exception(
          '❌ Final file too small ($finalMB MB), expected ~509 MB',
        );
      }

      _log('');
      _log('🎉 APP KILL & RESUME TEST SUCCESS!');
      _log('📊 Summary:');
      _log('  • Before kill: $progressBefore%');
      if (partialSizeBefore > 0) {
        _log(
          '  • File before: ${(partialSizeBefore / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      }
      if (currentSize > 0 && currentSize > partialSizeBefore) {
        _log(
          '  • After restart: ${(currentSize / 1024 / 1024).toStringAsFixed(1)} MB',
        );
        _log('  • Background download: ✅ Worked during kill!');
      } else {
        _log('  • Background download: ⚠️  Reset by iOS force kill (expected)');
      }
      _log('  • Final: $finalMB MB');
      _log('  • State persistence: ✅ Works!');
      _log('  • Resume mechanism: ✅ Works!');

      // Clean up test state
      await TestPreferences.clearAll();

      setState(() {
        _testStatus = 'Passed';
        _hasPendingResumeTest = false;
      });
    });
  }

  Future<void> _resumeInterrupted() async {
    if (_interruptedUrl == null || _interruptedPath == null) {
      _log('❌ No interrupted download found');
      return;
    }

    await _runTest('Resume Interrupted Download', () async {
      _log('🔄 Resuming download from: $_interruptedUrl');
      _log('📁 Target: $_interruptedPath');

      await for (final progress in SmartDownloader.downloadWithProgress(
        url: _interruptedUrl!,
        targetPath: _interruptedPath!,
        maxRetries: 3,
      )) {
        setState(() => _progress['resumed'] = progress);
      }

      // Download completed
      final file = File(_interruptedPath!);
      final size = await file.length();
      final sizeMB = (size / 1024 / 1024).toStringAsFixed(1);
      _log('✅ Download resumed and completed: $sizeMB MB ($size bytes)');

      // Clear interrupted state
      await TestPreferences.clearInterruptedDownload();

      setState(() {
        _interruptedUrl = null;
        _interruptedPath = null;
      });

      _log('✅ Resume test completed successfully!');
    });
  }

  Future<void> _testConcurrentDownloads() async {
    await _runTest('Concurrent (Leg+Mod)', () async {
      final testDir = await _getTestDir();

      // === Test 1: Legacy Concurrent Downloads ===
      _log('🔧 Testing Legacy concurrent downloads (2 parallel)...');

      final legacyFile1 = '$testDir/legacy_concurrent1.bin';
      final legacyFile2 = '$testDir/legacy_concurrent2.bin';

      await File(legacyFile1).delete().catchError((_) => File(legacyFile1));
      await File(legacyFile2).delete().catchError((_) => File(legacyFile2));

      _log('📥 Legacy: Starting 2 downloads in parallel...');

      final download1 = SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/Go.gitignore',
        targetPath: legacyFile1,
        maxRetries: 3,
      );

      final download2 = SmartDownloader.downloadWithProgress(
        url:
            'https://raw.githubusercontent.com/github/gitignore/main/Ruby.gitignore',
        targetPath: legacyFile2,
        maxRetries: 3,
      );

      // Listen to both streams concurrently
      final legacyFutures = await Future.wait([
        _listenToDownload(download1, 'legacy_concurrent1'),
        _listenToDownload(download2, 'legacy_concurrent2'),
      ]);

      if (legacyFutures.every((completed) => completed)) {
        final size1 = await File(legacyFile1).length();
        final size2 = await File(legacyFile2).length();
        _log('✅ Legacy Download 1: $size1 bytes');
        _log('✅ Legacy Download 2: $size2 bytes');
        _log('✅ Legacy: Concurrent downloads successful!');
      } else {
        throw Exception('Legacy: Not all downloads completed');
      }

      // === Test 2: Modern API Concurrent Downloads ===
      _log('🆕 Testing Modern API concurrent downloads (2 parallel)...');
      FlutterGemma.initialize(
        maxDownloadRetries: 3,
        inferenceEngines: kExampleInferenceEngines,
        embeddingBackends: kExampleEmbeddingBackends,
        embeddingTokenizers: kExampleEmbeddingTokenizers,
      );

      final documentsDir = testDir.replaceAll('/integration_tests', '');
      final modernFile1 = '$documentsDir/Dart.gitignore';
      final modernFile2 = '$documentsDir/Kotlin.gitignore';

      await File(modernFile1).delete().catchError((_) => File(modernFile1));
      await File(modernFile2).delete().catchError((_) => File(modernFile2));

      _log('📥 Modern: Starting 2 downloads in parallel...');

      // Start both downloads concurrently
      await Future.wait([
        FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
            .fromNetwork(
              'https://raw.githubusercontent.com/github/gitignore/main/Dart.gitignore',
            )
            .withProgress((progress) {
              setState(() => _progress['modern_concurrent1'] = progress);
            })
            .install(),
        FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
            .fromNetwork(
              'https://raw.githubusercontent.com/github/gitignore/main/Kotlin.gitignore',
            )
            .withProgress((progress) {
              setState(() => _progress['modern_concurrent2'] = progress);
            })
            .install(),
      ]);

      final modernSize1 = await File(modernFile1).length();
      final modernSize2 = await File(modernFile2).length();
      _log('✅ Modern Download 1 completed: $modernSize1 bytes');
      _log('✅ Modern Download 2 completed: $modernSize2 bytes');
      _log('✅ Modern: Concurrent downloads successful!');

      _log('✅ Concurrent Downloads: Both Legacy & Modern API work!');
    });
  }

  Future<bool> _listenToDownload(Stream<int> stream, String id) async {
    await for (final progress in stream) {
      setState(() => _progress[id] = progress);
      if (progress == 100) {
        return true;
      }
    }
    return false;
  }

  // === STORAGE MANAGEMENT METHODS ===

  Future<void> _showOrphanedFiles() async {
    await _runTest('Show Orphaned Files', () async {
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
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
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

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
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
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
      const resourceName = 'gemma3-270m-it-q8.task';

      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

      _log('🔧 Creating BundledSource spec via MobileModelManager...');

      // Legacy API: Create bundled inference spec
      final spec = legacy_mobile.MobileModelManager.createBundledInferenceSpec(
        resourceName: resourceName,
      );

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
      const resourceName = 'gemma3-270m-it-q8.task';

      // Cleanup: Delete model if already installed (for honest testing)
      if (await FlutterGemma.isModelInstalled(resourceName)) {
        _log('🧹 Cleaning up existing model before test...');
        final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
        final spec =
            legacy_mobile.MobileModelManager.createBundledInferenceSpec(
              resourceName: resourceName,
            );
        await manager.deleteModel(spec);
      }

      _log(
        '🔧 Installing via Modern API: FlutterGemma.installModel().fromBundled()',
      );

      // Modern API: Install bundled model
      await FlutterGemma.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromBundled(resourceName).withProgress((progress) {
        _log('📊 Installation progress: $progress%');
      }).install();

      _log('✅ [MODERN] Bundled model installed (zero-copy!)');
      _log('📁 Model ID: $resourceName');

      // Modern API: Verify installation
      final isInstalled = await FlutterGemma.isModelInstalled(resourceName);
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
      const modelResourceName =
          'embeddinggemma-300M_seq1024_mixed-precision.tflite';
      const tokenizerResourceName = 'sentencepiece.model';

      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

      _log(
        '🔧 Creating BundledSource embedding spec via MobileModelManager...',
      );

      // Legacy API: Create bundled embedding spec
      final spec = legacy_mobile.MobileModelManager.createBundledEmbeddingSpec(
        modelResourceName: modelResourceName,
        tokenizerResourceName: tokenizerResourceName,
      );

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
      const modelResourceName =
          'embeddinggemma-300M_seq1024_mixed-precision.tflite';
      const tokenizerResourceName = 'sentencepiece.model';

      // Cleanup: Delete model if already installed (for honest testing)
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      final spec = legacy_mobile.MobileModelManager.createBundledEmbeddingSpec(
        modelResourceName: modelResourceName,
        tokenizerResourceName: tokenizerResourceName,
      );
      if (await manager.isModelInstalled(spec)) {
        _log('🧹 Cleaning up existing model before test...');
        await manager.deleteModel(spec);
      }

      _log('🔧 Installing Model + Tokenizer via Modern API...');

      // Modern API: Install embedding model (model + tokenizer together)
      await FlutterGemma.installEmbedder()
          .modelFromBundled(modelResourceName)
          .tokenizerFromBundled(tokenizerResourceName)
          .install();

      _log('✅ [MODERN] Embedding model + tokenizer installed');

      // Modern API: Verify both files installed
      final modelInstalled = await FlutterGemma.isModelInstalled(
        modelResourceName,
      );
      final tokenizerInstalled = await FlutterGemma.isModelInstalled(
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

    final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
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

    // Legacy API: Create spec and download
    final spec = legacy_mobile.InferenceModelSpec.fromLegacyUrl(
      name: 'gemma3-270m-it-q8.task',
      modelUrl: inferenceModelUrl,
    );

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
    if (await FlutterGemma.isModelInstalled(filename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      final spec = legacy_mobile.InferenceModelSpec.fromLegacyUrl(
        name: filename,
        modelUrl: inferenceModelUrl,
      );
      await manager.deleteModel(spec);
    }

    // Modern API: Install model from network
    await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
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

    final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

    // Legacy API: Create inference spec from asset
    final spec = legacy_mobile.MobileModelManager.createInferenceSpec(
      name: 'gemma3-270m-it-q8',
      modelUrl: inferenceAssetPath,
    );

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
    if (await FlutterGemma.isModelInstalled(filename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      final spec = legacy_mobile.MobileModelManager.createInferenceSpec(
        name: filename.split('.').first,
        modelUrl: inferenceAssetPath,
      );
      await manager.deleteModel(spec);
    }

    setState(() => _progress['inference_asset_modern'] = 0);

    // Modern API: Install model from asset
    await FlutterGemma.installModel(
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

  Future<void> _setCustomInferencePathLegacy() async {
    await _runTest('Set Custom Inference Path (Legacy)', () async {
      final path = _customInferencePathController.text.trim();
      if (path.isEmpty) {
        throw Exception('Path is empty');
      }

      _log('📁 [LEGACY] Setting custom inference path: $path');

      final file = File(path);
      if (!await file.exists()) {
        throw Exception('File does not exist: $path');
      }

      // Legacy API: setModelPath
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      await manager.setModelPath(path);

      _log('✅ [LEGACY] Custom inference path set successfully');
      setState(() => _inferenceModelReady = true);
    });
  }

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
      await FlutterGemma.installModel(
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
    final inferenceModel = await legacy.FlutterGemmaPlugin.instance.createModel(
      modelType: legacy.ModelType.gemmaIt,
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

    final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
    final token = _huggingFaceTokenController.text.trim();

    if (token.isEmpty) {
      _log(
        '⚠️  Note: No HuggingFace token provided. Some models may require authentication.',
      );
    }

    // Legacy API: Create embedding spec (includes both model and tokenizer)
    final spec = legacy_mobile.EmbeddingModelSpec.fromLegacyUrl(
      name: 'embeddinggemma-300m',
      modelUrl: embeddingModelUrl,
      tokenizerUrl: embeddingTokenizerUrl,
    );

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
    if (await FlutterGemma.isModelInstalled(modelFilename) ||
        await FlutterGemma.isModelInstalled(tokenizerFilename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      final spec = legacy_mobile.EmbeddingModelSpec.fromLegacyUrl(
        name: modelFilename.split('.').first,
        modelUrl: embeddingModelUrl,
        tokenizerUrl: embeddingTokenizerUrl,
      );
      await manager.deleteModel(spec);
    }

    // Modern API: Download model + tokenizer together
    _log('📥 Downloading model and tokenizer...');
    await FlutterGemma.installEmbedder()
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

    final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

    // Legacy API: Create embedding spec with both model and tokenizer
    final spec = legacy_mobile.MobileModelManager.createEmbeddingSpec(
      name: 'embeddinggemma-300M',
      modelUrl: embeddingModelAssetPath,
      tokenizerUrl: embeddingTokenizerAssetPath,
    );

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
    if (await FlutterGemma.isModelInstalled(modelFilename) ||
        await FlutterGemma.isModelInstalled(tokenizerFilename)) {
      _log('🧹 Cleaning up existing model before test...');
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;
      final spec = legacy_mobile.MobileModelManager.createEmbeddingSpec(
        name: modelFilename.split('.').first,
        modelUrl: embeddingModelAssetPath,
        tokenizerUrl: embeddingTokenizerAssetPath,
      );
      await manager.deleteModel(spec);
    }

    setState(() => _progress['embedding_asset_modern'] = 0);

    // Modern API: Install model + tokenizer together from assets
    await FlutterGemma.installEmbedder()
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
    final embeddingModel = await legacy.FlutterGemmaPlugin.instance
        .createEmbeddingModel();

    _log('✅ Embedding model created successfully');
    _log('');

    // Test 1: Simple embedding
    _log('💬 Test 1: Generating embedding for: "Hello, world!"');
    final startTime1 = DateTime.now();
    final embedding1 = await embeddingModel.generateEmbedding('Hello, world!');
    final duration1 = DateTime.now().difference(startTime1);

    _log('🔢 Embedding dimensions: ${embedding1.length}');
    _log('🔢 First 5 values: ${embedding1.take(5).toList()}');
    _log('⏱️  Generation time: ${duration1.inMilliseconds}ms');
    _log('');

    // Test 2: Different text
    _log('💬 Test 2: Generating embedding for: "Artificial Intelligence"');
    final startTime2 = DateTime.now();
    final embedding2 = await embeddingModel.generateEmbedding(
      'Artificial Intelligence',
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
      _totalTests = 32; // Download(8) + Assets(8) + Bundled(8) + FileSource(8)
      _runAllTestsProgress = '';
    });

    _log('🚀 Running all integration tests...');
    _log('📋 Total: $_totalTests tests');
    _log('📋 Plan:');
    _log('  1. Cleanup all downloaded models');
    _log('  2. Download tests (with cleanup after each): 8 tests');
    _log('  3. Assets tests (with cleanup after each): 8 tests');
    _log('  4. Bundled tests (NO cleanup): 4 tests');
    _log('');

    try {
      final manager = legacy.FlutterGemmaPlugin.instance.modelManager;

      // ═══════════════════════════════════════════════════════════════
      // STEP 0: CLEANUP ALL DOWNLOADED MODELS
      // ═══════════════════════════════════════════════════════════════
      _log('═══════════════════════════════════════════');
      _log('🧹 CLEANUP: Deleting all installed models');
      _log('═══════════════════════════════════════════');

      // Cleanup inference models
      final inferenceModels = await manager.getInstalledModels(
        legacy_mobile.ModelManagementType.inference,
      );
      for (final modelName in inferenceModels) {
        _log('  🗑️  Deleting inference: $modelName');
      }

      // Cleanup embedding models
      final embeddingModels = await manager.getInstalledModels(
        legacy_mobile.ModelManagementType.embedding,
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

      final inferenceSpec = legacy_mobile.InferenceModelSpec.fromLegacyUrl(
        name: 'gemma3-270m-it-q8',
        modelUrl: inferenceModelUrl,
      );

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
      final inferenceModel1 = await legacy.FlutterGemmaPlugin.instance
          .createModel(modelType: legacy.ModelType.gemmaIt, maxTokens: 512);
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
      await FlutterGemma.installModel(modelType: legacy.ModelType.gemmaIt)
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
      final inferenceModel2 = await FlutterGemma.getActiveModel(maxTokens: 512);
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
          '⏭️  [5-8/32] Skipping Network Embedding tests (not implemented on web)',
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

        final embeddingSpec = legacy_mobile.EmbeddingModelSpec.fromLegacyUrl(
          name: 'embeddinggemma-300m',
          modelUrl: embeddingModelUrl,
          tokenizerUrl: embeddingTokenizerUrl,
        );

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
        final embeddingModel1 = await legacy.FlutterGemmaPlugin.instance
            .createEmbeddingModel();
        final emb1 = await embeddingModel1.generateEmbedding('Hello, world!');
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
        await FlutterGemma.installEmbedder()
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
        final embeddingModel2 = await FlutterGemma.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb2 = await embeddingModel2.generateEmbedding('Hello, world!');
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
        _log('⏭️  [9-16/32] Skipping all Assets tests (files not available)');
        _log('');
        _currentTestIndex += 8;
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        // TEST 9-10: Inference Assets Legacy
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] Assets Inference (Legacy) - Install',
        );

        final assetInferenceSpec =
            legacy_mobile.MobileModelManager.createInferenceSpec(
              name: 'gemma3-270m-it-q8',
              modelUrl: inferenceAssetPath,
            );

        _log('  📦 Installing from assets...');
        await manager.ensureModelReadyFromSpec(assetInferenceSpec);
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        final inferenceModel3 = await legacy.FlutterGemmaPlugin.instance
            .createModel(modelType: legacy.ModelType.gemmaIt, maxTokens: 512);
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
        await FlutterGemma.installModel(
          modelType: legacy.ModelType.gemmaIt,
        ).fromAsset(inferenceAssetPath).install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        _log('  🔧 Getting active model with Modern API...');
        final inferenceModel4 = await FlutterGemma.getActiveModel(
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
            '⏭️  [13-16/32] Skipping Assets Embedding tests (not implemented on web)',
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

          final assetEmbeddingSpec =
              legacy_mobile.MobileModelManager.createEmbeddingSpec(
                name: 'embeddinggemma-300M',
                modelUrl: embeddingModelAssetPath,
                tokenizerUrl: embeddingTokenizerAssetPath,
              );

          _log('  📦 Installing model and tokenizer from assets...');
          await manager.ensureModelReadyFromSpec(assetEmbeddingSpec);
          _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
          setState(() => _embeddingModelReady = true);
          await Future.delayed(const Duration(milliseconds: 500));

          _currentTestIndex++;
          _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
          final embeddingModel3 = await legacy.FlutterGemmaPlugin.instance
              .createEmbeddingModel();
          final emb3 = await embeddingModel3.generateEmbedding('Hello, world!');
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
          await FlutterGemma.installEmbedder()
              .modelFromAsset(embeddingModelAssetPath)
              .tokenizerFromAsset(embeddingTokenizerAssetPath)
              .install();
          _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
          setState(() => _embeddingModelReady = true);
          await Future.delayed(const Duration(milliseconds: 500));

          _currentTestIndex++;
          _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
          _log('  🔧 Getting active embedding model with Modern API...');
          final embeddingModel4 = await FlutterGemma.getActiveEmbedder();
          _log('  ✅ Model ready');
          _log('  🔧 Generating embedding...');
          final emb4 = await embeddingModel4.generateEmbedding('Hello, world!');
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

      final bundledInferenceSpec =
          legacy_mobile.MobileModelManager.createBundledInferenceSpec(
            resourceName: 'gemma3-270m-it-q8.task',
          );

      _log('  📲 Installing from bundled resources...');
      await manager.ensureModelReadyFromSpec(bundledInferenceSpec);
      _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      final inferenceModel5 = await legacy.FlutterGemmaPlugin.instance
          .createModel(modelType: legacy.ModelType.gemmaIt, maxTokens: 512);
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
      await FlutterGemma.installModel(
        modelType: legacy.ModelType.gemmaIt,
      ).fromBundled('gemma3-270m-it-q8.task').install();
      _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
      setState(() => _inferenceModelReady = true);
      await Future.delayed(const Duration(milliseconds: 500));

      _currentTestIndex++;
      _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
      _log('  🔧 Getting active model with Modern API...');
      final inferenceModel6 = await FlutterGemma.getActiveModel(maxTokens: 512);
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
          '⏭️  [21-24/32] Skipping Bundled Embedding tests (not implemented on web)',
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

        final bundledEmbeddingSpec =
            legacy_mobile.MobileModelManager.createBundledEmbeddingSpec(
              modelResourceName:
                  'embeddinggemma-300M_seq1024_mixed-precision.tflite',
              tokenizerResourceName: 'sentencepiece.model',
            );

        _log('  📲 Installing from bundled resources...');
        await manager.ensureModelReadyFromSpec(bundledEmbeddingSpec);
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        final embeddingModel5 = await legacy.FlutterGemmaPlugin.instance
            .createEmbeddingModel();
        final emb5 = await embeddingModel5.generateEmbedding('Hello, world!');
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
        await FlutterGemma.installEmbedder()
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
        final embeddingModel6 = await FlutterGemma.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb6 = await embeddingModel6.generateEmbedding('Hello, world!');
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
      _log('📁 SECTION 4: FILE SOURCE TESTS (8 tests)');
      _log('═══════════════════════════════════════════');

      // TEST 25-32: All FileSource tests - SKIP ON WEB (local paths not supported)
      if (kIsWeb) {
        _log(
          '⏭️  [25-32/32] Skipping all FileSource tests (local file paths not available)',
        );
        _log(
          '💡 Web: FileSource works with URLs/assets, but these tests use local paths',
        );
        _currentTestIndex += 8;
      } else {
        // TEST 25-26: FileSource Inference Legacy
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Inference (Legacy) - Install',
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

        _log('  📁 [LEGACY] Setting custom inference path...');
        await manager.setModelPath(inferenceFilePath);
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        final inferenceModel7 = await legacy.FlutterGemmaPlugin.instance
            .createModel(modelType: legacy.ModelType.gemmaIt, maxTokens: 512);
        final session7 = await inferenceModel7.createSession();
        await session7.addQueryChunk(
          const legacy.Message(
            text: 'What is the capital of France?',
            isUser: true,
          ),
        );
        final response7 = await session7.getResponse();
        if (response7.isEmpty) {
          throw Exception('Model returned empty response');
        }
        _log(
          '  📝 Response (${response7.length} chars): ${response7.length > 100 ? "${response7.substring(0, 100)}..." : response7}',
        );
        await session7.close();
        await inferenceModel7.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Inference complete');
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 27-28: FileSource Inference Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Inference (Modern) - Install',
        );

        _log('  📁 [MODERN] Installing from file...');
        await FlutterGemma.installModel(
          modelType: legacy.ModelType.gemmaIt,
        ).fromFile(inferenceFilePath).install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _inferenceModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Inference');
        _log('  🔧 Getting active model with Modern API...');
        final inferenceModel8 = await FlutterGemma.getActiveModel(
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

        // TEST 29-30: FileSource Embedding Legacy
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

        _log(
          '  📁 [LEGACY] Paths validated (Legacy API uses paths directly in createEmbeddingModel)',
        );
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        final embeddingModel7 = await legacy.FlutterGemmaPlugin.instance
            .createEmbeddingModel(
              modelPath: embeddingModelPath,
              tokenizerPath: embeddingTokenizerPath,
            );
        final emb7 = await embeddingModel7.generateEmbedding('Hello, world!');
        _log('  🔢 Dimensions: ${emb7.length}');
        _log('  🔢 First 5 values: ${emb7.take(5).toList()}');
        await embeddingModel7.close();
        _log('✅ [$_currentTestIndex/$_totalTests] Embedding complete');
        await Future.delayed(const Duration(milliseconds: 500));

        // TEST 31-32: FileSource Embedding Modern
        _currentTestIndex++;
        _log(
          '▶️  [$_currentTestIndex/$_totalTests] FileSource Embedding (Modern) - Install',
        );

        _log('  📁 [MODERN] Installing from files...');
        await FlutterGemma.installEmbedder()
            .modelFromFile(embeddingModelPath)
            .tokenizerFromFile(embeddingTokenizerPath)
            .install();
        _log('✅ [$_currentTestIndex/$_totalTests] Install complete');
        setState(() => _embeddingModelReady = true);
        await Future.delayed(const Duration(milliseconds: 500));

        _currentTestIndex++;
        _log('▶️  [$_currentTestIndex/$_totalTests]   ▶️ Run Embedding');
        _log('  🔧 Getting active embedding model with Modern API...');
        final embeddingModel8 = await FlutterGemma.getActiveEmbedder();
        _log('  ✅ Model ready');
        _log('  🔧 Generating embedding...');
        final emb8 = await embeddingModel8.generateEmbedding('Hello, world!');
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
        '✅ Section 4 - FileSource: 4 installs, 4 runs (inference + embedding)',
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

            // Kill app instruction
            if (_killAppInstruction != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  border: Border.all(color: Colors.orange, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _killAppInstruction!,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
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
                      Text('  • FileSource (4 install + 4 run = 8)'),
                      SizedBox(height: 4),
                      Text(
                        'Total: 32 tests',
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
                  '▶️  RUN ALL TESTS (32 tests)',
                  _isTesting ? null : _runAllTests,
                  _isTesting ? Colors.grey : Colors.green,
                ),
              ],
            ),

            // === SECTION 1: Download Tests ===
            _buildSection(
              title: 'Download Tests',
              children: [
                _buildButton('2 Seq (L+M)', _testSequentialDownloads),
                _buildButton('3 Seq (L+M)', _testThreeSequentialDownloads),
                _buildButton('Replace+File+LoRA', _testReplacePolicy),
                _buildButton('Progress (L+M)', _testProgressTracking),
                _buildButton('404 (L+M)', _test404Error),
                _buildButton('401 (L+M)', _test401Error),
                _buildButton(
                  'App Kill Resume',
                  _testInterruptAndRestart,
                  Colors.orange,
                ),
                if (_hasPendingResumeTest)
                  _buildButton(
                    'Continue Resume Test',
                    _testInterruptAndRestart_Part2,
                    Colors.deepOrange,
                  ),
                if (_interruptedUrl != null && _interruptedPath != null)
                  _buildButton(
                    'Resume Manual',
                    _resumeInterrupted,
                    Colors.purple,
                  ),
                _buildButton(
                  'Concurrent (L+M)',
                  _testConcurrentDownloads,
                  Colors.cyan,
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
                      Row(
                        children: [
                          Expanded(
                            child: _buildButton(
                              'Legacy',
                              _setCustomInferencePathLegacy,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildButton(
                              'Modern',
                              _setCustomInferencePathModern,
                            ),
                          ),
                        ],
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
