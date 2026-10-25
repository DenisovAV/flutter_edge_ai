// Where FlutterEdgeAi.getModelPath says a file is, and what uninstallModel
// does to the active inference model.
//
// getModelPath answers from the file's own repository record, the way the
// engines read the file in this run: a file the app installed with
// `fromFile` where it is now — on iOS in the app's current data container,
// which an update or a restore from a backup can move —, a resource of the
// iOS bundle in place, otherwise core's copy. A name with no record (an
// install older than per-file records) resolves as it always did: what the
// app registered, else core's directory. Web is not covered: it returns the
// name unchanged, and these tests run on the VM.
//
// uninstallModel clears the active inference identity, in memory and
// persisted, when the file it removes is one of the active model's — after
// the file is gone and before its record is, so a step that fails leaves an
// uninstall that can be retried.
//
// Run: flutter test test/core/model_path_and_uninstall_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/infrastructure/platform_file_system_service.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/model_management/utils/local_file_io.dart'
    show debugAppContainerCanMove, debugBundledResourcesAreCopies;
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show FlutterEdgeAiMobile, MobileModelManager;

/// Over the 1 MB floor install validation applies to model files.
final _modelBytes = Uint8List(1024 * 1024 + 1);

/// Two iOS app data containers: the one a file was recorded in, and the one
/// the app runs in now.
const _earlierContainer = 'AAAAAAAA-1111-2222-3333-444444444444';
const _currentContainer = 'BBBBBBBB-5555-6666-7777-888888888888';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory user;
  late _Downloads downloads;

  Future<void> useServices({FileSystemService? fileSystem}) async {
    ServiceRegistry.reset();
    await ServiceRegistry.initialize(
      downloadService: downloads,
      fileSystemService: fileSystem,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('fe_model_path_');
    // Documents inside an app data container shaped as iOS names it, so a
    // test can move the container; to the desktop host it is a directory.
    final documents = Directory(
      '${root.path}/Containers/Data/Application/$_currentContainer/Documents',
    )..createSync(recursive: true);
    final support = Directory('${root.path}/support')..createSync();
    user = Directory('${root.path}/user')..createSync();
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: documents.path,
      appSupportPath: support.path,
    );
    downloads = _Downloads();
    await useServices();
    // The plugin's model manager lives as long as the process: no test
    // starts with the previous test's active model.
    await FlutterEdgeAiPlugin.instance.modelManager
        .clearActiveInferenceIdentity();
  });

  tearDown(() async {
    debugAppContainerCanMove = null;
    debugBundledResourcesAreCopies = null;
    ServiceRegistry.reset();
    if (await root.exists()) await root.delete(recursive: true);
  });

  repo.ModelRepository records() => ServiceRegistry.instance.modelRepository;

  File userFile(String relative) => File('${user.path}/$relative')
    ..createSync(recursive: true)
    ..writeAsBytesSync(_modelBytes);

  Future<String> coreReadPath(String name) =>
      ServiceRegistry.instance.fileSystemService.getReadTargetPath(name);

  Future<void> saveRecord(String id, ModelSource source) => records().saveModel(
    repo.ModelInfo(
      id: id,
      source: source,
      installedAt: DateTime(2026),
      sizeBytes: _modelBytes.length,
      type: repo.ModelType.inference,
      hasLoraWeights: false,
    ),
  );

  /// What a `fromFile` install registers for [name].
  Future<void> registerAppFile(String name, String filePath) async {
    final registry = ServiceRegistry.instance.protectedFilesRegistry;
    await registry.protect(name);
    await registry.registerExternalPath(name, filePath);
  }

  Future<InferenceInstallation> fromFile(String filePath, {String? lora}) {
    var builder = FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
    ).fromFile(filePath);
    if (lora != null) builder = builder.withLoraFromFile(lora);
    return builder.install();
  }

  /// Core's copy of [name], downloaded; the model is active.
  Future<File> downloaded(String name) async {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
    ).fromNetwork('https://a.example/m/$name').install();
    return File(await coreReadPath(name));
  }

  Future<Map<String, String>?> persistedIdentity() async =>
      ActiveIdentityStore.read(
        await SharedPreferences.getInstance(),
        ActiveIdentityKind.inference,
      );

  group('getModelPath', () {
    test('a fromFile model recorded in an earlier iOS container is where it '
        'is in the current one', () async {
      debugAppContainerCanMove = true;
      final containers = '${root.path}/Containers/Data/Application';
      final recorded = '$containers/$_earlierContainer/Documents/picked.task';
      final now = File('$containers/$_currentContainer/Documents/picked.task')
        ..writeAsBytesSync(_modelBytes);
      // What the install left before the container moved: the record and the
      // registration both name the earlier container.
      await saveRecord('picked.task', FileSource(recorded));
      await registerAppFile('picked.task', recorded);

      expect(await FlutterEdgeAi.getModelPath('picked.task'), now.path);
    });

    test('a fromFile model is the app\'s file, where it lies', () async {
      final picked = userFile('picked/model.task');
      await fromFile(picked.path);

      expect(await FlutterEdgeAi.getModelPath('model.task'), picked.path);
    });

    test('a download is core\'s copy, although an older release left the '
        'name registered as the app\'s file', () async {
      final copy = await downloaded('model.task');
      // Releases up to 2.2.0 kept a fromFile registration after the name was
      // uninstalled or downloaded over.
      await registerAppFile('model.task', '${user.path}/model.task');

      expect(await FlutterEdgeAi.getModelPath('model.task'), copy.path);
      expect(copy.existsSync(), isTrue);
    });

    test('a resource of the iOS bundle is read in place', () async {
      // The host reads bundled resources in place, as iOS does.
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/gemma.task')
        ..writeAsBytesSync(_modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').install();

      expect(await FlutterEdgeAi.getModelPath('gemma.task'), resource.path);
    });

    test('a bundle resource recorded under a namespaced name is found by its '
        'resource name', () async {
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/tokenizer.model')
        ..writeAsBytesSync(_modelBytes);
      await saveRecord(
        'gemma__tokenizer.model',
        BundledSource('tokenizer.model'),
      );

      expect(
        await FlutterEdgeAi.getModelPath('gemma__tokenizer.model'),
        resource.path,
      );
    });

    test('a resource the iOS bundle no longer holds throws, as loading it '
        'does', () async {
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      await saveRecord('gone.task', BundledSource('gone.task'));

      await expectLater(
        FlutterEdgeAi.getModelPath('gone.task'),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('gone.task'),
          ),
        ),
      );
    });

    test('a name with no record is the file the app registered', () async {
      // An install from before every file had a record.
      await registerAppFile('legacy.task', '${user.path}/legacy.task');

      expect(
        await FlutterEdgeAi.getModelPath('legacy.task'),
        '${user.path}/legacy.task',
      );
    });

    test('a name with no record and no registration is in core\'s '
        'directory', () async {
      expect(
        await FlutterEdgeAi.getModelPath('nothing.task'),
        await coreReadPath('nothing.task'),
      );
    });
  });

  // What a start finds: the active model is rebuilt from its files' records,
  // and must name the files the engine opens when the model is activated —
  // the same places getModelPath reports.
  group('a start restores the active model', () {
    Future<MobileModelManager> restart() async {
      final restarted = MobileModelManager();
      await restarted.ensureInitialized();
      return restarted;
    }

    test('from a resource of the iOS bundle, read in place', () async {
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/gemma.task')
        ..writeAsBytesSync(_modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').install();

      final restarted = await restart();

      expect(
        (restarted.activeInferenceModel as InferenceModelSpec?)?.modelSource,
        FileSource(resource.path),
      );
      expect(await FlutterEdgeAi.getModelPath('gemma.task'), resource.path);
    });

    test('from the iOS bundle, not a file of that name in core\'s '
        'directory', () async {
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/gemma.task')
        ..writeAsBytesSync(_modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').install();
      // Core never writes a bundled resource there on iOS; this is someone
      // else's file.
      File(await coreReadPath('gemma.task')).writeAsBytesSync(_modelBytes);

      final restarted = await restart();

      expect(
        (restarted.activeInferenceModel as InferenceModelSpec?)?.modelSource,
        FileSource(resource.path),
      );
    });

    test('with a bundled LoRA, from core\'s copy of it under its resource '
        'name on Android', () async {
      debugBundledResourcesAreCopies = true;
      final apk = Directory('${root.path}/apk')..createSync();
      File('${apk.path}/gemma.task').writeAsBytesSync(_modelBytes);
      File('${apk.path}/adapter.bin').writeAsBytesSync(_modelBytes);
      await useServices(fileSystem: _ApkAssets(apk));
      final installation = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').withLoraFromBundled('adapter.bin').install();
      final loraName = installation.spec.files
          .singleWhere(
            (file) => file.prefsKey == PreferencesKeys.installedLoraFileName,
          )
          .filename;
      final fs = ServiceRegistry.instance.fileSystemService;
      final loraCopy = await fs.getWriteTargetPath('adapter.bin');
      expect(loraName, isNot('adapter.bin'), reason: 'a namespaced record');
      // An app update that ships another adapter under the same name.
      File(
        '${apk.path}/adapter.bin',
      ).writeAsBytesSync(Uint8List(_modelBytes.length)..[0] = 7);

      final restarted = await restart();

      final active = restarted.activeInferenceModel as InferenceModelSpec?;
      expect(
        active?.modelSource,
        FileSource(await fs.getWriteTargetPath('gemma.task')),
      );
      expect(active?.loraSource, FileSource(loraCopy));
      expect(
        File(loraCopy).readAsBytesSync().first,
        7,
        reason:
            'the copy is renewed from the APK installed now, as when the '
            'model is activated',
      );
      expect(await FlutterEdgeAi.getModelPath(loraName), loraCopy);
    });
  });

  // What an uninstall deletes is core's copy, found as getModelPath finds the
  // file: a resource the iOS bundle serves in place is not core's, and
  // Android's copy of a bundled resource is under its resource name.
  group('uninstalling a bundled file', () {
    test('on iOS deletes nothing in core\'s directory', () async {
      final bundle = Directory('${root.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/gemma.task')
        ..writeAsBytesSync(_modelBytes);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').install();
      final notCores = File(await coreReadPath('gemma.task'))
        ..writeAsBytesSync(_modelBytes);

      await FlutterEdgeAi.uninstallModel('gemma.task');

      expect(notCores.existsSync(), isTrue);
      expect(resource.existsSync(), isTrue);
      expect(await records().isInstalled('gemma.task'), isFalse);
    });

    Future<({InferenceInstallation installation, String loraName})>
    androidWithLora() async {
      debugBundledResourcesAreCopies = true;
      final apk = Directory('${root.path}/apk')..createSync();
      File('${apk.path}/gemma.task').writeAsBytesSync(_modelBytes);
      File('${apk.path}/adapter.bin').writeAsBytesSync(_modelBytes);
      await useServices(fileSystem: _ApkAssets(apk));
      final installation = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('gemma.task').withLoraFromBundled('adapter.bin').install();
      final loraName = installation.spec.files
          .singleWhere(
            (file) => file.prefsKey == PreferencesKeys.installedLoraFileName,
          )
          .filename;
      return (installation: installation, loraName: loraName);
    }

    test('on Android deletes core\'s copy under its resource name', () async {
      final (:installation, :loraName) = await androidWithLora();
      final fs = ServiceRegistry.instance.fileSystemService;
      final loraCopy = File(await fs.getWriteTargetPath('adapter.bin'));
      expect(loraCopy.existsSync(), isTrue);

      await FlutterEdgeAi.uninstallModel(loraName);

      expect(loraCopy.existsSync(), isFalse);
      expect(await records().isInstalled(loraName), isFalse);
    });

    test('through the model manager, on Android, deletes every copy', () async {
      final (:installation, :loraName) = await androidWithLora();
      final fs = ServiceRegistry.instance.fileSystemService;
      final copies = [
        File(await fs.getWriteTargetPath('gemma.task')),
        File(await fs.getWriteTargetPath('adapter.bin')),
      ];
      expect(copies.map((f) => f.existsSync()), everyElement(isTrue));

      await FlutterEdgeAiPlugin.instance.modelManager.deleteModel(
        installation.spec,
      );

      expect(copies.map((f) => f.existsSync()), everyElement(isFalse));
      expect(await records().isInstalled(loraName), isFalse);
    });
  });

  group('uninstallModel and the active model', () {
    test('removing the active fromFile model clears the active identity, in '
        'memory and persisted', () async {
      final picked = userFile('active.task');
      await fromFile(picked.path);
      expect(FlutterEdgeAi.activeModelSpec, isNotNull);

      await FlutterEdgeAi.uninstallModel('active.task');

      expect(FlutterEdgeAi.hasActiveModel(), isFalse);
      expect(FlutterEdgeAi.activeModelSpec, isNull);
      await expectLater(
        FlutterEdgeAi.getActiveModel(),
        throwsA(isA<NoActiveModelError>()),
      );
      expect(await persistedIdentity(), isNull);
      expect(picked.existsSync(), isTrue, reason: 'the app\'s own file');
    });

    for (final (name, shell) in [
      ('mobile', FlutterEdgeAiMobile.new),
      ('desktop', () => FlutterEdgeAiDesktop.instance),
    ]) {
      test('the model getActiveModel built from the file is closed before the '
          'file goes, and not handed out again ($name)', () async {
        final plugin = FlutterEdgeAiPlugin.instance;
        FlutterEdgeAiPlugin.instance = shell();
        addTearDown(() => FlutterEdgeAiPlugin.instance = plugin);
        await FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
        final copy = await downloaded('model.task');
        bool? fileAtClose;
        EngineRegistry.instance
          ..reset()
          ..registerAll([
            _Engine(onClose: () => fileAtClose = copy.existsSync()),
          ]);
        addTearDown(EngineRegistry.instance.reset);
        final built = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
        addTearDown(built.close);

        await FlutterEdgeAi.uninstallModel('model.task');

        expect(built.isClosed, isTrue);
        expect(fileAtClose, isTrue, reason: 'closed while the file still was');
        expect(copy.existsSync(), isFalse);
        expect(FlutterEdgeAiPlugin.instance.initializedModel, isNull);
        await expectLater(
          FlutterEdgeAi.getActiveModel(maxTokens: 1024),
          throwsA(isA<NoActiveModelError>()),
        );
      });
    }

    test('a model built from another file stays open', () async {
      final plugin = FlutterEdgeAiPlugin.instance;
      FlutterEdgeAiPlugin.instance = FlutterEdgeAiMobile();
      addTearDown(() => FlutterEdgeAiPlugin.instance = plugin);
      // What initialize() does first: a restore at the uninstall would
      // replace the active spec and rebuild the model for that reason.
      await FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
      EngineRegistry.instance
        ..reset()
        ..registerAll([_Engine()]);
      addTearDown(EngineRegistry.instance.reset);
      await fromFile(userFile('other/other.task').path);
      await downloaded('model.task');
      final built = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      addTearDown(built.close);

      await FlutterEdgeAi.uninstallModel('other.task');

      expect(built.isClosed, isFalse);
      expect(await FlutterEdgeAi.getActiveModel(maxTokens: 1024), same(built));
    });

    test('removing the active download clears it too', () async {
      final copy = await downloaded('model.task');
      expect(FlutterEdgeAi.activeModelSpec, isNotNull);

      await FlutterEdgeAi.uninstallModel('model.task');

      expect(copy.existsSync(), isFalse);
      expect(FlutterEdgeAi.activeModelSpec, isNull);
      expect(await persistedIdentity(), isNull);
    });

    test('removing the active model\'s LoRA clears the identity', () async {
      final installation = await fromFile(
        userFile('model.task').path,
        lora: userFile('adapter.bin').path,
      );
      final lora = installation.spec.files.singleWhere(
        (file) => file.prefsKey == PreferencesKeys.installedLoraFileName,
      );

      await FlutterEdgeAi.uninstallModel(lora.filename);

      expect(FlutterEdgeAi.activeModelSpec, isNull);
      expect(await persistedIdentity(), isNull);
    });

    test('removing a file the active model does not use keeps the '
        'identity', () async {
      await fromFile(userFile('other/other.task').path);
      final active = userFile('active/active.task');
      await fromFile(active.path);

      await FlutterEdgeAi.uninstallModel('other.task');

      expect(
        FlutterEdgeAi.activeModelSpec?.modelSource,
        FileSource(active.path),
      );
      expect(
        (await persistedIdentity())?[PreferencesKeys.activeInferenceFilename],
        'active.task',
      );
    });

    test('removing the active model before anything read it after a start '
        'clears it', () async {
      await downloaded('model.task');
      // A started app whose model manager has not restored the active model
      // yet.
      final restarted = MobileModelManager();
      final plugin = FlutterEdgeAiPlugin.instance;
      FlutterEdgeAiPlugin.instance = _PluginWith(restarted);
      addTearDown(() => FlutterEdgeAiPlugin.instance = plugin);

      await FlutterEdgeAi.uninstallModel('model.task');

      expect(restarted.activeInferenceModel, isNull);
      expect(await persistedIdentity(), isNull);
    });

    test('an identity clear that fails leaves the record, and the retry '
        'clears it', () async {
      final copy = await downloaded('model.task');
      final active = FlutterEdgeAi.activeModelSpec;
      expect(active, isNotNull);
      final manager = _ClearFailsOnce(active!);
      final plugin = FlutterEdgeAiPlugin.instance;
      FlutterEdgeAiPlugin.instance = _PluginWith(manager);
      addTearDown(() => FlutterEdgeAiPlugin.instance = plugin);

      await expectLater(
        FlutterEdgeAi.uninstallModel('model.task'),
        throwsA(isA<StateError>()),
      );
      expect(copy.existsSync(), isFalse);
      expect(await records().isInstalled('model.task'), isTrue);

      await FlutterEdgeAi.uninstallModel('model.task');

      expect(manager.activeInferenceModel, isNull);
      expect(await records().isInstalled('model.task'), isFalse);
    });

    test('a file delete that fails leaves the identity, and the retry '
        'clears it', () async {
      final copy = await downloaded('model.task');
      await useServices(fileSystem: _UndeletableFileSystem(copy.path));

      await expectLater(
        FlutterEdgeAi.uninstallModel('model.task'),
        throwsA(isA<FileSystemException>()),
      );
      expect(FlutterEdgeAi.activeModelSpec, isNotNull);
      expect(await persistedIdentity(), isNotNull);
      expect(await records().isInstalled('model.task'), isTrue);

      await useServices();
      await FlutterEdgeAi.uninstallModel('model.task');

      expect(copy.existsSync(), isFalse);
      expect(FlutterEdgeAi.activeModelSpec, isNull);
      expect(await persistedIdentity(), isNull);
    });
  });
}

/// The plugin with [modelManager] in place of its own.
final class _PluginWith extends FlutterEdgeAiPlugin {
  _PluginWith(this.modelManager);

  @override
  final ModelFileManager modelManager;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A model manager with [_active] as the active inference model, whose first
/// clear of it fails, as a storage write can.
final class _ClearFailsOnce extends ModelFileManager {
  _ClearFailsOnce(this._active);

  ModelSpec? _active;
  var _clears = 0;

  @override
  ModelSpec? get activeInferenceModel => _active;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> clearActiveInferenceIdentity() async {
    if (++_clears == 1) throw StateError('the identity was not removed');
    _active = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Builds a model for any file, without opening it.
final class _Engine implements InferenceEngineProvider {
  _Engine({this.onClose});

  /// Called by each model this engine built when it closes.
  final void Function()? onClose;

  @override
  String get name => 'Fake';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async => _Model(onClose);
}

final class _Model with CloseNotifier implements InferenceModel {
  _Model([this.onClose]);

  final void Function()? onClose;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose?.call();
    fireCloseListeners();
  }

  // The shell only closes and listens to the model it caches.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Writes a model-sized file for each download.
class _Downloads implements DownloadService {
  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    await File(targetPath).writeAsBytes(_modelBytes);
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    await download(url, targetPath);
    yield 100;
  }
}

/// A file system whose bundled resources are files in [bundle], read in
/// place as the iOS bundle is; a resource the bundle does not hold is not
/// found, as on iOS.
class _BundleFiles extends PlatformFileSystemService {
  _BundleFiles(this.bundle);
  final Directory bundle;

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    final resource = File(path.join(bundle.path, resourceName));
    if (!resource.existsSync()) {
      throw Exception('Bundled resource not found: $resourceName');
    }
    return resource.path;
  }
}

/// A file system whose bundled resources are the files in [apk], copied into
/// core's directory under their resource name on each lookup, as Android
/// copies an asset out of the APK.
class _ApkAssets extends PlatformFileSystemService {
  _ApkAssets(this.apk);
  final Directory apk;

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    final asset = File(path.join(apk.path, resourceName));
    if (!asset.existsSync()) {
      throw Exception('Failed to copy asset from Android assets');
    }
    final copy = await getWriteTargetPath(resourceName);
    await asset.copy(copy);
    return copy;
  }
}

/// A file system that cannot delete one file, the way Windows refuses to
/// delete a model a live engine has mapped.
class _UndeletableFileSystem extends PlatformFileSystemService {
  _UndeletableFileSystem(this.locked);
  final String locked;

  @override
  Future<void> deleteFile(String filePath) async {
    if (path.equals(filePath, locked)) {
      throw FileSystemException('The file is in use', filePath);
    }
    await super.deleteFile(filePath);
  }
}

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
