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
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show TtsModelTypeManifest;
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/core/utils/file_name_utils.dart';
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

  /// What a `fromFile` install leaves for [file] under [filename]: its record
  /// and its registration.
  Future<void> installedInPlace(
    String filename,
    File file,
    repo.ModelType type,
  ) async {
    await saveRecord(filename, FileSource(file.path), type: type);
    final registry = ServiceRegistry.instance.protectedFilesRegistry;
    await registry.protect(filename);
    await registry.registerExternalPath(filename, file.path);
  }

  /// The per-field STT identity of a release before the tokenizer names were
  /// namespaced.
  Future<void> writeLegacySttIdentity() async {
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
  }

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
      expect(spec.loraSource, isNull);
      expect(await restarted.isModelInstalled(spec), isTrue);
    });

    test(
      'a model installed with a LoRA has it again after a restart',
      () async {
        final model = userFile('picked-model.task', _modelBytes);
        final lora = userFile('adapter.bin', _modelBytes);
        final installed = (await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.task,
        ).fromFile(model.path).withLoraFromFile(lora.path).install()).spec;

        final restarted = await restart();

        final spec = restarted.activeInferenceModel as InferenceModelSpec?;
        expect(spec, isNotNull);
        // Without it the model loads with no adapter and says nothing.
        expect(spec!.loraSource, isNotNull, reason: 'the LoRA was dropped');
        expect(
          spec.files.map((f) => f.filename),
          installed.files.map((f) => f.filename),
        );
        final paths = await restarted.getModelFilePaths(spec);
        expect(paths?[PreferencesKeys.installedLoraFileName], lora.path);
        expect(await restarted.isModelInstalled(spec), isTrue);
      },
    );

    test('a model whose LoRA file is gone restores nothing, rather than '
        'the model without it', () async {
      final model = userFile('picked-model.task', _modelBytes);
      final lora = userFile('adapter.bin', _modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(model.path).withLoraFromFile(lora.path).install();
      lora.deleteSync();

      expect((await restart()).activeInferenceModel, isNull);
    });

    test('a fromFile model whose file is gone restores nothing', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);
      model.deleteSync();

      expect((await restart()).activeInferenceModel, isNull);
    });

    test('a fromFile model the app can no longer read is still restored, '
        'for the engine\'s open to report', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);
      // Stat still works, open does not: a revoked sandbox grant or
      // shared-storage permission looks like this. It is not "no model".
      Process.runSync('chmod', ['000', model.path]);
      addTearDown(() => Process.runSync('chmod', ['644', model.path]));

      final restarted = await restart();
      final spec = restarted.activeInferenceModel as InferenceModelSpec?;

      expect(spec, isNotNull);
      expect(spec!.modelSource, FileSource(model.path));
      expect(await restarted.isModelInstalled(spec), isTrue);
    }, skip: Platform.isWindows ? 'POSIX permissions' : false);

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

    test('a file with the same name elsewhere does not stand in for a '
        'fromFile model that is gone', () async {
      final model = userFile('picked-model.task', _modelBytes);
      await installTask(model);
      model.deleteSync();
      // Core's directory, and the Documents core used on desktop before
      // 0.15.1: neither file is the one the app installed.
      await coreDirFile('picked-model.task', _modelBytes);
      File(
        '${fakeDocuments.path}/picked-model.task',
      ).writeAsBytesSync(_modelBytes);

      expect((await restart()).activeInferenceModel, isNull);
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

    test('an app\'s tokenizer named the old way is used in place, not '
        'renamed, and is installed under its new name', () async {
      // Releases before the tokenizer names were namespaced recorded the plain
      // name. Migrating renames core's copy — never a file the app owns; only
      // its record and registration move to the new name.
      final model = await coreDirFile('picked-stt.tflite', _modelBytes);
      final tokenizer = await coreDirFile('tokenizer.json', _tokenizerBytes);
      await installedInPlace('picked-stt.tflite', model, repo.ModelType.stt);
      await installedInPlace('tokenizer.json', tokenizer, repo.ModelType.stt);
      await writeLegacySttIdentity();

      final restarted = await restart();
      final spec = restarted.activeSttModel as SttModelSpec?;

      expect(tokenizer.existsSync(), isTrue, reason: 'not renamed');
      expect(spec, isNotNull);
      expect(spec!.tokenizerSource, FileSource(tokenizer.path));
      expect(await restarted.isModelInstalled(spec), isTrue);
      final registry = ServiceRegistry.instance.protectedFilesRegistry;
      expect(
        await registry.getExternalPath('picked-stt__tokenizer.json'),
        tokenizer.path,
      );
      await expectForgotten('tokenizer.json');

      await restarted.deleteModel(spec);

      expect(tokenizer.existsSync(), isTrue);
      final repository = ServiceRegistry.instance.modelRepository;
      expect(await repository.isInstalled('tokenizer.json'), isFalse);
      expect(
        await repository.isInstalled('picked-stt__tokenizer.json'),
        isFalse,
      );
      await expectForgotten('picked-stt__tokenizer.json');
    });

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

    test(
      'a tokenizer with no record is neither renamed nor restored',
      () async {
        final model = await coreDirFile('picked-stt.tflite', _modelBytes);
        final tokenizer = await coreDirFile('tokenizer.json', _tokenizerBytes);
        // The model is installed; only the tokenizer's record is gone.
        await installedInPlace('picked-stt.tflite', model, repo.ModelType.stt);
        await writeLegacySttIdentity();

        final restarted = await restart();

        expect(restarted.activeSttModel, isNull);
        expect(tokenizer.existsSync(), isTrue, reason: 'not renamed');
        expect(
          await ServiceRegistry.instance.modelRepository.loadModel(
            'picked-stt__tokenizer.json',
          ),
          isNull,
        );
      },
    );

    test('a migration an earlier launch left half done is finished without '
        'rewriting its record', () async {
      // The record was copied to the new name; the old one and the persisted
      // name were not changed yet.
      final source = NetworkSource('https://example.com/stt');
      await coreDirFile('picked-stt.tflite', _modelBytes);
      final tokenizer = await coreDirFile(
        'picked-stt__tokenizer.json',
        _tokenizerBytes,
      );
      await saveRecord('picked-stt.tflite', source, type: repo.ModelType.stt);
      await saveRecord('tokenizer.json', source, type: repo.ModelType.stt);
      await saveRecord(
        'picked-stt__tokenizer.json',
        source,
        type: repo.ModelType.stt,
      );
      await writeLegacySttIdentity();

      final spec = (await restart()).activeSttModel as SttModelSpec?;

      expect(spec?.tokenizerSource, FileSource(tokenizer.path));
      final repository = ServiceRegistry.instance.modelRepository;
      expect(
        (await repository.loadModel('picked-stt__tokenizer.json'))?.source,
        source,
        reason: 'core\'s download stays core\'s',
      );
      expect(await repository.isInstalled('tokenizer.json'), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString(
          PreferencesKeys.activeSttTokenizerFilename,
        ),
        'picked-stt__tokenizer.json',
      );
    });

    test('a newer install under the new name is not overwritten by the old '
        'record', () async {
      // The app's old tokenizer is still recorded under the plain name; a
      // newer download of this model was installed under the new name and
      // the app stopped before activating it.
      final appTokenizer = userFile('tokenizer.json', _tokenizerBytes);
      await installedInPlace(
        'tokenizer.json',
        appTokenizer,
        repo.ModelType.stt,
      );
      final download = NetworkSource('https://example.com/stt-v2');
      await coreDirFile('picked-stt.tflite', _modelBytes);
      final newer = await coreDirFile(
        'picked-stt__tokenizer.json',
        _tokenizerBytes,
      );
      await saveRecord('picked-stt.tflite', download, type: repo.ModelType.stt);
      await saveRecord(
        'picked-stt__tokenizer.json',
        download,
        type: repo.ModelType.stt,
      );
      await writeLegacySttIdentity();

      final spec = (await restart()).activeSttModel as SttModelSpec?;

      expect(spec?.tokenizerSource, FileSource(newer.path));
      final repository = ServiceRegistry.instance.modelRepository;
      expect(
        (await repository.loadModel('picked-stt__tokenizer.json'))?.source,
        download,
      );
      expect(
        (await repository.loadModel('tokenizer.json'))?.source,
        FileSource(appTokenizer.path),
        reason: 'the older install\'s record is not this migration\'s',
      );
    });
  });

  group('embedding restore', () {
    test('a tokenizer the app installed before the names were namespaced is '
        'used in place, on this launch and the next', () async {
      final model = await coreDirFile('embedder.tflite', _modelBytes);
      final tokenizer = await coreDirFile(
        'sentencepiece.model',
        _tokenizerBytes,
      );
      await installedInPlace(
        'embedder.tflite',
        model,
        repo.ModelType.embedding,
      );
      await installedInPlace(
        'sentencepiece.model',
        tokenizer,
        repo.ModelType.embedding,
      );
      // The per-field identity releases before the one-key record wrote.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingFilename,
        'embedder.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerFilename,
        'sentencepiece.model',
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingSource,
        FileSource(model.path).encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerSource,
        FileSource(tokenizer.path).encode(),
      );

      final first =
          (await restart()).activeEmbeddingModel as EmbeddingModelSpec?;

      expect(tokenizer.existsSync(), isTrue, reason: 'not renamed');
      expect(first?.tokenizerSource, FileSource(tokenizer.path));

      final next =
          (await restart()).activeEmbeddingModel as EmbeddingModelSpec?;

      expect(next?.modelSource, FileSource(model.path));
      expect(next?.tokenizerSource, FileSource(tokenizer.path));
    });

    test('a legacy embedder whose records are gone is not restored', () async {
      // An older release's per-field identity, its files still in core's
      // directory, its records gone: an uninstall that kept the files.
      await coreDirFile('embedder.tflite', _modelBytes);
      await coreDirFile('embedder__sentencepiece.model', _tokenizerBytes);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingFilename,
        'embedder.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerFilename,
        'embedder__sentencepiece.model',
      );

      expect((await restart()).activeEmbeddingModel, isNull);
    });

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

    test('the identity\'s sources are not followed; the files\' records '
        'decide', () async {
      File pickedIn(String dir, String name, Uint8List bytes) =>
          File('${userDir.path}/$dir/$name')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes);
      final installation = await FlutterEdgeAi.installEmbedder()
          .modelFromFile(pickedIn('old', 'embedder.tflite', _modelBytes).path)
          .tokenizerFromFile(
            pickedIn('old', 'sentencepiece.model', _tokenizerBytes).path,
          )
          .install();
      // The records say where the files are installed; the identity still
      // names the old copies, which are there too.
      final model = pickedIn('new', 'embedder.tflite', _modelBytes);
      final tokenizer = pickedIn('new', 'sentencepiece.model', _tokenizerBytes);
      final [modelFile, tokenizerFile] = installation.spec.files;
      await saveRecord(
        modelFile.filename,
        FileSource(model.path),
        type: repo.ModelType.embedding,
      );
      await saveRecord(
        tokenizerFile.filename,
        FileSource(tokenizer.path),
        type: repo.ModelType.embedding,
      );

      final spec =
          (await restart()).activeEmbeddingModel as EmbeddingModelSpec?;

      expect(spec?.modelSource, FileSource(model.path));
      expect(spec?.tokenizerSource, FileSource(tokenizer.path));
    });
  });

  group('tts restore', () {
    /// A bundle of [type] in core's directory, and its active identity.
    Future<List<String>> placeBundle(TtsModelType type) async {
      final names = [
        for (final fn in type.manifest) FileNameUtils.namespaced(type.name, fn),
      ];
      for (final name in names) {
        await coreDirFile(name, _tokenizerBytes);
      }
      await ActiveIdentityStore.write(
        await SharedPreferences.getInstance(),
        ActiveIdentityKind.tts,
        {
          PreferencesKeys.activeTtsName: 'voice',
          PreferencesKeys.activeTtsModelType: type.name,
        },
      );
      return names;
    }

    test('a downloaded bundle is restored', () async {
      final type = TtsModelType.values.first;
      for (final name in await placeBundle(type)) {
        await saveRecord(
          name,
          NetworkSource('https://example.com/$name'),
          type: repo.ModelType.tts,
        );
      }

      expect((await restart()).activeTtsModel, isNotNull);
    });

    test('a bundle whose records are gone is not restored', () async {
      await placeBundle(TtsModelType.values.first);

      expect((await restart()).activeTtsModel, isNull);
    });
  });

  group('a file picked anew under the same name', () {
    File pickedIn(String dir, String name, Uint8List bytes) =>
        File('${userDir.path}/$dir/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    /// Installs [model] with [lora] and returns the LoRA's record name.
    Future<String> installWithLora(File model, File lora) async {
      final installation = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(model.path).withLoraFromFile(lora.path).install();
      return installation.spec.files[1].filename;
    }

    test('is the inference model after a restart, not the old one', () async {
      final old = pickedIn('old', 'picked-model.task', _modelBytes);
      final picked = pickedIn('new', 'picked-model.task', _modelBytes);
      await installTask(old);
      await installTask(picked);

      final spec =
          (await restart()).activeInferenceModel as InferenceModelSpec?;

      expect(spec?.modelSource, FileSource(picked.path));
    });

    test('is the STT model after a restart', () async {
      await installStt(
        pickedIn('old', 'picked-stt.tflite', _modelBytes),
        pickedIn('old', 'tokenizer.json', _tokenizerBytes),
      );
      final model = pickedIn('new', 'picked-stt.tflite', _modelBytes);
      final tokenizer = pickedIn('new', 'tokenizer.json', _tokenizerBytes);
      await installStt(model, tokenizer);

      final spec = (await restart()).activeSttModel as SttModelSpec?;

      expect(spec?.modelSource, FileSource(model.path));
      expect(spec?.tokenizerSource, FileSource(tokenizer.path));
    });

    test('is the embedder after a restart', () async {
      Future<void> install(File model, File tokenizer) =>
          FlutterEdgeAi.installEmbedder()
              .modelFromFile(model.path)
              .tokenizerFromFile(tokenizer.path)
              .install();
      await install(
        pickedIn('old', 'embedder.tflite', _modelBytes),
        pickedIn('old', 'sentencepiece.model', _tokenizerBytes),
      );
      final model = pickedIn('new', 'embedder.tflite', _modelBytes);
      final tokenizer = pickedIn('new', 'sentencepiece.model', _tokenizerBytes);
      await install(model, tokenizer);

      final spec =
          (await restart()).activeEmbeddingModel as EmbeddingModelSpec?;

      expect(spec?.modelSource, FileSource(model.path));
      expect(spec?.tokenizerSource, FileSource(tokenizer.path));
    });

    test(
      'through ensureModelReadyFromSpec is the model after a restart',
      () async {
        final manager = FlutterEdgeAiPlugin.instance.modelManager;
        Future<void> ready(File model) => manager.ensureModelReadyFromSpec(
          InferenceModelSpec(
            name: 'picked-model',
            modelSource: FileSource(model.path),
            modelType: ModelType.gemmaIt,
          ),
        );
        await ready(pickedIn('old', 'picked-model.task', _modelBytes));
        final picked = pickedIn('new', 'picked-model.task', _modelBytes);

        await ready(picked);

        final spec =
            (await restart()).activeInferenceModel as InferenceModelSpec?;
        expect(spec?.modelSource, FileSource(picked.path));
      },
    );

    test('leaves the LoRA installed with the model alone', () async {
      final lora = pickedIn('lora', 'adapter.bin', _tokenizerBytes);
      final loraId = await installWithLora(
        pickedIn('old', 'picked-model.task', _modelBytes),
        lora,
      );
      // Installed again, the record would take the new size.
      lora.writeAsBytesSync(Uint8List(_tokenizerBytes.length * 2));

      await installWithLora(
        pickedIn('new', 'picked-model.task', _modelBytes),
        lora,
      );

      final record = await ServiceRegistry.instance.modelRepository.loadModel(
        loraId,
      );
      expect(record?.sizeBytes, _tokenizerBytes.length);
    });

    test('is the LoRA, when only the LoRA is picked anew', () async {
      final model = pickedIn('model', 'picked-model.task', _modelBytes);
      await installWithLora(
        model,
        pickedIn('old', 'adapter.bin', _tokenizerBytes),
      );
      final lora = pickedIn('new', 'adapter.bin', _tokenizerBytes);

      final loraId = await installWithLora(model, lora);

      final record = await ServiceRegistry.instance.modelRepository.loadModel(
        loraId,
      );
      expect(record?.source, FileSource(lora.path));
    });

    test('replaces core\'s download, which is deleted', () async {
      final download = await coreDirFile('picked-model.task', _modelBytes);
      await saveRecord(
        'picked-model.task',
        NetworkSource('https://example.com/picked-model.task'),
      );
      final picked = pickedIn('new', 'picked-model.task', _modelBytes);

      await installTask(picked);

      expect(download.existsSync(), isFalse, reason: 'nothing else frees it');
      expect(picked.existsSync(), isTrue);
      expect(
        (await ServiceRegistry.instance.modelRepository.loadModel(
          'picked-model.task',
        ))?.source,
        FileSource(picked.path),
      );
    });

    test(
      'replaces the STT and embedder downloads, which are deleted',
      () async {
        Future<List<File>> downloaded(
          List<String> names,
          repo.ModelType type,
        ) => Future.wait([
          for (final name in names)
            () async {
              final file = await coreDirFile(name, _modelBytes);
              await saveRecord(
                name,
                NetworkSource('https://example.com/$name'),
                type: type,
              );
              return file;
            }(),
        ]);
        final copies = [
          ...await downloaded([
            'picked-stt.tflite',
            'picked-stt__tokenizer.json',
          ], repo.ModelType.stt),
          ...await downloaded([
            'embedder.tflite',
            'embedder__sentencepiece.model',
          ], repo.ModelType.embedding),
        ];

        await installStt(
          pickedIn('new', 'picked-stt.tflite', _modelBytes),
          pickedIn('new', 'tokenizer.json', _tokenizerBytes),
        );
        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(pickedIn('new', 'embedder.tflite', _modelBytes).path)
            .tokenizerFromFile(
              pickedIn('new', 'sentencepiece.model', _tokenizerBytes).path,
            )
            .install();

        for (final copy in copies) {
          expect(copy.existsSync(), isFalse, reason: copy.path);
        }
      },
    );

    test('replaces a downloaded LoRA, which is deleted', () async {
      final model = pickedIn('model', 'picked-model.task', _modelBytes);
      final loraId = await installWithLora(
        model,
        pickedIn('old', 'adapter.bin', _tokenizerBytes),
      );
      final download = await coreDirFile(loraId, _tokenizerBytes);
      await saveRecord(loraId, NetworkSource('https://example.com/a.bin'));

      await installWithLora(
        model,
        pickedIn('new', 'adapter.bin', _tokenizerBytes),
      );

      expect(download.existsSync(), isFalse);
    });

    test('keeps core\'s download when the app picks that very file', () async {
      final download = await coreDirFile('picked-model.task', _modelBytes);
      await saveRecord(
        'picked-model.task',
        NetworkSource('https://example.com/picked-model.task'),
      );

      await installTask(download);

      expect(download.existsSync(), isTrue);
      expect(
        (await ServiceRegistry.instance.modelRepository.loadModel(
          'picked-model.task',
        ))?.source,
        isA<NetworkSource>(),
        reason: 'core\'s copy handed back stays core\'s',
      );
    });

    test('at the same path, after the file is gone, says so', () async {
      final picked = pickedIn('old', 'picked-model.task', _modelBytes);
      await installTask(picked);
      picked.deleteSync();

      await expectLater(installTask(picked), throwsA(anything));
    });
  });

  group('storage cleanup', () {
    test('counts a .gguf file in core\'s directory', () async {
      // Protected, so the orphan scan inside getStorageInfo skips it without
      // asking the downloader, which does not answer on a test host. The
      // extension filter that would drop the file comes first either way.
      await coreDirFile('model.gguf', _modelBytes);

      final stats = await ModelFileSystemManager.getStorageInfo(
        protectedFiles: ['model.gguf'],
      );

      expect(stats.totalFiles, 1);
      expect(stats.totalSizeBytes, _modelBytes.length);
    });

    test(
      'never counts an installed app file in core\'s directory as an orphan',
      () async {
        // Its record has the namespaced name, the file keeps its own.
        final model = await coreDirFile('picked-stt.tflite', _modelBytes);
        final tokenizer = await coreDirFile('tokenizer.json', _tokenizerBytes);
        await installedInPlace('picked-stt.tflite', model, repo.ModelType.stt);
        await installedInPlace('tokenizer.json', tokenizer, repo.ModelType.stt);
        await writeLegacySttIdentity();
        final restarted = await restart();

        final orphans = await restarted.getOrphanedFiles();

        expect(orphans.map((orphan) => orphan.filename), isEmpty);
      },
      // An unprotected file reaches the downloader, which does not answer on
      // a test host: a regression shows up as this timeout.
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  group('uninstall keeps the app\'s files and forgets them', () {
    test('an STT model uninstalled after a restart', () async {
      final model = userFile('picked-stt.tflite', _modelBytes);
      final tokenizer = userFile('tokenizer.json', _tokenizerBytes);
      final installed = await installStt(model, tokenizer);
      final restarted = await restart();
      final active = restarted.activeSttModel;
      expect(active, isNotNull);

      await restarted.deleteModel(active!);

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
        final spec = manager.activeInferenceModel;
        expect(spec, isNotNull);

        await manager.deleteModel(spec!);
        // A retry, or the same call after a restart, finds no record.
        await manager.deleteModel(spec);

        expect(model.existsSync(), isTrue);
      },
    );

    test('core\'s download is deleted although an older uninstall left the '
        'name registered as the app\'s', () async {
      // Releases up to 2.2.0 never unregistered a fromFile install.
      final registry = ServiceRegistry.instance.protectedFilesRegistry;
      await registry.protect('model.task');
      await registry.registerExternalPath(
        'model.task',
        '${userDir.path}/model.task',
      );
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

    test('the file delete cleanups go through keeps the app\'s file and '
        'deletes core\'s', () async {
      // A replace-policy switch's task cleanup and the resume checker delete
      // through deleteModelFile; it decides by the record, like an uninstall.
      final appFile = await coreDirFile('picked-model.task', _modelBytes);
      await installTask(appFile);
      // Recorded in a container iOS has since moved; the file is here now.
      final moved = await coreDirFile('moved.task', _modelBytes);
      await saveRecord(
        'moved.task',
        FileSource('${userDir.path}/OldContainer/Documents/moved.task'),
      );
      final partial = await coreDirFile('partial.task', _modelBytes);

      for (final name in ['picked-model.task', 'moved.task', 'partial.task']) {
        await ModelFileSystemManager.deleteModelFile(name);
      }

      expect(appFile.existsSync(), isTrue);
      expect(moved.existsSync(), isTrue);
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
