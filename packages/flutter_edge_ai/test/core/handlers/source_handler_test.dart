import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/handlers/network_source_handler.dart';
import 'package:flutter_edge_ai/core/handlers/asset_source_handler.dart';
import 'package:flutter_edge_ai/core/handlers/bundled_source_handler.dart';
import 'package:flutter_edge_ai/core/handlers/file_source_handler.dart';
import 'package:flutter_edge_ai/core/handlers/source_handler_registry.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/services/file_system_service.dart';
import 'package:flutter_edge_ai/core/services/asset_loader.dart';
import 'package:flutter_edge_ai/core/services/protected_files_registry.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';

// Mock implementations
class MockDownloadService extends Mock implements DownloadService {}

class MockFileSystemService extends Mock implements FileSystemService {}

class MockAssetLoader extends Mock implements AssetLoader {}

class MockProtectedFilesRegistry extends Mock
    implements ProtectedFilesRegistry {}

class MockModelRepository extends Mock implements ModelRepository {}

// Fake for ModelInfo
class FakeModelInfo extends Fake implements ModelInfo {
  @override
  String get id => 'test-model';

  @override
  ModelSource get source => NetworkSource('https://example.com/model.bin');

  @override
  DateTime get installedAt => DateTime(2025, 1, 1);

  @override
  int get sizeBytes => 1024;

  @override
  ModelType get type => ModelType.inference;

  @override
  bool get hasLoraWeights => false;
}

