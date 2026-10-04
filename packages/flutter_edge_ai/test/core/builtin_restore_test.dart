// Unit test for restoring a builtIn active model across an app restart
// (Task 3).
//
// A builtIn model (e.g. Gemini Nano / Apple Foundation Models) has NO file on
// disk — the OS owns the model/template. Restore must reconstruct the
// InferenceModelSpec from persisted identity alone, without ever touching
// File(...).existsSync().
//
// Run: flutter test test/core/builtin_restore_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
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

  group('builtIn restore-after-restart', () {
    test(
      'builtIn active model survives restart without a file on disk',
      () async {
        SharedPreferences.setMockInitialValues({
          'active_inference_model_type': 'general',
          'active_inference_file_type': 'builtIn',
          'active_inference_filename': 'gemini-nano',
          'active_inference_source': 'bundled|gemini-nano',
        });

        // Simulate app restart: ServiceRegistry boots fresh, then the model
        // manager restores the previously-active model identity from prefs.
        await ServiceRegistry.initialize();
        final manager = FlutterEdgeAiPlugin.instance.modelManager;
        await manager.ensureInitialized();

        final spec = manager.activeInferenceModel as InferenceModelSpec;
        expect(spec.fileType, ModelFileType.builtIn);
        expect(spec.modelSource, BundledSource('gemini-nano'));
        expect(spec.name, 'gemini-nano');
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
