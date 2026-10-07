// Unit test for the builtIn install pipeline (Task 2).
//
// Verifies that FlutterEdgeAi.installModel(... fileType: ModelFileType.builtIn)
// skips SourceHandlers/ModelRepository entirely, persists the active
// inference identity, and rejects a configured LoRA source.
//
// Run: flutter test test/core/builtin_install_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('builtIn install pipeline', () {
    test('builtIn install skips handlers and persists identity', () async {
      final installation = await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.builtIn,
      ).fromBundled('gemini-nano').install();

      expect(installation.fileType, ModelFileType.builtIn);
      expect(installation.modelId, 'gemini-nano');

      final prefs = await SharedPreferences.getInstance();
      await Future<void>.delayed(Duration.zero);
      final identity = ActiveIdentityStore.read(
        prefs,
        ActiveIdentityKind.inference,
      )!;
      expect(identity[PreferencesKeys.activeInferenceFileType], 'builtIn');
      expect(identity[PreferencesKeys.activeInferenceFilename], 'gemini-nano');
      expect(
        identity[PreferencesKeys.activeInferenceSource],
        'bundled|gemini-nano',
      );
    });

    test('builtIn install with LoRA throws ArgumentError', () async {
      expect(
        () =>
            FlutterEdgeAi.installModel(
                  modelType: ModelType.general,
                  fileType: ModelFileType.builtIn,
                )
                .fromBundled('gemini-nano')
                .withLora(ModelSource.file('/tmp/l.bin'))
                .install(),
        throwsArgumentError,
      );
    });
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