void main() {
  // Register fallback values for mocktail
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(NetworkSource('https://example.com/model.bin'));
    registerFallbackValue(AssetSource('models/test.bin'));
    registerFallbackValue(FileSource('/tmp/test.bin'));
    registerFallbackValue(FakeModelInfo());
  });

  group('NetworkSourceHandler', () {
    late NetworkSourceHandler handler;
    late MockDownloadService mockDownloadService;
    late MockFileSystemService mockFileSystem;
    late MockModelRepository mockRepository;

    setUp(() {
      mockDownloadService = MockDownloadService();
      mockFileSystem = MockFileSystemService();
      mockRepository = MockModelRepository();
      handler = NetworkSourceHandler(
        downloadService: mockDownloadService,
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
    });

    test('supports NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      expect(handler.supports(source), isTrue);
    });

    test('does not support AssetSource', () {
      final source = AssetSource('models/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support BundledSource', () {
      final source = BundledSource('test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support FileSource', () {
      final source = FileSource('/tmp/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('install downloads file and saves metadata', () async {
      final source = NetworkSource('https://example.com/model.bin');
      const targetPath = '/data/model.bin';

      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockDownloadService.download(
          any(),
          any(),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 1024);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      verify(
        () => mockDownloadService.download(source.url, targetPath, token: null),
      ).called(1);
      verify(() => mockRepository.saveModel(any())).called(1);
    });

    test(
      'install honors targetFilename override for write path and ModelInfo.id',
      () async {
        final source = NetworkSource('https://example.com/model.bin');
        const targetPath = '/data/moonshine-tiny__model.bin';

        when(
          () => mockFileSystem.getWriteTargetPath('moonshine-tiny__model.bin'),
        ).thenAnswer((_) async => targetPath);
        when(
          () => mockDownloadService.download(
            any(),
            any(),
            token: any(named: 'token'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockFileSystem.getFileSize(targetPath),
        ).thenAnswer((_) async => 2048);
        when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

        await handler.install(
          source,
          targetFilename: 'moonshine-tiny__model.bin',
        );

        verify(
          () => mockFileSystem.getWriteTargetPath('moonshine-tiny__model.bin'),
        ).called(1);
        final captured = verify(
          () => mockRepository.saveModel(captureAny()),
        ).captured;
        final savedInfo = captured.single as ModelInfo;
        expect(savedInfo.id, 'moonshine-tiny__model.bin');
      },
    );

    test('threads modelType into the saved ModelInfo.type (#391)', () async {
      final source = NetworkSource('https://example.com/model.bin');
      const targetPath = '/data/model.bin';
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockDownloadService.download(
          any(),
          any(),
          token: any(named: 'token'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(targetPath),
      ).thenAnswer((_) async => 2048);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      // Default is inference; an explicit type must reach ModelInfo.type
      // (getInstalledModels(stt/tts/embedding) filters on exactly this).
      await handler.install(source);
      await handler.install(source, modelType: ModelType.stt);

      final saved = verify(
        () => mockRepository.saveModel(captureAny()),
      ).captured.cast<ModelInfo>();
      expect(saved[0].type, ModelType.inference);
      expect(saved[1].type, ModelType.stt);
    });

    test('installWithProgress tracks download progress', () async {
      final source = NetworkSource('https://example.com/model.bin');
      const targetPath = '/data/model.bin';
      final progressStream = Stream<int>.fromIterable([0, 25, 50, 75, 100]);

      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockDownloadService.downloadWithProgress(
          any(),
          any(),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) => progressStream);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 1024);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      final progress = await handler.installWithProgress(source).toList();

      expect(progress, [0, 25, 50, 75, 100]);
      verify(
        () => mockDownloadService.downloadWithProgress(
          source.url,
          targetPath,
          token: null,
        ),
      ).called(1);
    });

    test('supportsResume returns true for NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      expect(handler.supportsResume(source), isTrue);
    });

    test('handles HuggingFace URLs with authentication', () async {
      final source = NetworkSource('https://huggingface.co/models/test.bin');
      const targetPath = '/data/model.bin';

      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockDownloadService.download(
          any(),
          any(),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 1024);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      // Should pass HuggingFace token if available
      verify(
        () => mockDownloadService.download(
          source.url,
          targetPath,
          token: any(named: 'token'),
        ),
      ).called(1);
    });

    test(
      'install throws and does NOT save metadata when no file landed at '
      'targetPath (0 bytes) — the Windows mis-landing silent failure',
      () async {
        final source = NetworkSource('https://example.com/model.bin');
        const targetPath = '/data/model.bin';
        when(
          () => mockFileSystem.getWriteTargetPath(any()),
        ).thenAnswer((_) async => targetPath);
        when(
          () => mockDownloadService.download(
            any(),
            any(),
            token: any(named: 'token'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockFileSystem.getFileSize(any()),
        ).thenAnswer((_) async => 0);
        when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

        await expectLater(handler.install(source), throwsA(isA<StateError>()));
        verifyNever(() => mockRepository.saveModel(any()));
      },
    );

    test('installWithProgress throws and does NOT save metadata when no file '
        'landed at targetPath (0 bytes)', () async {
      final source = NetworkSource('https://example.com/model.bin');
      const targetPath = '/data/model.bin';
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockDownloadService.downloadWithProgress(
          any(),
          any(),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) => Stream<int>.value(100));
      when(() => mockFileSystem.getFileSize(any())).thenAnswer((_) async => 0);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await expectLater(
        handler.installWithProgress(source).toList(),
        throwsA(isA<StateError>()),
      );
      verifyNever(() => mockRepository.saveModel(any()));
    });
  });

  group('AssetSourceHandler', () {
    late AssetSourceHandler handler;
    late MockAssetLoader mockAssetLoader;
    late MockFileSystemService mockFileSystem;
    late MockModelRepository mockRepository;

    setUp(() {
      mockAssetLoader = MockAssetLoader();
      mockFileSystem = MockFileSystemService();
      mockRepository = MockModelRepository();
      handler = AssetSourceHandler(
        assetLoader: mockAssetLoader,
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
    });

    test('supports AssetSource', () {
      final source = AssetSource('models/test.bin');
      expect(handler.supports(source), isTrue);
    });

    test('does not support NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support BundledSource', () {
      final source = BundledSource('test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support FileSource', () {
      final source = FileSource('/tmp/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('install copies asset to app directory', () async {
      final source = AssetSource('models/test.bin');
      const targetPath = '/data/model.bin';
      final assetData = Uint8List.fromList([1, 2, 3, 4]);

      when(
        () => mockAssetLoader.loadAsset(any()),
      ).thenAnswer((_) async => assetData);
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockFileSystem.writeFile(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => assetData.length);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      // AssetSourceHandler uses normalizedPath (with assets/ prefix) for the
      // generic loadAsset path — matches Flutter rootBundle's expected key
      // format. The native large_file_handler path uses pathForLookupKey
      // separately (see #250 Mode 2 fix).
      verify(() => mockAssetLoader.loadAsset(source.normalizedPath)).called(1);
      verify(() => mockFileSystem.writeFile(targetPath, assetData)).called(1);
      verify(() => mockRepository.saveModel(any())).called(1);
    });

    test('installWithProgress reports single 100% progress', () async {
      final source = AssetSource('models/test.bin');
      const targetPath = '/data/model.bin';
      final assetData = Uint8List.fromList([1, 2, 3, 4]);

      when(
        () => mockAssetLoader.loadAsset(any()),
      ).thenAnswer((_) async => assetData);
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockFileSystem.writeFile(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => assetData.length);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      final progress = await handler.installWithProgress(source).toList();

      expect(progress, [100]);
    });

    test('supportsResume returns false for AssetSource', () {
      final source = AssetSource('models/test.bin');
      expect(handler.supportsResume(source), isFalse);
    });

    test('handles asset paths with and without assets/ prefix', () async {
      final source1 = AssetSource('models/test.bin');
      final source2 = AssetSource('assets/models/test.bin');
      const targetPath = '/data/model.bin';
      final assetData = Uint8List.fromList([1, 2, 3, 4]);

      when(
        () => mockAssetLoader.loadAsset(any()),
      ).thenAnswer((_) async => assetData);
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockFileSystem.writeFile(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => assetData.length);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source1);
      await handler.install(source2);

      // Both should normalize to 'assets/models/test.bin' for the loadAsset
      // (rootBundle) path. The native lookup key (without prefix) is used
      // separately on the large_file_handler path.
      verify(
        () => mockAssetLoader.loadAsset('assets/models/test.bin'),
      ).called(2);
    });

    test('install throws and does NOT save metadata when the copied asset is '
        '0 bytes', () async {
      final source = AssetSource('models/test.bin');
      const targetPath = '/data/model.bin';
      final assetData = Uint8List.fromList([1, 2, 3, 4]);
      when(
        () => mockAssetLoader.loadAsset(any()),
      ).thenAnswer((_) async => assetData);
      when(
        () => mockFileSystem.getWriteTargetPath(any()),
      ).thenAnswer((_) async => targetPath);
      when(
        () => mockFileSystem.writeFile(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockFileSystem.getFileSize(any())).thenAnswer((_) async => 0);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await expectLater(handler.install(source), throwsA(isA<StateError>()));
      verifyNever(() => mockRepository.saveModel(any()));
    });
  });

  group('BundledSourceHandler', () {
    late BundledSourceHandler handler;
    late MockFileSystemService mockFileSystem;
    late MockModelRepository mockRepository;

    setUp(() {
      mockFileSystem = MockFileSystemService();
      mockRepository = MockModelRepository();
      handler = BundledSourceHandler(
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
    });

    test('supports BundledSource', () {
      final source = BundledSource('test.bin');
      expect(handler.supports(source), isTrue);
    });

    test('does not support NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support AssetSource', () {
      final source = AssetSource('models/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support FileSource', () {
      final source = FileSource('/tmp/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('install gets bundled resource path and saves metadata', () async {
      final source = BundledSource('test.bin');
      const bundledPath = '/native/resources/test.bin';

      when(
        () => mockFileSystem.getBundledResourcePath(any()),
      ).thenAnswer((_) async => bundledPath);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 2048);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      verify(
        () => mockFileSystem.getBundledResourcePath(source.resourceName),
      ).called(1);
      verify(() => mockRepository.saveModel(any())).called(1);
    });

    test('installWithProgress reports single 100% progress', () async {
      final source = BundledSource('test.bin');
      const bundledPath = '/native/resources/test.bin';

      when(
        () => mockFileSystem.getBundledResourcePath(any()),
      ).thenAnswer((_) async => bundledPath);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 2048);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      final progress = await handler.installWithProgress(source).toList();

      expect(progress, [100]);
    });

    test('supportsResume returns false for BundledSource', () {
      final source = BundledSource('test.bin');
      expect(handler.supportsResume(source), isFalse);
    });

    test('handles platform-specific bundled paths', () async {
      // Android: assets/models/
      // iOS: Bundle.main
      // Web: /assets/
      final source = BundledSource('test.bin');
      const bundledPath = '/platform/specific/test.bin';

      when(
        () => mockFileSystem.getBundledResourcePath(any()),
      ).thenAnswer((_) async => bundledPath);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 2048);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      verify(
        () => mockFileSystem.getBundledResourcePath(source.resourceName),
      ).called(1);
    });
  });

  group('FileSourceHandler', () {
    late FileSourceHandler handler;
    late MockFileSystemService mockFileSystem;
    late MockProtectedFilesRegistry mockRegistry;
    late MockModelRepository mockRepository;

    setUp(() {
      mockFileSystem = MockFileSystemService();
      mockRegistry = MockProtectedFilesRegistry();
      mockRepository = MockModelRepository();
      handler = FileSourceHandler(
        fileSystem: mockFileSystem,
        protectedFiles: mockRegistry,
        repository: mockRepository,
      );
    });

    test('supports FileSource', () {
      final source = FileSource('/tmp/test.bin');
      expect(handler.supports(source), isTrue);
    });

    test('does not support NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support AssetSource', () {
      final source = AssetSource('models/test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('does not support BundledSource', () {
      final source = BundledSource('test.bin');
      expect(handler.supports(source), isFalse);
    });

    test('install registers external file and protects it', () async {
      final source = FileSource('/tmp/external/model.bin');

      when(
        () => mockFileSystem.fileExists(any()),
      ).thenAnswer((_) async => true);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 3072);
      when(
        () => mockFileSystem.registerExternalFile(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRegistry.protect(any())).thenAnswer((_) async {});
      when(
        () => mockRegistry.registerExternalPath(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      verify(() => mockFileSystem.fileExists(source.path)).called(1);
      verify(() => mockRegistry.protect(any())).called(1);
      verify(
        () => mockRegistry.registerExternalPath(any(), source.path),
      ).called(1);
      verify(() => mockRepository.saveModel(any())).called(1);
    });

    test('install throws if external file does not exist', () async {
      final source = FileSource('/tmp/nonexistent.bin');

      when(
        () => mockFileSystem.fileExists(any()),
      ).thenAnswer((_) async => false);

      expect(() => handler.install(source), throwsA(isA<Exception>()));

      verify(() => mockFileSystem.fileExists(source.path)).called(1);
      verifyNever(() => mockRegistry.protect(any()));
      verifyNever(() => mockRepository.saveModel(any()));
    });

    test('installWithProgress reports single 100% progress', () async {
      final source = FileSource('/tmp/external/model.bin');

      when(
        () => mockFileSystem.fileExists(any()),
      ).thenAnswer((_) async => true);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 3072);
      when(
        () => mockFileSystem.registerExternalFile(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRegistry.protect(any())).thenAnswer((_) async {});
      when(
        () => mockRegistry.registerExternalPath(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      final progress = await handler.installWithProgress(source).toList();

      expect(progress, [100]);
    });

    test('supportsResume returns false for FileSource', () {
      final source = FileSource('/tmp/test.bin');
      expect(handler.supportsResume(source), isFalse);
    });

    test('protects external file from cleanup operations', () async {
      final source = FileSource('/important/user/model.bin');

      when(
        () => mockFileSystem.fileExists(any()),
      ).thenAnswer((_) async => true);
      when(
        () => mockFileSystem.getFileSize(any()),
      ).thenAnswer((_) async => 4096);
      when(
        () => mockFileSystem.registerExternalFile(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRegistry.protect(any())).thenAnswer((_) async {});
      when(
        () => mockRegistry.registerExternalPath(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await handler.install(source);

      // File should be protected to prevent deletion during cleanup
      verify(() => mockRegistry.protect(any())).called(1);
      verify(
        () => mockRegistry.registerExternalPath(any(), source.path),
      ).called(1);
    });

    test('install throws and does NOT save metadata when the external file is '
        'present but 0 bytes', () async {
      final source = FileSource('/tmp/external/model.bin');
      when(
        () => mockFileSystem.fileExists(any()),
      ).thenAnswer((_) async => true);
      when(
        () => mockFileSystem.registerExternalFile(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockRegistry.protect(any())).thenAnswer((_) async {});
      when(
        () => mockRegistry.registerExternalPath(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockFileSystem.getFileSize(any())).thenAnswer((_) async => 0);
      when(() => mockRepository.saveModel(any())).thenAnswer((_) async {});

      await expectLater(handler.install(source), throwsA(isA<StateError>()));
      verifyNever(() => mockRepository.saveModel(any()));
    });
  });

  group('SourceHandlerRegistry', () {
    late SourceHandlerRegistry registry;
    late MockDownloadService mockDownloadService;
    late MockFileSystemService mockFileSystem;
    late MockAssetLoader mockAssetLoader;
    late MockProtectedFilesRegistry mockProtectedFiles;
    late MockModelRepository mockRepository;

    setUp(() {
      mockDownloadService = MockDownloadService();
      mockFileSystem = MockFileSystemService();
      mockAssetLoader = MockAssetLoader();
      mockProtectedFiles = MockProtectedFilesRegistry();
      mockRepository = MockModelRepository();

      final networkHandler = NetworkSourceHandler(
        downloadService: mockDownloadService,
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
      final assetHandler = AssetSourceHandler(
        assetLoader: mockAssetLoader,
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
      final bundledHandler = BundledSourceHandler(
        fileSystem: mockFileSystem,
        repository: mockRepository,
      );
      final fileHandler = FileSourceHandler(
        fileSystem: mockFileSystem,
        protectedFiles: mockProtectedFiles,
        repository: mockRepository,
      );

      registry = SourceHandlerRegistry(
        handlers: [networkHandler, assetHandler, bundledHandler, fileHandler],
      );
    });

    test('finds handler for NetworkSource', () {
      final source = NetworkSource('https://example.com/model.bin');
      final handler = registry.getHandler(source);

      expect(handler, isNotNull);
      expect(handler!.supports(source), isTrue);
    });

    test('finds handler for AssetSource', () {
      final source = AssetSource('models/test.bin');
      final handler = registry.getHandler(source);

      expect(handler, isNotNull);
      expect(handler!.supports(source), isTrue);
    });

    test('finds handler for BundledSource', () {
      final source = BundledSource('test.bin');
      final handler = registry.getHandler(source);

      expect(handler, isNotNull);
      expect(handler!.supports(source), isTrue);
    });

    test('finds handler for FileSource', () {
      final source = FileSource('/tmp/test.bin');
      final handler = registry.getHandler(source);

      expect(handler, isNotNull);
      expect(handler!.supports(source), isTrue);
    });

    test(
      'returns first matching handler when multiple support same source',
      () {
        // If multiple handlers claim to support a source, first one wins
        final source = NetworkSource('https://example.com/model.bin');
        final handler = registry.getHandler(source);

        expect(handler, isNotNull);
        expect(handler, isA<NetworkSourceHandler>());
      },
    );
  });
}
