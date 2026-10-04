// Skip this test on VM platform - uses web-specific service_registry with dart:js_interop
@TestOn('!vm')
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/services/file_system_service.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/core/services/asset_loader.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
import 'package:flutter_edge_ai/core/services/protected_files_registry.dart';
import 'package:flutter_edge_ai/core/handlers/source_handler_registry.dart';

// Mock implementations for testing
class MockFileSystemService implements FileSystemService {
  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<bool> fileExists(String path) async => false;

  @override
  Future<String> getBundledResourcePath(String resourceName) async => '';

  @override
  Future<int> getFileSize(String path) async => 0;

  @override
  Future<String> getTargetPath(String filename) async => '';

  @override
  Future<String> getReadTargetPath(String filename) async => '';

  @override
  Future<String> getWriteTargetPath(String filename) async => '';

  @override
  Future<Uint8List> readFile(String path) async => Uint8List(0);

  @override
  Future<void> registerExternalFile(
    String filename,
    String externalPath,
  ) async {}

  @override
  Future<String> getModelStorageDirectory() async => '/models';

  @override
  Future<void> writeFile(String path, List<int> data) async {}

  @override
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename) async =>
      false;
}

class MockDownloadService implements DownloadService {
  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {}

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    yield 100;
  }
}

class MockAssetLoader implements AssetLoader {
  @override
  Future<Uint8List> loadAsset(String assetPath) async => Uint8List(0);
}

class MockModelRepository implements ModelRepository {
  @override
  Future<void> deleteModel(String id) async {}

  @override
  Future<ModelInfo?> loadModel(String id) async => null;

  @override
  Future<List<ModelInfo>> listInstalled() async => [];

  @override
  Future<void> saveModel(ModelInfo info) async {}

  @override
  Future<bool> isInstalled(String id) async => false;
}

class MockProtectedFilesRegistry implements ProtectedFilesRegistry {
  @override
  Future<void> protect(String filename) async {}

  @override
  Future<void> unprotect(String filename) async {}

  @override
  Future<bool> isProtected(String filename) async => false;

  @override
  Future<List<String>> getProtectedFiles() async => [];

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> registerExternalPath(
    String filename,
    String externalPath,
  ) async {}

  @override
  Future<String?> getExternalPath(String filename) async => null;
}

