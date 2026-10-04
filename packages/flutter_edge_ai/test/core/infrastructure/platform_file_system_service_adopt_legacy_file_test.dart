import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:flutter_edge_ai/core/infrastructure/platform_file_system_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late PlatformFileSystemService service;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    service = PlatformFileSystemService();
  });

  tearDown(() async {
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  group('PlatformFileSystemService.adoptLegacyFile', () {
    test(
      'renames an existing old flat file to the new namespaced name',
      () async {
        final oldPath = await service.getWriteTargetPath(
          'matcha_textenc_fp16.tflite',
        );
        await File(oldPath).writeAsBytes([1, 2, 3, 4]);

        final adopted = await service.adoptLegacyFile(
          'matcha_textenc_fp16.tflite',
          'matcha__matcha_textenc_fp16.tflite',
        );

        expect(adopted, isTrue);
        expect(await File(oldPath).exists(), isFalse);
        final newPath = await service.getWriteTargetPath(
          'matcha__matcha_textenc_fp16.tflite',
        );
        expect(await File(newPath).exists(), isTrue);
        expect(await File(newPath).readAsBytes(), [1, 2, 3, 4]);
      },
    );

    test('returns false when there is no old file to adopt', () async {
      final adopted = await service.adoptLegacyFile(
        'nonexistent.tflite',
        'matcha__nonexistent.tflite',
      );
      expect(adopted, isFalse);
    });

    test('returns false and touches nothing when old == new', () async {
      final adopted = await service.adoptLegacyFile(
        'model.tflite',
        'model.tflite',
      );
      expect(adopted, isFalse);
    });

    test('returns false when the new file already exists', () async {
      final newPath = await service.getWriteTargetPath('matcha__config.json');
      await File(newPath).writeAsBytes([9]);
      final oldPath = await service.getWriteTargetPath('config.json');
      await File(oldPath).writeAsBytes([1]);

      final adopted = await service.adoptLegacyFile(
        'config.json',
        'matcha__config.json',
      );

      expect(adopted, isFalse);
      // Neither file was touched.
      expect(await File(newPath).readAsBytes(), [9]);
      expect(await File(oldPath).exists(), isTrue);
    });
  });
}

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
