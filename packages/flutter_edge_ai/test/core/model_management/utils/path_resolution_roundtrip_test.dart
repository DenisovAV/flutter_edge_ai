// Unit test for the desktop install/validate path-mismatch fix.
//
// Verifies that PlatformFileSystemService.getReadTargetPath() and
// getModelStorageDirectory() return consistent paths, and that
// ModelFileSystemManager.getModelFilePath() delegates through them
// rather than calling getApplicationDocumentsDirectory() directly.
//
// Run: flutter test test/core/model_management/utils/path_resolution_roundtrip_test.dart

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/infrastructure/platform_file_system_service.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show ModelFileSystemManager;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Use real temp dirs (in /tmp on Unix, %TEMP% on Windows) so the code under
  // test can actually mkdir them. The dirs are distinct so the legacy fallback
  // branch is exercisable.
  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late _FixedPathProviderPlatform mockProvider;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    mockProvider = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    PathProviderPlatform.instance = mockProvider;
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    if (await fakeDocuments.exists()) {
      await fakeDocuments.delete(recursive: true);
    }
    if (await fakeAppSupport.exists()) {
      await fakeAppSupport.delete(recursive: true);
    }
  });

  group('PlatformFileSystemService path resolution', () {
    test(
      'getReadTargetPath returns path under the canonical storage directory',
      () async {
        final service = PlatformFileSystemService();
        final targetPath = await service.getReadTargetPath('foo.litertlm');
        final storageDir = await service.getModelStorageDirectory();

        // The file path must be inside the storage dir.
        expect(targetPath, startsWith(storageDir));
        expect(p.basename(targetPath), 'foo.litertlm');
      },
    );

    test('getModelStorageDirectory matches getReadTargetPath parent', () async {
      final service = PlatformFileSystemService();
      final targetPath = await service.getReadTargetPath('model.bin');
      final storageDir = await service.getModelStorageDirectory();

      expect(p.dirname(targetPath), storageDir);
    });

    test('read path on mobile-like platforms uses Documents dir', () async {
      // On the host (macOS / Linux / Windows) this test exercises the desktop
      // branch. On a real Android/iOS device it would hit the mobile branch.
      // Both branches must place the file inside the reported storageDir.
      final service = PlatformFileSystemService();
      final storageDir = await service.getModelStorageDirectory();
      final targetPath = await service.getReadTargetPath('test.bin');

      expect(targetPath, equals(p.join(storageDir, 'test.bin')));
    });

    test(
      'legacy Documents fallback emits debug log and returns legacy path',
      () async {
        // Only desktop platforms execute the legacy probe; skip on mobile.
        if (Platform.isAndroid || Platform.isIOS) return;

        // Arrange: write a file to the "legacy Documents" location so that the
        // fallback probe in getReadTargetPath finds it. The "new" location at
        // <appSupport>/flutter_edge_ai/old_model.litertlm is left empty so the
        // probe fires.
        final legacyFile = File(
          p.join(fakeDocuments.path, 'old_model.litertlm'),
        );
        legacyFile.writeAsStringSync('placeholder');

        final service = PlatformFileSystemService();

        // Capture debugPrint output.
        final logs = <String>[];
        final originalDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logs.add(message);
        };

        try {
          final resultPath = await service.getReadTargetPath(
            'old_model.litertlm',
          );
          expect(
            resultPath,
            equals(legacyFile.path),
            reason: 'Should fall back to legacy Documents path',
          );
          expect(
            logs.any((l) => l.contains('legacy Documents path')),
            isTrue,
            reason: 'Should emit debug log nudging re-install',
          );
        } finally {
          debugPrint = originalDebugPrint;
        }
      },
    );

    test('getModelStorageDirectory is consistent across two calls', () async {
      final service = PlatformFileSystemService();
      final dir1 = await service.getModelStorageDirectory();
      final dir2 = await service.getModelStorageDirectory();
      expect(dir1, equals(dir2));
    });
  });

  group('ModelFileSystemManager round-trip through FileSystemService', () {
    test(
      'getModelFilePath delegates through ServiceRegistry.fileSystemService',
      () async {
        // Initialize ServiceRegistry with a real PlatformFileSystemService so
        // the delegation chain is exercised end-to-end.
        await ServiceRegistry.initialize(
          fileSystemService: PlatformFileSystemService(),
        );
        final service = ServiceRegistry.instance.fileSystemService;

        final resolved = await ModelFileSystemManager.getModelFilePath(
          'roundtrip.bin',
        );

        expect(resolved, await service.getReadTargetPath('roundtrip.bin'));
        final storageDir = await service.getModelStorageDirectory();
        expect(resolved, startsWith(storageDir));
        expect(p.basename(resolved), 'roundtrip.bin');
      },
    );

    test(
      'getModelFilePath resolves the read path, not the write path',
      () async {
        // Only desktop platforms probe the legacy Documents location.
        if (Platform.isAndroid || Platform.isIOS) return;

        // A pre-0.15.1 install left in Documents: the read path finds it there,
        // while the write path stays in the canonical storage directory. That
        // is the one case where the two differ, so it tells them apart.
        final legacyFile = File(p.join(fakeDocuments.path, 'legacy.litertlm'));
        legacyFile.writeAsStringSync('placeholder');
        await ServiceRegistry.initialize(
          fileSystemService: PlatformFileSystemService(),
        );
        final service = ServiceRegistry.instance.fileSystemService;
        expect(
          await service.getWriteTargetPath('legacy.litertlm'),
          isNot(legacyFile.path),
        );

        expect(
          await ModelFileSystemManager.getModelFilePath('legacy.litertlm'),
          legacyFile.path,
        );
      },
    );
  });
}

/// PathProviderPlatform stub that returns fixed, distinct paths for
/// Documents and ApplicationSupport so tests can distinguish them.
class _FixedPathProviderPlatform extends PathProviderPlatform {
  final String documentsPath;
  final String appSupportPath;

  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}