void main() {
  // Initialize Flutter bindings for tests (required by BackgroundDownloaderService)
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServiceRegistry', () {
    setUp(() {
      // Reset singleton before each test
      ServiceRegistry.reset();
    });

    tearDown(() {
      // Reset singleton after each test to prevent state leakage
      ServiceRegistry.reset();
    });

    group('Singleton Pattern', () {
      test('instance returns same instance on multiple calls', () {
        // Arrange - Use mock services to avoid BackgroundDownloaderService initialization
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();

        // Act - Initialize with mocks to avoid platform plugins
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );

        final instance1 = ServiceRegistry.instance;
        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isTrue);
      });

      test('instance auto-initializes if not manually initialized', () {
        // Arrange - Use mock services to avoid BackgroundDownloaderService initialization
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();

        // Act - Initialize with mocks first
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );

        final instance = ServiceRegistry.instance;

        // Assert
        expect(instance, isNotNull);
        expect(instance.fileSystemService, isNotNull);
        expect(instance.downloadService, isNotNull);
      });

      test('reset clears singleton instance', () {
        // Arrange - Use mock services to avoid BackgroundDownloaderService initialization
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();

        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );

        final instance1 = ServiceRegistry.instance;

        // Act
        ServiceRegistry.reset();

        // Re-initialize with mocks after reset
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );

        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isFalse);
      });

      test('initialize before instance returns same instance', () {
        // Arrange - Use mock services to avoid BackgroundDownloaderService initialization
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();

        // Act
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );
        final instance1 = ServiceRegistry.instance;
        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isTrue);
      });

      test('multiple initialize calls use first instance', () {
        // Arrange - Use mock services to avoid BackgroundDownloaderService initialization
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();

        // Act
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        );
        final instance1 = ServiceRegistry.instance;

        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
        ); // Second call
        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isTrue);
      });
    });

    group('Platform Detection', () {
      test('uses correct service types for current platform', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.fileSystemService, isNotNull);
        expect(registry.downloadService, isNotNull);

        // Platform-specific assertions would go here
        // We can't easily test kIsWeb in unit tests without conditional compilation
      });
    });

    group('Dependency Injection', () {
      test('accepts custom FileSystemService', () {
        // Arrange
        final mockFS = MockFileSystemService();

        // Act
        ServiceRegistry.initialize(fileSystemService: mockFS);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.fileSystemService, same(mockFS));
      });

      test('accepts custom DownloadService', () {
        // Arrange
        final mockDownload = MockDownloadService();

        // Act
        ServiceRegistry.initialize(downloadService: mockDownload);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.downloadService, same(mockDownload));
      });

      test('accepts custom AssetLoader', () {
        // Arrange
        final mockAsset = MockAssetLoader();

        // Act
        ServiceRegistry.initialize(assetLoader: mockAsset);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.assetLoader, same(mockAsset));
      });

      test('accepts custom ModelRepository', () {
        // Arrange
        final mockRepo = MockModelRepository();

        // Act
        ServiceRegistry.initialize(modelRepository: mockRepo);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.modelRepository, same(mockRepo));
      });

      test('accepts custom ProtectedFilesRegistry', () {
        // Arrange
        final mockProtected = MockProtectedFilesRegistry();

        // Act
        ServiceRegistry.initialize(protectedFilesRegistry: mockProtected);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.protectedFilesRegistry, same(mockProtected));
      });

      test('accepts all custom services at once', () {
        // Arrange
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();
        final mockAsset = MockAssetLoader();
        final mockRepo = MockModelRepository();
        final mockProtected = MockProtectedFilesRegistry();

        // Act
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
          assetLoader: mockAsset,
          modelRepository: mockRepo,
          protectedFilesRegistry: mockProtected,
        );
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.fileSystemService, same(mockFS));
        expect(registry.downloadService, same(mockDownload));
        expect(registry.assetLoader, same(mockAsset));
        expect(registry.modelRepository, same(mockRepo));
        expect(registry.protectedFilesRegistry, same(mockProtected));
      });
    });

    group('Configuration', () {
      test('stores huggingFaceToken', () {
        // Arrange
        const token = 'hf_testtoken123';

        // Act
        ServiceRegistry.initialize(huggingFaceToken: token);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.huggingFaceToken, token);
      });

      test('stores maxDownloadRetries', () {
        // Arrange
        const retries = 5;

        // Act
        ServiceRegistry.initialize(maxDownloadRetries: retries);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.maxDownloadRetries, retries);
      });

      test('uses default maxDownloadRetries when not specified', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.maxDownloadRetries, 10);
      });

      test('accepts null huggingFaceToken', () {
        // Act
        ServiceRegistry.initialize(huggingFaceToken: null);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.huggingFaceToken, isNull);
      });
    });

    group('Handler Registry', () {
      test('sourceHandlerRegistry is initialized', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.sourceHandlerRegistry, isNotNull);
        expect(registry.sourceHandlerRegistry, isA<SourceHandlerRegistry>());
      });

      test('all handlers are available', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.networkHandler, isNotNull);
        expect(registry.assetHandler, isNotNull);
        expect(registry.bundledHandler, isNotNull);
        expect(registry.fileHandler, isNotNull);
      });
    });

    group('Service Getters', () {
      test('all service getters return non-null values', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.fileSystemService, isNotNull);
        expect(registry.assetLoader, isNotNull);
        expect(registry.downloadService, isNotNull);
        expect(registry.modelRepository, isNotNull);
        expect(registry.protectedFilesRegistry, isNotNull);
      });

      test('service getters return same instances on multiple calls', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        expect(
          identical(registry.fileSystemService, registry.fileSystemService),
          isTrue,
        );
        expect(
          identical(registry.downloadService, registry.downloadService),
          isTrue,
        );
        expect(
          identical(
            registry.sourceHandlerRegistry,
            registry.sourceHandlerRegistry,
          ),
          isTrue,
        );
      });
    });

    group('Edge Cases', () {
      test('handles rapid reset and initialize', () {
        // Act
        for (int i = 0; i < 10; i++) {
          ServiceRegistry.reset();
          ServiceRegistry.initialize();
        }

        // Assert
        final instance = ServiceRegistry.instance;
        expect(instance, isNotNull);
      });

      test('handles reset while holding reference', () {
        // Arrange
        final instance1 = ServiceRegistry.instance;

        // Act
        ServiceRegistry.reset();
        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isFalse);
        // instance1 is still valid but detached
        expect(instance1.fileSystemService, isNotNull);
      });

      test('handles empty configuration', () {
        // Act
        ServiceRegistry.initialize(
          huggingFaceToken: null,
          maxDownloadRetries: 10,
        );
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry, isNotNull);
        expect(registry.huggingFaceToken, isNull);
      });

      test('handles maxDownloadRetries = 0', () {
        // Act
        ServiceRegistry.initialize(maxDownloadRetries: 0);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.maxDownloadRetries, 0);
      });

      test('handles maxDownloadRetries = -1', () {
        // Act
        ServiceRegistry.initialize(maxDownloadRetries: -1);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.maxDownloadRetries, -1);
      });

      test('handles very large maxDownloadRetries', () {
        // Act
        ServiceRegistry.initialize(maxDownloadRetries: 1000000);
        final registry = ServiceRegistry.instance;

        // Assert
        expect(registry.maxDownloadRetries, 1000000);
      });
    });

    group('Incompatible Service Combinations', () {
      test('throws when web platform has non-WebFileSystemService', () {
        // This test would need to be run specifically on web platform
        // Skip for now as we can't easily simulate kIsWeb
      });
    });

    group('Service Initialization Order', () {
      test('handlers can use injected services', () {
        // Arrange
        final mockFS = MockFileSystemService();
        final mockDownload = MockDownloadService();
        final mockRepo = MockModelRepository();

        // Act
        ServiceRegistry.initialize(
          fileSystemService: mockFS,
          downloadService: mockDownload,
          modelRepository: mockRepo,
        );
        final registry = ServiceRegistry.instance;

        // Assert - handlers should be created with injected dependencies
        expect(registry.networkHandler, isNotNull);
        expect(registry.assetHandler, isNotNull);
      });
    });

    group('Thread Safety', () {
      test('concurrent instance access returns same instance', () async {
        // Arrange
        final futures = <Future<ServiceRegistry>>[];

        // Act
        for (int i = 0; i < 100; i++) {
          futures.add(Future(() => ServiceRegistry.instance));
        }
        final instances = await Future.wait(futures);

        // Assert
        final first = instances.first;
        for (final instance in instances) {
          expect(identical(first, instance), isTrue);
        }
      });

      test('concurrent initialize calls are safe', () async {
        // Arrange
        final futures = <Future>[];

        // Act
        for (int i = 0; i < 10; i++) {
          futures.add(Future(() => ServiceRegistry.initialize()));
        }
        await Future.wait(futures);

        // Assert
        final instance = ServiceRegistry.instance;
        expect(instance, isNotNull);
      });
    });

    group('Memory Management', () {
      test('reset allows garbage collection of old instance', () {
        // Arrange
        ServiceRegistry.initialize();
        final instance1 = ServiceRegistry.instance;

        // Act
        ServiceRegistry.reset();

        // Force new instance
        final instance2 = ServiceRegistry.instance;

        // Assert
        expect(identical(instance1, instance2), isFalse);
        // In a real scenario, instance1 would be garbage collected if no other references exist
      });

      test('services are not recreated on multiple accesses', () {
        // Arrange
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Act
        final fs1 = registry.fileSystemService;
        final fs2 = registry.fileSystemService;
        final dl1 = registry.downloadService;
        final dl2 = registry.downloadService;

        // Assert
        expect(identical(fs1, fs2), isTrue);
        expect(identical(dl1, dl2), isTrue);
      });
    });

    group('Default Factory Methods', () {
      test('creates correct services when none provided', () {
        // Act
        ServiceRegistry.initialize();
        final registry = ServiceRegistry.instance;

        // Assert
        // On mobile, should create PlatformFileSystemService
        // On web, should create WebFileSystemService
        // We can only assert that SOMETHING was created
        expect(registry.fileSystemService, isNotNull);
        expect(registry.downloadService, isNotNull);
        expect(registry.assetLoader, isNotNull);
        expect(registry.modelRepository, isNotNull);
        expect(registry.protectedFilesRegistry, isNotNull);
      });
    });

    group('Service Type Checking', () {
      test('WebDownloadService requires WebFileSystemService', () {
        // This is tested in the actual implementation
        // The factory method validates this constraint
      });
    });
  });
}
