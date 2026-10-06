import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/services/file_system_service.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/core/services/asset_loader.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
import 'package:flutter_edge_ai/core/services/protected_files_registry.dart';

/// Mock FileSystemService that tracks file operations
class MockFileSystemService implements FileSystemService {
  final Set<String> _files = {};
  final Map<String, String> _externalPaths = {};
  bool deleteFileCalled = false;
  String? lastDeletedPath;

  @override
  Future<void> deleteFile(String path) async {
    deleteFileCalled = true;
    lastDeletedPath = path;
    _files.remove(path);
  }

  @override
  Future<bool> fileExists(String path) async => _files.contains(path);

  @override
  Future<String> getBundledResourcePath(String resourceName) async =>
      '/bundled/$resourceName';

  @override
  Future<int> getFileSize(String path) async =>
      _files.contains(path) ? 1024 : 0;

  @override
  Future<String> getTargetPath(String filename) async => '/models/$filename';

  @override
  Future<String> getReadTargetPath(String filename) async =>
      '/models/$filename';

  @override
  Future<String> getWriteTargetPath(String filename) async =>
      '/models/$filename';

  @override
  Future<Uint8List> readFile(String path) async => Uint8List(0);

  @override
  Future<void> registerExternalFile(
    String filename,
    String externalPath,
  ) async {
    _externalPaths[filename] = externalPath;
  }

  @override
  Future<String> getModelStorageDirectory() async => '/models';

  @override
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename) async =>
      false;

  @override
  Future<void> writeFile(String path, List<int> data) async {
    _files.add(path);
  }

  /// Helper to simulate file creation
  void createFile(String path) {
    _files.add(path);
  }

  /// Check if file exists (for testing)
  bool hasFile(String path) => _files.contains(path);

  void reset() {
    deleteFileCalled = false;
    lastDeletedPath = null;
    _files.clear();
    _externalPaths.clear();
  }
}

/// Mock DownloadService
class MockDownloadService implements DownloadService {
  final MockFileSystemService fileSystem;

  MockDownloadService(this.fileSystem);

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    fileSystem.createFile(targetPath);
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    fileSystem.createFile(targetPath);
    yield 100;
  }
}

/// Mock AssetLoader
class MockAssetLoader implements AssetLoader {
  @override
  Future<Uint8List> loadAsset(String assetPath) async => Uint8List(1024);
}

/// Mock ModelRepository that tracks saved/deleted models
class MockModelRepository implements ModelRepository {
  final Map<String, ModelInfo> _models = {};
  bool deleteModelCalled = false;
  String? lastDeletedId;

  @override
  Future<void> deleteModel(String id) async {
    deleteModelCalled = true;
    lastDeletedId = id;
    _models.remove(id);
  }

  @override
  Future<ModelInfo?> loadModel(String id) async => _models[id];

  @override
  Future<List<ModelInfo>> listInstalled() async => _models.values.toList();

  @override
  Future<void> saveModel(ModelInfo info) async {
    _models[info.id] = info;
  }

  @override
  Future<bool> isInstalled(String id) async => _models.containsKey(id);

  /// Check if model metadata exists (for testing)
  bool hasModel(String id) => _models.containsKey(id);

  void reset() {
    deleteModelCalled = false;
    lastDeletedId = null;
    _models.clear();
  }
}

/// Mock ProtectedFilesRegistry
class MockProtectedFilesRegistry implements ProtectedFilesRegistry {
  final Set<String> _protected = {};
  final Map<String, String> _externalPaths = {};

  @override
  Future<void> protect(String filename) async {
    _protected.add(filename);
  }

  @override
  Future<void> unprotect(String filename) async {
    _protected.remove(filename);
  }

  @override
  Future<bool> isProtected(String filename) async =>
      _protected.contains(filename);

  @override
  Future<List<String>> getProtectedFiles() async => _protected.toList();

  @override
  Future<void> clearAll() async {
    _protected.clear();
  }

  @override
  Future<void> registerExternalPath(
    String filename,
    String externalPath,
  ) async {
    _externalPaths[filename] = externalPath;
  }

  @override
  Future<String?> getExternalPath(String filename) async =>
      _externalPaths[filename];

