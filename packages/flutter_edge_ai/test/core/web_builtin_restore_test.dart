@TestOn('browser')
library;

// Web-arm counterpart of `builtin_restore_test.dart` (which only exercises
// MobileModelManager, since flutter_edge_ai_default_web.dart makes
// FlutterEdgeAiPlugin.instance unusable outside a real plugin registration on
// web). Proves the WebModelManager._restoreActiveInferenceModel() builtIn
// early-return fix: without it, a restored builtIn active model would be
// silently dropped on every page reload, because
// InferenceInstallationBuilder.install() never calls
// repository.saveModel() for fileType.builtIn (no SourceHandler is invoked),
// so the pre-fix `repo.isInstalled(filename)` gate would always read false.
//
// Run: flutter test --platform chrome test/core/web_builtin_restore_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

void main() {
  setUp(() {
    ServiceRegistry.reset();
  });

  tearDown(() {
    ServiceRegistry.reset();
  });

  test('a builtIn active model survives a page reload even though it was never '
      'saved to the ModelRepository (fileType.builtIn install bypasses '
      'SourceHandlers entirely)', () async {
    SharedPreferences.setMockInitialValues({
      'active_inference_model_type': 'general',
      'active_inference_file_type': 'builtIn',
      'active_inference_filename': 'gemini-nano',
      'active_inference_source': 'bundled|gemini-nano',
    });

    await ServiceRegistry.initialize();
    final manager = WebModelManager();
    await manager.ensureInitialized();

    final spec = manager.activeInferenceModel as InferenceModelSpec;
    expect(spec.fileType, ModelFileType.builtIn);
    expect(spec.modelSource, BundledSource('gemini-nano'));
    expect(spec.name, 'gemini-nano');
  });

  test('a non-builtIn active model with no installed file is correctly '
      'skipped on restore (regression guard for the builtIn early-return: it '
      'must not swallow the normal isInstalled gate for real files)', () async {
    SharedPreferences.setMockInitialValues({
      'active_inference_model_type': 'general',
      'active_inference_file_type': 'task',
      'active_inference_filename': 'not-actually-installed.task',
      'active_inference_source': 'network|https://example.com/m.task',
    });

    await ServiceRegistry.initialize();
    final manager = WebModelManager();
    await manager.ensureInitialized();

    expect(manager.activeInferenceModel, isNull);
  });

  test('downloadModelWithProgress treats a builtIn spec as a fileless identity '
      'install (no SourceHandler fetch of a nonexistent resource)', () async {
    await ServiceRegistry.initialize();
    final manager = WebModelManager();
    await manager.ensureInitialized();

    final spec = InferenceModelSpec(
      name: 'gemini-nano',
      modelSource: BundledSource('gemini-nano'),
      modelType: ModelType.general,
      fileType: ModelFileType.builtIn,
    );

    // Before the fix a builtIn spec fell into the per-file handler loop and the
    // bundled handler tried to fetch '/gemini-nano'; now it short-circuits to
    // setActiveModel + a single 100% progress event, like ONNX.
    final progress = await manager.downloadModelWithProgress(spec).toList();
    expect(progress, isNotEmpty);
    expect(progress.last.currentFileProgress, 100);
    final active = manager.activeInferenceModel as InferenceModelSpec;
    expect(active.fileType, ModelFileType.builtIn);
    expect(active.name, 'gemini-nano');
  });
}
