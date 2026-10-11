// Models installed from a file the app owns (`fromFile`) across a restart and
// an uninstall.
//
// A FileSource install is used in place: nothing is copied into core's model
// directory, and the file stays the app's. After a restart core must find it
// where it was installed from, and no uninstall or model switch may delete it.
//
// Run: flutter test test/core/file_source_restore_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager, ModelFileSystemManager;

/// Over the 1 MB floor install validation applies to model files.
final _modelBytes = Uint8List(1024 * 1024 + 1);

/// Over the floor for small companions (tokenizers).
final _tokenizerBytes = Uint8List(2048);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory userDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeDocuments = await Directory.systemTemp.createTemp('fe_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fe_support_');
    userDir = await Directory.systemTemp.createTemp('fe_user_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, userDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  File userFile(String name, Uint8List bytes) =>
      File('${userDir.path}/$name')..writeAsBytesSync(bytes);

  /// A new manager restores from what the previous run persisted, the way a
  /// restarted app does. The plugin's own manager restores only once per
  /// process, so it cannot stand in for a restart.
  Future<MobileModelManager> restart() async {
    final manager = MobileModelManager();
    await manager.initialize();
    return manager;
  }

  Future<SttModelSpec> installStt(File model, File tokenizer) async =>
      (await FlutterEdgeAi.installStt()
              .modelFromFile(model.path)
              .tokenizerFromFile(tokenizer.path)
              .ofType(SttModelType.moonshine)
              .install())
          .spec;

  group('inference', () {
    test('a fromFile model is active and installed after a restart', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(model.path).install();

      final restarted = await restart();

      final spec = restarted.activeInferenceModel as InferenceModelSpec?;
      expect(spec, isNotNull, reason: 'the file is still there');
      expect(spec!.modelSource, FileSource(model.path));
      expect(spec.modelType, ModelType.gemmaIt);
      expect(spec.fileType, ModelFileType.task);
      expect(await restarted.isModelInstalled(spec), isTrue);
    });

    test('a fromFile model whose file is gone restores nothing', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(model.path).install();
      model.deleteSync();

      final restarted = await restart();

      expect(restarted.activeInferenceModel, isNull);
    });

    test(
      'a downloaded model is still restored from core\'s directory',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await ActiveIdentityStore.write(prefs, ActiveIdentityKind.inference, {
          PreferencesKeys.activeInferenceModelType: ModelType.gemmaIt.name,
          PreferencesKeys.activeInferenceFileType: ModelFileType.task.name,
          PreferencesKeys.activeInferenceFilename: 'downloaded.task',
          PreferencesKeys.activeInferenceSource: NetworkSource(
            'https://example.com/downloaded.task',
          ).encode(),
        });
        final target = await ServiceRegistry.instance.fileSystemService
            .getReadTargetPath('downloaded.task');
        File(target)
          ..createSync(recursive: true)
          ..writeAsBytesSync(_modelBytes);

        final restarted = await restart();

        final spec = restarted.activeInferenceModel as InferenceModelSpec?;
        expect(spec, isNotNull);
        expect(spec!.modelSource, FileSource(target));
      },
    );

    test('an identity in the per-field form of older releases does not have '
        'its source trusted', () async {
      // Older releases wrote one key per field, so an interrupted write could
      // leave one model's filename next to another model's source. Restoring
      // that source would load the other model under this one's type.
      final other = userFile('qwen.task', _modelBytes);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeInferenceModelType,
        ModelType.gemmaIt.name,
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceFileType,
        ModelFileType.task.name,
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceFilename,
        'gemma.task',
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceSource,
        FileSource(other.path).encode(),
      );

      final restarted = await restart();

      expect(restarted.activeInferenceModel, isNull);
    });
  });

  group('stt', () {
    test('a fromFile model and tokenizer are active and installed after a '
        'restart', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final tokenizer = userFile('tokenizer.json', _tokenizerBytes);
      await installStt(model, tokenizer);

      final restarted = await restart();

      final spec = restarted.activeSttModel as SttModelSpec?;
      expect(spec, isNotNull, reason: 'both files are still there');
      expect(spec!.modelSource, FileSource(model.path));
      expect(spec.tokenizerSource, FileSource(tokenizer.path));
      expect(await restarted.isModelInstalled(spec), isTrue);
    });

    test('an identity in the per-field form of older releases does not have '
        'its tokenizer source trusted', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final staleTokenizer = userFile('tokenizer.json', _tokenizerBytes);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        'picked-stt.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        'picked-stt__tokenizer.json',
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.moonshine.name,
      );
      await prefs.setString(
        PreferencesKeys.activeSttSource,
        FileSource(model.path).encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerSource,
        FileSource(staleTokenizer.path).encode(),
      );

      final restarted = await restart();

      expect(restarted.activeSttModel, isNull);
    });
  });

  group('uninstall keeps the app\'s own files', () {
    test('an STT model uninstalled after a restart', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final tokenizer = userFile('tokenizer.json', _tokenizerBytes);
      await installStt(model, tokenizer);
      final restarted = await restart();

      await restarted.deleteModel(restarted.activeSttModel!);

      expect(model.existsSync(), isTrue);
      expect(tokenizer.existsSync(), isTrue);
      expect(
        await restarted.isModelInstalled(restarted.activeSttModel!),
        isFalse,
      );
    });

    test('an embedder uninstalled in the same run', () async {
      final model = userFile('embedder.tflite', _modelBytes);
      final tokenizer = userFile('sentencepiece.model', _tokenizerBytes);
      final installation = await FlutterEdgeAi.installEmbedder()
          .modelFromFile(model.path)
          .tokenizerFromFile(tokenizer.path)
          .install();

      await FlutterEdgeAiPlugin.instance.modelManager.deleteModel(
        installation.spec,
      );

      expect(model.existsSync(), isTrue);
      expect(tokenizer.existsSync(), isTrue);
    });

    test(
      'the file delete every cleanup goes through skips a fromFile file',
      () async {
        // Uninstall, a replace-policy switch and the resume checker all delete
        // through deleteModelFile, by the filename the install registered.
        final model = userFile('picked-model.task', _modelBytes);
        await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.task,
        ).fromFile(model.path).install();

        await ModelFileSystemManager.deleteModelFile('picked-model.task');

        expect(model.existsSync(), isTrue);
      },
    );
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