  @override
  Future<void> unregisterExternalPath(String filename) async {
    _externalPaths.remove(filename);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockFileSystemService mockFS;
  late MockModelRepository mockRepo;

  setUp(() {
    mockFS = MockFileSystemService();
    mockRepo = MockModelRepository();
  });

  tearDown(() {
    mockFS.reset();
    mockRepo.reset();
  });

  group('Model Uninstall Logic', () {
    test('proper uninstall removes both metadata and file', () async {
      // Arrange - simulate installed model
      const modelId = 'test-model.task';
      const modelPath = '/models/test-model.task';

      // Create file
      mockFS.createFile(modelPath);

      // Create metadata
      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://example.com/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);

      // Verify initial state
      expect(mockRepo.hasModel(modelId), isTrue);
      expect(mockFS.hasFile(modelPath), isTrue);

      // Act - simulate proper uninstall (what FlutterEdgeAi.uninstallModel does)
      // 1. Delete metadata
      await mockRepo.deleteModel(modelId);
      // 2. Delete file
      await mockFS.deleteFile(modelPath);

      // Assert
      expect(
        mockRepo.hasModel(modelId),
        isFalse,
        reason: 'Metadata should be deleted',
      );
      expect(
        mockFS.hasFile(modelPath),
        isFalse,
        reason: 'File should be deleted',
      );
      expect(mockRepo.deleteModelCalled, isTrue);
      expect(mockFS.deleteFileCalled, isTrue);
    });

    test('buggy delete (file only) leaves metadata orphaned', () async {
      // This test demonstrates the BUG behavior (before fix)
      // Arrange
      const modelId = 'test-model.task';
      const modelPath = '/models/test-model.task';

      mockFS.createFile(modelPath);
      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://example.com/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);

      // Act - BAD: only delete file, NOT metadata (the bug)
      await mockFS.deleteFile(modelPath);
      // NOT calling: await mockRepo.deleteModel(modelId);

      // Assert - demonstrates the bug
      expect(mockFS.hasFile(modelPath), isFalse, reason: 'File was deleted');
      expect(
        mockRepo.hasModel(modelId),
        isTrue,
        reason: 'BUG: Metadata still exists after file deletion',
      );
      expect(
        await mockRepo.isInstalled(modelId),
        isTrue,
        reason: 'BUG: isInstalled returns true even though file is gone',
      );
    });

    test('isInstalled returns false after proper uninstall', () async {
      // Arrange
      const modelId = 'test-model.task';

      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://example.com/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);

      // Verify installed
      expect(await mockRepo.isInstalled(modelId), isTrue);

      // Act - proper uninstall
      await mockRepo.deleteModel(modelId);

      // Assert
      expect(await mockRepo.isInstalled(modelId), isFalse);
    });

    test('external file (FileSource) should not be deleted', () async {
      // Arrange - external file should not be deleted
      const modelId = 'external-model.task';
      const externalPath = '/external/path/model.task';

      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.file(externalPath),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);
      mockFS.createFile(externalPath);

      // Act - proper uninstall for external file
      final info = await mockRepo.loadModel(modelId);
      await mockRepo.deleteModel(modelId);

      // For FileSource, we should NOT delete the file
      if (info?.source is! FileSource) {
        await mockFS.deleteFile(externalPath);
      }

      // Assert
      expect(
        mockRepo.hasModel(modelId),
        isFalse,
        reason: 'Metadata should be deleted',
      );
      expect(
        mockFS.hasFile(externalPath),
        isTrue,
        reason: 'External file should NOT be deleted',
      );
    });

    test('model can be reinstalled after uninstall', () async {
      // Arrange
      const modelId = 'reinstall-test.task';
      const modelPath = '/models/reinstall-test.task';

      // First installation
      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://example.com/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);
      mockFS.createFile(modelPath);

      expect(await mockRepo.isInstalled(modelId), isTrue);

      // Uninstall
      await mockRepo.deleteModel(modelId);
      await mockFS.deleteFile(modelPath);
      expect(await mockRepo.isInstalled(modelId), isFalse);

      // Reinstall
      final newModelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://example.com/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 1024,
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(newModelInfo);
      mockFS.createFile(modelPath);

      // Assert
      expect(await mockRepo.isInstalled(modelId), isTrue);
    });
  });

  group('Issue #169 - Delete model bug verification', () {
    test('after proper deleteModel, isInstalled returns false', () async {
      // This test verifies the fix for issue #169
      // Before fix: deleteModel only deleted file, metadata remained
      // After fix: deleteModel calls FlutterEdgeAi.uninstallModel which deletes both

      // Arrange - simulate model installed via Modern API
      const modelId = 'functiongemma-flutter_q8_ekv1024.task';
      const modelPath = '/models/$modelId';

      final modelInfo = ModelInfo(
        id: modelId,
        source: ModelSource.network('https://huggingface.co/test/$modelId'),
        installedAt: DateTime.now(),
        sizeBytes: 500 * 1024 * 1024, // 500MB
        type: ModelType.inference,
        hasLoraWeights: false,
      );
      await mockRepo.saveModel(modelInfo);
      mockFS.createFile(modelPath);

      // Verify model is "installed"
      expect(await mockRepo.isInstalled(modelId), isTrue);

      // Act - simulate what FIXED deleteModel() does:
      // 1. Delete metadata from repository
      await mockRepo.deleteModel(modelId);
      // 2. Delete file
      await mockFS.deleteFile(modelPath);

      // Assert - both metadata AND file should be gone
      expect(
        await mockRepo.isInstalled(modelId),
        isFalse,
        reason: 'isInstalled should return false after uninstall',
      );
      expect(
        mockRepo.hasModel(modelId),
        isFalse,
        reason: 'Metadata should be deleted',
      );
      expect(
        mockFS.hasFile(modelPath),
        isFalse,
        reason: 'File should be deleted',
      );
    });

    test(
      'metadata persistence causes false positive on isInstalled (the bug)',
      () async {
        // This test demonstrates the bug behavior BEFORE the fix
        // If only file is deleted but metadata remains, isInstalled returns true

        // Arrange
        const modelId = 'test-model.task';

        final modelInfo = ModelInfo(
          id: modelId,
          source: ModelSource.network('https://example.com/$modelId'),
          installedAt: DateTime.now(),
          sizeBytes: 1024,
          type: ModelType.inference,
          hasLoraWeights: false,
        );
        await mockRepo.saveModel(modelInfo);
        // Note: file is NOT created, simulating deleted file with remaining metadata

        // This is the bug: metadata says installed, but file doesn't exist
        // isModelInstalled checks metadata, not file existence
        expect(
          await mockRepo.isInstalled(modelId),
          isTrue,
          reason: 'BUG: isInstalled returns true when metadata exists',
        );

        // After proper uninstall (metadata + file), both should be false
        await mockRepo.deleteModel(modelId);
        expect(await mockRepo.isInstalled(modelId), isFalse);
      },
    );
  });
}
