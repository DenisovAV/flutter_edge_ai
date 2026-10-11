// Models installed from a file the app owns (`fromFile`) across a restart and
// an uninstall.
//
// A FileSource install is used in place: nothing is copied into core's model
// directory, and the file stays the app's. Where a file is and whose it is
// come from that file's own repository record. After a restart core restores
// only what is still installed, and no uninstall, retry or model switch may
// delete the app's file — while core's own copies still go.
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
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
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

  /// A file at [filename]'s place in core's own directory — where an app on
  /// Android or iOS keeps a model in its Documents, which is that directory.
  Future<File> coreDirFile(String filename, Uint8List bytes) async {
    final path = await ServiceRegistry.instance.fileSystemService
        .getWriteTargetPath(filename);
    return File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  Future<void> saveRecord(
    String id,
    ModelSource source, {
    repo.ModelType type = repo.ModelType.inference,
  }) => ServiceRegistry.instance.modelRepository.saveModel(
    repo.ModelInfo(
      id: id,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: _modelBytes.length,
      type: type,
      hasLoraWeights: false,
    ),
  );

  Future<void> writeInferenceIdentity(String filename, ModelSource source) =>
      SharedPreferences.getInstance().then(
        (prefs) =>
            ActiveIdentityStore.write(prefs, ActiveIdentityKind.inference, {
              PreferencesKeys.activeInferenceModelType: ModelType.gemmaIt.name,
              PreferencesKeys.activeInferenceFileType: ModelFileType.task.name,
              PreferencesKeys.activeInferenceFilename: filename,
              PreferencesKeys.activeInferenceSource: source.encode(),
            }),
      );

  /// A new manager restores from what the previous run persisted, the way a
  /// restarted app does. The plugin's own manager restores only once per
  /// process, so it cannot stand in for a restart.
  Future<MobileModelManager> restart() async {
    final manager = MobileModelManager();
    await manager.initialize();
    return manager;
  }

  Future<void> installTask(File model) => FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
  ).fromFile(model.path).install();

  Future<SttModelSpec> installStt(File model, File tokenizer) async =>
      (await FlutterEdgeAi.installStt()
              .modelFromFile(model.path)
              .tokenizerFromFile(tokenizer.path)
              .ofType(SttModelType.moonshine)
              .install())
          .spec;

  Future<void> expectForgotten(String filename) async {
    final registry = ServiceRegistry.instance.protectedFilesRegistry;
    expect(await registry.getExternalPath(filename), isNull, reason: filename);
    expect(await registry.isProtected(filename), isFalse, reason: filename);
  }

  group('inference restore', () {
    test('a fromFile model is active and installed after a restart', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);

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
      await installTask(model);
      model.deleteSync();

      expect((await restart()).activeInferenceModel, isNull);
    });

    test(
      'a fromFile model the app can no longer read restores nothing',
      () async {
        final model = userFile('picked-model.task', _modelBytes);
        await installTask(model);
        // Stat still works, open does not: a revoked sandbox grant or
        // shared-storage permission looks like this.
        Process.runSync('chmod', ['000', model.path]);

        expect((await restart()).activeInferenceModel, isNull);
      },
      skip: Platform.isWindows ? 'POSIX permissions' : false,
    );

    test('an uninstalled fromFile model is not restored', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);
      // Drops the record and keeps the app's file; the identity stays.
      await FlutterEdgeAi.uninstallModel('picked-model.task');

      expect((await restart()).activeInferenceModel, isNull);
      expect(model.existsSync(), isTrue);
    });

    test(
      'an uninstalled fromFile model in core\'s directory is not restored',
      () async {
        // The app's file stays at core's own path, so only the missing record
        // says the model is gone.
        final model = await coreDirFile('staged.task', _modelBytes);
        await installTask(model);
        await FlutterEdgeAi.uninstallModel('staged.task');

        expect((await restart()).activeInferenceModel, isNull);
        expect(model.existsSync(), isTrue);
      },
    );

    test('a downloaded model is restored from core\'s directory', () async {
      final file = await coreDirFile('downloaded.task', _modelBytes);
      final source = NetworkSource('https://example.com/downloaded.task');
      await saveRecord('downloaded.task', source);
      await writeInferenceIdentity('downloaded.task', source);

      final spec =
          (await restart()).activeInferenceModel as InferenceModelSpec?;

      expect(spec?.modelSource, FileSource(file.path));
    });

    test(
      'the identity\'s source is not followed; the file\'s record decides',
      () async {
        // A record written by an older release, or a re-activated restored
        // spec, can carry a path that is not where this file is installed.
        final file = await coreDirFile('gemma.task', _modelBytes);
        await saveRecord(
          'gemma.task',
          NetworkSource('https://example.com/gemma.task'),
        );
        final other = userFile('qwen.task', _modelBytes);
        await writeInferenceIdentity('gemma.task', FileSource(other.path));

        final spec =
            (await restart()).activeInferenceModel as InferenceModelSpec?;

        expect(spec?.modelSource, FileSource(file.path));
      },
    );

    test('a fromFile model whose recorded path moved is found by its name in '
        'core\'s directory', () async {
      // iOS moves the app container on an update: a model the app kept in its
      // Documents (core's directory) keeps its name, not its absolute path.
      final file = await coreDirFile('picked-model.task', _modelBytes);
      final oldPath =
          '${userDir.path}/OldContainer/Documents/picked-model.task';
      await saveRecord('picked-model.task', FileSource(oldPath));
      await writeInferenceIdentity('picked-model.task', FileSource(oldPath));

      final spec =
          (await restart()).activeInferenceModel as InferenceModelSpec?;

      expect(spec?.modelSource, FileSource(file.path));
    });
  });

  group('stt restore', () {
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

    test('an uninstalled fromFile model is not restored', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final tokenizer = userFile('tokenizer.json', _tokenizerBytes);
      final spec = await installStt(model, tokenizer);
      // A process killed between deleteModel and clearActiveSttIdentity.
      await FlutterEdgeAiPlugin.instance.modelManager.deleteModel(spec);

      expect((await restart()).activeSttModel, isNull);
    });

    test(
      'an app\'s tokenizer named the old way is used in place, not renamed',
      () async {
        // Releases before the tokenizer names were namespaced recorded the plain
        // name. Migrating renames the file — never one the app owns.
        final model = await coreDirFile('picked-stt.tflite', _modelBytes);
        final tokenizer = await coreDirFile('tokenizer.json', _tokenizerBytes);
        await saveRecord(
          'picked-stt.tflite',
          FileSource(model.path),
          type: repo.ModelType.stt,
        );
        await saveRecord(
          'tokenizer.json',
          FileSource(tokenizer.path),
          type: repo.ModelType.stt,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          PreferencesKeys.activeSttFilename,
          'picked-stt.tflite',
        );
        await prefs.setString(
          PreferencesKeys.activeSttTokenizerFilename,
          'tokenizer.json',
        );
        await prefs.setString(
          PreferencesKeys.activeSttModelType,
          SttModelType.moonshine.name,
        );

        final spec = (await restart()).activeSttModel as SttModelSpec?;

        expect(tokenizer.existsSync(), isTrue, reason: 'not renamed');
        expect(spec?.tokenizerSource, FileSource(tokenizer.path));
      },
    );

    test('a downloaded tokenizer migrated to its new name is still core\'s: '
        'an uninstall deletes it', () async {
      final source = NetworkSource('https://example.com/stt');
      await coreDirFile('picked-stt.tflite', _modelBytes);
      await coreDirFile('tokenizer.json', _tokenizerBytes);
      await saveRecord('picked-stt.tflite', source, type: repo.ModelType.stt);
      await saveRecord('tokenizer.json', source, type: repo.ModelType.stt);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        'picked-stt.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        'tokenizer.json',
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.moonshine.name,
      );
      final restarted = await restart();
      final spec = restarted.activeSttModel as SttModelSpec?;
      expect(spec, isNotNull, reason: 'migrated and restored');
      final migrated = File((spec!.tokenizerSource as FileSource).path);
      expect(migrated.existsSync(), isTrue);

      await restarted.deleteModel(spec);

      expect(migrated.existsSync(), isFalse);
    });
  });

  group('embedding restore', () {
    test('an uninstalled fromFile embedder is not restored', () async {
      final model = userFile('embedder.tflite', _modelBytes);
      final tokenizer = userFile('sentencepiece.model', _tokenizerBytes);
      final installation = await FlutterEdgeAi.installEmbedder()
          .modelFromFile(model.path)
          .tokenizerFromFile(tokenizer.path)
          .install();
      // A process killed between deleteModel and clearActiveEmbeddingIdentity.
      await FlutterEdgeAiPlugin.instance.modelManager.deleteModel(
        installation.spec,
      );

      expect((await restart()).activeEmbeddingModel, isNull);
    });
  });

  group('uninstall keeps the app\'s files and forgets them', () {
    test('an STT model uninstalled after a restart', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final tokenizer = userFile('tokenizer.json', _tokenizerBytes);
      final installed = await installStt(model, tokenizer);
      final restarted = await restart();

      await restarted.deleteModel(restarted.activeSttModel!);

      expect(model.existsSync(), isTrue);
      expect(tokenizer.existsSync(), isTrue);
      expect(await restarted.isModelInstalled(installed), isFalse);
      for (final file in installed.files) {
        await expectForgotten(file.filename);
      }
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
      for (final file in installation.spec.files) {
        await expectForgotten(file.filename);
      }
    });

    test('a fromFile model through uninstallModel', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);

      await FlutterEdgeAi.uninstallModel('picked-model.task');

      expect(model.existsSync(), isTrue);
      expect(
        await ServiceRegistry.instance.modelRepository.isInstalled(
          'picked-model.task',
        ),
        isFalse,
      );
      await expectForgotten('picked-model.task');
    });

    test(
      'an app\'s file in core\'s directory survives a repeated uninstall',
      () async {
        final model = await coreDirFile('staged.task', _modelBytes);
        await installTask(model);
        final manager = FlutterEdgeAiPlugin.instance.modelManager;
        final spec = manager.activeInferenceModel!;

        await manager.deleteModel(spec);
        // A retry, or the same call after a restart, finds no record.
        await manager.deleteModel(spec);

        expect(model.existsSync(), isTrue);
      },
    );

    test('core\'s download is deleted although an older uninstall left the '
        'name registered as the app\'s', () async {
      // Releases up to 2.2.0 never unregistered a fromFile install.
      await ServiceRegistry.instance.protectedFilesRegistry
          .registerExternalPath('model.task', '${userDir.path}/model.task');
      final download = await coreDirFile('model.task', _modelBytes);
      final source = NetworkSource('https://example.com/model.task');
      await saveRecord('model.task', source);

      await FlutterEdgeAiPlugin.instance.modelManager.deleteModel(
        InferenceModelSpec(
          name: 'model',
          modelSource: source,
          modelType: ModelType.gemmaIt,
        ),
      );

      expect(download.existsSync(), isFalse);
      await expectForgotten('model.task');
    });

    test('the file delete every cleanup goes through keeps the app\'s file '
        'and deletes core\'s', () async {
      // Uninstall, a replace-policy switch and the resume checker all delete
      // through deleteModelFile.
      final appFile = await coreDirFile('picked-model.task', _modelBytes);
      await installTask(appFile);
      final partial = await coreDirFile('partial.task', _modelBytes);

      await ModelFileSystemManager.deleteModelFile('picked-model.task');
      await ModelFileSystemManager.deleteModelFile('partial.task');

      expect(appFile.existsSync(), isTrue);
      expect(partial.existsSync(), isFalse);
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
