// The install rule every installer follows when a name already installed is
// installed again: what is skipped, installed or refused, and how core's
// earlier copy is released — only once the new file is active, only if it is
// a free copy of core's, and still after an interrupted install.
//
// Run: flutter test test/core/install_rule_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/infrastructure/platform_file_system_service.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/install_rule.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;

/// Over the 1 MB floor install validation applies to model files; the first
/// byte tells one file's bytes from another's.
Uint8List _model(int mark) => Uint8List(1024 * 1024 + 1)..[0] = mark;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late Directory support;
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
    docs = await Directory.systemTemp.createTemp('fe_rule_docs_');
    support = await Directory.systemTemp.createTemp('fe_rule_support_');
    user = await Directory.systemTemp.createTemp('fe_rule_user_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: docs.path,
      appSupportPath: support.path,
    );
    downloads = _Downloads();
    await useServices();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [docs, support, user]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  repo.ModelRepository records() => ServiceRegistry.instance.modelRepository;

  Future<String> coreDir() =>
      ServiceRegistry.instance.fileSystemService.getModelStorageDirectory();

  File userFile(String relative, Uint8List bytes) =>
      File('${user.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  Future<void> fromFile(String path) => FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
  ).fromFile(path).install();

  Future<void> fromNetwork(String url, {String? token}) =>
      FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromNetwork(url, token: token).install();

  /// core's copy of `model.task`, downloaded from [url].
  Future<File> downloaded([
    String url = 'https://a.example/m/model.task',
  ]) async {
    await fromNetwork(url);
    return File('${await coreDir()}/model.task');
  }

  /// core's copy of [name], downloaded.
  Future<File> downloadedNamed(String name) async {
    await fromNetwork('https://a.example/m/$name');
    return File('${await coreDir()}/$name');
  }

  Future<ModelSource?> sourceOf(String name) async =>
      (await records().loadModel(name))?.source;

  Future<String?> journal() async => (await SharedPreferences.getInstance())
      .getString(PreferencesKeys.pendingCopyReleases);

  /// Installs the app's [picked] file over core's download of its name, the
  /// way an installer does, but stops before the release: the app stopped
  /// there.
  Future<void> installStoppedBeforeRelease(File picked) async {
    await installPlanned(
      await planInstall(
        InferenceModelSpec(
          name: 'model',
          modelSource: FileSource(picked.path),
          modelType: ModelType.gemmaIt,
        ).files,
      ),
      modelType: repo.ModelType.inference,
    );
  }

  Future<void> saveRecord(String name, ModelSource source) =>
      records().saveModel(
        repo.ModelInfo(
          id: name,
          source: source,
          installedAt: DateTime(2026),
          sizeBytes: 1,
          type: repo.ModelType.inference,
          hasLoraWeights: false,
        ),
      );

  Future<MobileModelManager> restart() async {
    final manager = MobileModelManager();
    await manager.initialize();
    return manager;
  }

  group('the app picks a file under a name core downloaded', () {
    test('core\'s copy goes once the app\'s file is installed', () async {
      final copy = await downloaded();
      final picked = userFile('picked/model.task', _model(2));

      await fromFile(picked.path);

      expect(await sourceOf('model.task'), FileSource(picked.path));
      expect(copy.existsSync(), isFalse);
      expect(picked.existsSync(), isTrue);
    });

    test(
      'a pick of core\'s own copy, however spelled, keeps it core\'s',
      () async {
        final copy = await downloaded();
        final spellings = [copy.path];
        // Links need Developer Mode on Windows.
        if (!Platform.isWindows) {
          final dirLink = Link('${user.path}/dir-link')
            ..createSync(copy.parent.path);
          final fileLink = Link('${user.path}/links/model.task')
            ..createSync(copy.path, recursive: true);
          // Another name for the same file, as an Android bind mount gives.
          final hardLink = '${user.path}/hard/model.task';
          Directory('${user.path}/hard').createSync();
          expect(Process.runSync('ln', [copy.path, hardLink]).exitCode, 0);
          spellings.addAll([
            '${dirLink.path}/model.task',
            fileLink.path,
            hardLink,
          ]);
        }

        for (final spelling in spellings) {
          await fromFile(spelling);

          expect(copy.existsSync(), isTrue, reason: spelling);
          expect(
            await sourceOf('model.task'),
            isA<NetworkSource>(),
            reason: spelling,
          );
        }
        await FlutterEdgeAi.uninstallModel('model.task');
        expect(copy.existsSync(), isFalse, reason: 'core\'s, so uninstalled');
      },
    );

    test('a restored download handed back to ensureModelReadyFromSpec stays '
        'core\'s', () async {
      final copy = await downloaded();
      final restarted = await restart();
      final restored = restarted.activeInferenceModel!;
      expect(restored.files.single.source, FileSource(copy.path));

      await restarted.ensureModelReadyFromSpec(restored);

      expect(await sourceOf('model.task'), isA<NetworkSource>());
      await restarted.deleteModel(restored);
      expect(copy.existsSync(), isFalse);
    });

    test('a pick that cannot be told from core\'s copy is installed, and '
        'the copy kept', () async {
      final copy = await downloaded();
      final picked = userFile('p/model.task', _model(2));

      await IOOverrides.runZoned(
        () => fromFile(picked.path),
        fseIdentical: (a, b) async => throw FileSystemException('busy', a),
      );

      expect(await sourceOf('model.task'), FileSource(picked.path));
      expect(copy.existsSync(), isTrue);
    });

    test(
      'core\'s copy the app wrote a file of its own over is the app\'s',
      () async {
        final copy = await downloaded();
        copy.writeAsBytesSync(Uint8List(2 * 1024 * 1024));

        await fromFile(copy.path);

        expect(await sourceOf('model.task'), FileSource(copy.path));
        await FlutterEdgeAi.uninstallModel('model.task');
        expect(copy.existsSync(), isTrue, reason: 'the app\'s, so kept');
      },
    );

    test('a pick of a resource the iOS bundle holds stays core\'s', () async {
      // The host reads bundled resources in place, as iOS does.
      final bundle = Directory('${user.path}/Runner.app')..createSync();
      await useServices(fileSystem: _BundleFiles(bundle));
      final resource = File('${bundle.path}/model.task')
        ..writeAsBytesSync(_model(4));
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromBundled('model.task').install();

      await fromFile(resource.path);

      expect(await sourceOf('model.task'), isA<BundledSource>());
    });

    test('the app\'s file missing fails before anything changes', () async {
      final copy = await downloaded();

      await expectLater(
        fromFile('${user.path}/gone/model.task'),
        throwsA(
          isA<ModelStorageException>().having(
            (e) => e.message,
            'message',
            contains('gone/model.task'),
          ),
        ),
      );
      expect(await sourceOf('model.task'), isA<NetworkSource>());
      expect(copy.existsSync(), isTrue);
    });
  });

  group('a download of a name the app installed', () {
    test('replaces the app\'s file elsewhere, which stays', () async {
      final picked = userFile('picked/model.task', _model(2));
      await fromFile(picked.path);

      await fromNetwork('https://a.example/m/model.task');

      expect(await sourceOf('model.task'), isA<NetworkSource>());
      expect(picked.existsSync(), isTrue);
      final registry = ServiceRegistry.instance.protectedFilesRegistry;
      expect(await registry.getExternalPath('model.task'), isNull);
      expect(await registry.isProtected('model.task'), isFalse);
    });

    test('is refused where it would overwrite the app\'s file', () async {
      final mine = File('${await coreDir()}/model.task')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_model(7));
      await fromFile(mine.path);

      await expectLater(
        fromNetwork('https://a.example/m/model.task'),
        throwsA(
          isA<ModelStorageException>().having(
            (e) => e.message,
            'message',
            contains('installed with fromFile'),
          ),
        ),
      );
      expect(downloads.requested, isEmpty);
      expect(mine.readAsBytesSync()[0], 7);
      expect(await sourceOf('model.task'), FileSource(mine.path));
    });

    test('is not refused by an app\'s file that is gone', () async {
      final mine = File('${await coreDir()}/model.task')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_model(7));
      await fromFile(mine.path);
      mine.deleteSync();

      await fromNetwork('https://a.example/m/model.task');

      expect(await sourceOf('model.task'), isA<NetworkSource>());
    });
  });

  group('a download of a name core downloaded', () {
    test('from the same URL is not downloaded again', () async {
      await downloaded('https://a.example/m/model.task');
      downloads.requested.clear();

      await fromNetwork('https://a.example/m/model.task');
      await fromNetwork('https://a.example/m/model.task?download=true');
      await fromNetwork('https://a.example/m/model.task', token: 'hf_x');

      expect(downloads.requested, isEmpty);
    });

    test('from another URL is downloaded again', () async {
      await downloaded('https://a.example/m/model.task');
      downloads.requested.clear();

      await fromNetwork('https://b.example/other/model.task');

      expect(downloads.requested, ['https://b.example/other/model.task']);
      expect(
        await sourceOf('model.task'),
        NetworkSource('https://b.example/other/model.task'),
      );
    });

    test('whose copy was cut short is downloaded again', () async {
      final copy = await downloaded();
      copy.writeAsBytesSync(Uint8List(10));
      downloads.requested.clear();

      await fromNetwork('https://a.example/m/model.task');

      expect(downloads.requested, hasLength(1));
    });

    test('from the same URL is not refused by another name the app put on '
        'core\'s copy', () async {
      final copy = await downloaded();
      await saveRecord('other.task', FileSource(copy.path));

      await fromNetwork('https://a.example/m/model.task');

      expect(await sourceOf('model.task'), isA<NetworkSource>());
    });

    test(
      'forgets a registration an older release left under its name',
      () async {
        await downloaded();
        final registry = ServiceRegistry.instance.protectedFilesRegistry;
        await registry.protect('model.task');
        await registry.registerExternalPath(
          'model.task',
          '${user.path}/x.task',
        );

        await fromNetwork('https://a.example/m/model.task');

        expect(await registry.getExternalPath('model.task'), isNull);
        expect(await registry.isProtected('model.task'), isFalse);
      },
    );

    test('whose copy is gone is downloaded again', () async {
      final copy = await downloaded();
      copy.deleteSync();
      downloads.requested.clear();

      await fromNetwork('https://a.example/m/model.task');

      expect(downloads.requested, hasLength(1));
      expect(copy.existsSync(), isTrue);
    });
  });

  group('releasing core\'s earlier copy', () {
    test(
      'one an install did not get to is released at the next start',
      () async {
        final copy = await downloaded();
        await installStoppedBeforeRelease(userFile('p/model.task', _model(2)));
        expect(copy.existsSync(), isTrue);

        await restart();

        expect(copy.existsSync(), isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(PreferencesKeys.pendingCopyReleases), isNull);
      },
    );

    test('one that cannot be deleted yet does not fail the install, and goes '
        'at the next start', () async {
      final copy = await downloaded();
      await useServices(fileSystem: _UndeletableFileSystem(copy.path));
      final picked = userFile('p/model.task', _model(2));

      await fromFile(picked.path);

      expect(copy.existsSync(), isTrue);
      expect(await sourceOf('model.task'), FileSource(picked.path));
      await useServices();
      await restart();
      expect(copy.existsSync(), isFalse);
    });

    test(
      'one another record reads is kept, and released once none does',
      () async {
        final copy = await downloaded();
        await installStoppedBeforeRelease(userFile('p/model.task', _model(2)));
        await saveRecord('other.task', FileSource(copy.path));

        await restart();

        expect(copy.existsSync(), isTrue);
        await records().deleteModel('other.task');
        await restart();
        expect(copy.existsSync(), isFalse);
      },
    );

    test('one journaled while a release runs is not lost', () async {
      final copyA = await downloadedNamed('a.task');
      final copyB = await downloadedNamed('b.task');
      await installStoppedBeforeRelease(userFile('p/a.task', _model(2)));
      final gated = _GatedFileSystem(copyA.path);
      await useServices(fileSystem: gated);

      final releasing = releasePendingCopies();
      await gated.entered.future;
      final installingB = installStoppedBeforeRelease(
        userFile('p/b.task', _model(3)),
      );
      gated.gate.complete();
      await releasing;
      await installingB;

      expect(copyA.existsSync(), isFalse);
      expect(await journal(), contains('b.task'));
      await useServices();
      await restart();
      expect(copyB.existsSync(), isFalse);
    });

    test('one in a model directory that has moved is released there', () async {
      // iOS moves the app's container on an update.
      final copy = await downloaded();
      await installStoppedBeforeRelease(userFile('p/model.task', _model(2)));
      final moved = Directory('${user.path}/new-support');
      support.renameSync(moved.path);
      PathProviderPlatform.instance = _FixedPathProviderPlatform(
        documentsPath: docs.path,
        appSupportPath: moved.path,
      );
      await useServices();

      await restart();

      expect(
        File(copy.path.replaceFirst(support.path, moved.path)).existsSync(),
        isFalse,
      );
      expect(await journal(), isNull);
    });

    test('one an old desktop install left in the user\'s Documents is never '
        'deleted', () async {
      // Before 0.15.1 desktop downloads went to Documents, which core still
      // reads from but does not own.
      final legacy = File('${docs.path}/model.task')
        ..writeAsBytesSync(_model(1));
      await records().saveModel(
        repo.ModelInfo(
          id: 'model.task',
          source: NetworkSource('https://a.example/m/model.task'),
          installedAt: DateTime(2026),
          sizeBytes: 1,
          type: repo.ModelType.inference,
          hasLoraWeights: false,
        ),
      );

      await fromFile(userFile('p/model.task', _model(2)).path);
      await restart();

      expect(legacy.existsSync(), isTrue);
    });

    test('one that is no longer the file that was journaled is kept', () async {
      final copy = await downloaded();
      await installStoppedBeforeRelease(userFile('p/model.task', _model(2)));
      // Something else wrote this name since: as large, but later.
      copy.writeAsBytesSync(_model(5));
      copy.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));

      await restart();

      expect(copy.existsSync(), isTrue);
      expect(await journal(), isNull, reason: 'not that copy any more');
    });
  });

  group('ensureModelReadyFromSpec', () {
    test('releases core\'s copy the app\'s file replaced', () async {
      final copy = await downloaded();
      final picked = userFile('p/model.task', _model(2));

      await FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
        InferenceModelSpec(
          name: 'model',
          modelSource: FileSource(picked.path),
          modelType: ModelType.gemmaIt,
        ),
      );

      expect(copy.existsSync(), isFalse);
      expect(await sourceOf('model.task'), FileSource(picked.path));
    });

    test('so does the legacy setModelPath', () async {
      final copy = await downloaded();
      final picked = userFile('p/model.task', _model(2));

      // ignore: deprecated_member_use_from_same_package
      await FlutterEdgeAiPlugin.instance.modelManager.setModelPath(picked.path);

      expect(copy.existsSync(), isFalse);
    });

    test('reports a failed install as a ModelStorageException', () async {
      downloads.fail = true;

      await expectLater(
        FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
          InferenceModelSpec(
            name: 'model',
            modelSource: NetworkSource('https://a.example/m/model.task'),
            modelType: ModelType.gemmaIt,
          ),
        ),
        throwsA(isA<ModelStorageException>()),
      );
    });

    test('records a companion under its namespaced name', () async {
      final spec = SttModelSpec(
        name: 'stt',
        modelSource: NetworkSource('https://a.example/stt.tflite'),
        tokenizerSource: NetworkSource('https://a.example/tokenizer.json'),
        sttModelType: SttModelType.moonshine,
      );

      await FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
        spec,
      );

      for (final file in spec.files) {
        expect(await records().isInstalled(file.filename), isTrue);
      }
    });
  });
}

/// Writes a model-sized file for each download and records the URLs asked
/// for.
class _Downloads implements DownloadService {
  final List<String> requested = [];

  /// Every download fails, like a lost connection.
  bool fail = false;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requested.add(url);
    if (fail) throw const SocketException('offline');
    await File(targetPath).writeAsBytes(_model(1));
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

/// A file system whose delete of one file waits until the test lets it go.
class _GatedFileSystem extends PlatformFileSystemService {
  _GatedFileSystem(this.held);
  final String held;
  final entered = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<void> deleteFile(String filePath) async {
    if (path.equals(filePath, held)) {
      entered.complete();
      await gate.future;
    }
    await super.deleteFile(filePath);
  }
}

/// A file system whose bundled resources are files in [bundle], read in
/// place as the iOS bundle is.
class _BundleFiles extends PlatformFileSystemService {
  _BundleFiles(this.bundle);
  final Directory bundle;

  @override
  Future<String> getBundledResourcePath(String resourceName) async =>
      '${bundle.path}/$resourceName';
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
