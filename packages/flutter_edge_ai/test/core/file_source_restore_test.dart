// Restoring a model that was installed from a file the app owns
// (`installModel(...).fromFile(path)`, `installStt(...).fromFile(...)`).
//
// A FileSource install is used in place — nothing is copied into core's model
// directory. A restore that looks only in that directory finds nothing and
// starts the app with no active model, although the file never moved. The
// embedding and TTS restores already read the persisted source; these cover
// the inference and STT ones.
//
// Run: flutter test test/core/file_source_restore_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory external;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fe_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fe_support_');
    external = await Directory.systemTemp.createTemp('fe_external_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    ServiceRegistry.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, external]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  /// Writes [fields] as the persisted identity of [kind], then boots core the
  /// way a restarted app does. [beforeRestore] runs once core's services exist
  /// and before the manager restores, so it can place a file where core looks.
  Future<ModelFileManager> restart(
    ActiveIdentityKind kind,
    Map<String, String> fields, {
    Future<void> Function()? beforeRestore,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await ActiveIdentityStore.write(prefs, kind, fields);
    await ServiceRegistry.initialize();
    await beforeRestore?.call();
    // A fresh manager per restart: the plugin's own is created once per
    // process, and it restores only on its first initialization.
    final manager = MobileModelManager();
    await manager.ensureInitialized();
    return manager;
  }

  group('inference', () {
    test('a model used in place is restored from where it lives', () async {
      final file = File('${external.path}/picked-model.task')
        ..writeAsStringSync('weights');

      final manager = await restart(ActiveIdentityKind.inference, {
        PreferencesKeys.activeInferenceModelType: ModelType.gemmaIt.name,
        PreferencesKeys.activeInferenceFileType: ModelFileType.task.name,
        PreferencesKeys.activeInferenceFilename: 'picked-model.task',
        PreferencesKeys.activeInferenceSource: FileSource(file.path).encode(),
      });

      final spec = manager.activeInferenceModel as InferenceModelSpec?;
      expect(spec, isNotNull, reason: 'the file is still there');
      expect(spec!.modelSource, FileSource(file.path));
      expect(spec.modelType, ModelType.gemmaIt);
      expect(spec.fileType, ModelFileType.task);
    });

    test('a file used in place that is gone restores nothing', () async {
      final manager = await restart(ActiveIdentityKind.inference, {
        PreferencesKeys.activeInferenceModelType: ModelType.gemmaIt.name,
        PreferencesKeys.activeInferenceFileType: ModelFileType.task.name,
        PreferencesKeys.activeInferenceFilename: 'gone.task',
        PreferencesKeys.activeInferenceSource: FileSource(
          '${external.path}/gone.task',
        ).encode(),
      });

      expect(manager.activeInferenceModel, isNull);
    });

    test(
      'a downloaded model is still restored from core\'s directory',
      () async {
        late String target;
        final manager = await restart(
          ActiveIdentityKind.inference,
          {
            PreferencesKeys.activeInferenceModelType: ModelType.gemmaIt.name,
            PreferencesKeys.activeInferenceFileType: ModelFileType.task.name,
            PreferencesKeys.activeInferenceFilename: 'downloaded.task',
            PreferencesKeys.activeInferenceSource: NetworkSource(
              'https://example.com/downloaded.task',
            ).encode(),
          },
          beforeRestore: () async {
            target = await ServiceRegistry.instance.fileSystemService
                .getReadTargetPath('downloaded.task');
            File(target)
              ..createSync(recursive: true)
              ..writeAsStringSync('weights');
          },
        );

        final spec = manager.activeInferenceModel as InferenceModelSpec?;
        expect(spec, isNotNull);
        expect(spec!.modelSource, FileSource(target));
      },
    );
  });

  group('stt', () {
    test('a model and tokenizer used in place are restored from where they '
        'live', () async {
      final model = File('${external.path}/picked-stt.tflite')
        ..writeAsStringSync('weights');
      final tokenizer = File('${external.path}/picked-stt-tokenizer.json')
        ..writeAsStringSync('{}');

      final manager = await restart(ActiveIdentityKind.stt, {
        PreferencesKeys.activeSttFilename: 'picked-stt.tflite',
        PreferencesKeys.activeSttTokenizerFilename: 'picked-stt-tokenizer.json',
        PreferencesKeys.activeSttModelType: SttModelType.moonshine.name,
        PreferencesKeys.activeSttSource: FileSource(model.path).encode(),
        PreferencesKeys.activeSttTokenizerSource: FileSource(
          tokenizer.path,
        ).encode(),
      });

      final spec = manager.activeSttModel as SttModelSpec?;
      expect(spec, isNotNull, reason: 'both files are still there');
      expect(spec!.modelSource, FileSource(model.path));
      expect(spec.tokenizerSource, FileSource(tokenizer.path));
    });
  });
}

/// PathProviderPlatform stub with fixed, distinct Documents and
/// ApplicationSupport paths.
class _FixedPathProviderPlatform extends PathProviderPlatform {
  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  final String documentsPath;
  final String appSupportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}
