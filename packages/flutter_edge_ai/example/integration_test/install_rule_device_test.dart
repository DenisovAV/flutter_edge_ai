// The install rule (lib/src/model_management/install_rule.dart) on a real
// device, where host tests cannot reach: another spelling of core's copy
// (Android's bind mount of the app's data, a directory link on desktop),
// deleting and journaling on the device's file system — a copy a loaded
// model maps included, which Windows will not delete —, and a `fromFile`
// model restored after a restart that still generates.
//
// Model functiongemma-270M-it.litertlm: Android /data/local/tmp/
// flutter_gemma_test/ (FTL --other-files), Linux ~/models, Windows
// %USERPROFILE%\models.
// Run: flutter test integration_test/install_rule_device_test.dart -d <id>
//
// No setUp/setUpAll: each test prepares itself, so a failure is reported as
// that test's failure, never as an empty, green run.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
// ignore: implementation_imports — resets core's services between runs
import 'package:flutter_edge_ai/src/di/service_registry.dart';
// ignore: implementation_imports — device test of core's install rule
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
// ignore: implementation_imports — inspects the repository records the install rule writes
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
// ignore: implementation_imports — device test of the mobile model manager's install paths
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelFile = 'functiongemma-270M-it.litertlm';

String get _stagedModel {
  if (Platform.isAndroid) {
    return '/data/local/tmp/flutter_gemma_test/$_modelFile';
  }
  if (Platform.isWindows) {
    return '${Platform.environment['USERPROFILE']}\\models\\$_modelFile';
  }
  return '${Platform.environment['HOME']}/models/$_modelFile';
}

/// Over the 1 MB floor install validation applies to model files.
Uint8List _bytes(int mark) => Uint8List(1024 * 1024 + 1)..[0] = mark;

repo.ModelRepository get _records => ServiceRegistry.instance.modelRepository;

Future<String> _coreDir() =>
    ServiceRegistry.instance.fileSystemService.getModelStorageDirectory();

/// core's copy of [name]: a file in the model directory recorded as a
/// download, as a network install leaves it.
Future<File> _coreCopy(String name) async {
  final file = File(path.join(await _coreDir(), name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(_bytes(1));
  await _records.saveModel(
    repo.ModelInfo(
      id: name,
      source: NetworkSource('https://example.com/m/$name'),
      installedAt: DateTime.now(),
      sizeBytes: file.lengthSync(),
      type: repo.ModelType.inference,
      hasLoraWeights: false,
    ),
  );
  return file;
}

/// A file of the app's own, outside the model directory.
Future<File> _appFile(String name, int mark) async {
  final dir = await getApplicationSupportDirectory();
  return File(path.join(dir.path, 'picked', name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(_bytes(mark));
}

Future<void> _fromFile(String path) => FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.task,
).fromFile(path).install();

Future<ModelSource?> _sourceOf(String name) async =>
    (await _records.loadModel(name))?.source;

/// Drops what a test left under [name]: its record, its registration, and
/// the files at [paths].
Future<void> _cleanUp(String name, [List<String> paths = const []]) async {
  await _records.deleteModel(name);
  final registry = ServiceRegistry.instance.protectedFilesRegistry;
  await registry.unprotect(name);
  await registry.unregisterExternalPath(name);
  for (final p in paths) {
    final file = File(p);
    if (file.existsSync()) file.deleteSync();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('core\'s copy picked under another spelling stays core\'s', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'rule-alias.task';
    final copy = await _coreCopy(name);
    final String alias;
    if (Platform.isAndroid) {
      // Android mounts the app's data directory at both spellings.
      alias = copy.path.replaceFirst('/data/user/0/', '/data/data/');
    } else {
      // A directory link to the model directory (a junction on Windows).
      final temp = await getTemporaryDirectory();
      final link = Link(path.join(temp.path, 'rule-alias-dir'));
      if (link.existsSync()) link.deleteSync();
      link.createSync(copy.parent.path);
      alias = path.join(link.path, name);
    }
    debugPrint(
      '[rule] copy=${copy.path} alias=$alias '
      'identical=${FileSystemEntity.identicalSync(alias, copy.path)} '
      'realpath=${File(alias).resolveSymbolicLinksSync()}',
    );
    expect(alias, isNot(copy.path));

    await _fromFile(alias);

    expect(await _sourceOf(name), isA<NetworkSource>());
    expect(copy.existsSync(), isTrue);
    await FlutterEdgeAi.uninstallModel(name);
    expect(copy.existsSync(), isFalse, reason: 'core\'s, so uninstalled');
    await _cleanUp(name);
  });

  testWidgets('an app file elsewhere replaces core\'s copy, which goes', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'rule-replace.task';
    final copy = await _coreCopy(name);
    final picked = await _appFile(name, 2);

    await _fromFile(picked.path);

    debugPrint('[rule] replace: copy exists=${copy.existsSync()}');
    expect(await _sourceOf(name), FileSource(picked.path));
    expect(copy.existsSync(), isFalse);
    expect(picked.existsSync(), isTrue);
    await FlutterEdgeAi.uninstallModel(name);
    expect(picked.existsSync(), isTrue, reason: 'the app\'s, so kept');
    await _cleanUp(name, [picked.path]);
  });

  testWidgets('a release the app did not get to is done at the next start', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'rule-journal.task';
    final copy = await _coreCopy(name);
    final picked = await _appFile(name, 3);
    // Installed the way an installer does, stopped before the release.
    await installPlanned(
      await planInstall(
        InferenceModelSpec(
          name: 'rule-journal',
          modelSource: FileSource(picked.path),
          modelType: ModelType.gemmaIt,
        ).files,
      ),
      modelType: repo.ModelType.inference,
    );
    expect(copy.existsSync(), isTrue);

    await MobileModelManager().initialize();

    debugPrint('[rule] journal: copy exists=${copy.existsSync()}');
    expect(copy.existsSync(), isFalse);
    await _cleanUp(name, [picked.path]);
  });

  testWidgets('a download onto the app\'s file is refused', (_) async {
    await registerTestEngines();
    const name = 'rule-collision.task';
    final mine = File(path.join(await _coreDir(), name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(7));
    await _fromFile(mine.path);

    await expectLater(
      FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromNetwork('https://example.com/m/$name').install(),
      throwsA(isA<ModelStorageException>()),
    );

    expect(mine.readAsBytesSync()[0], 7);
    expect(await _sourceOf(name), FileSource(mine.path));
    await _cleanUp(name, [mine.path]);
  });

  testWidgets('core\'s copy a loaded model maps goes once it can', (_) async {
    await registerTestEngines();
    final staged = File(_stagedModel);
    expect(staged.existsSync(), isTrue, reason: 'stage $_stagedModel');
    const name = 'rule-loaded.litertlm';
    const url = 'https://example.com/m/$name';
    // core's copy of a model, recorded as a download, active and loaded.
    final copy = staged.copySync(path.join(await _coreDir(), name));
    await _records.saveModel(
      repo.ModelInfo(
        id: name,
        source: NetworkSource(url),
        installedAt: DateTime.now(),
        sizeBytes: copy.lengthSync(),
        type: repo.ModelType.inference,
        hasLoraWeights: false,
      ),
    );
    await FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
      InferenceModelSpec(
        name: 'rule-loaded',
        modelSource: NetworkSource(url),
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.litertlm,
      ),
    );
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );
    final picked = staged.copySync(
      path.join((await getApplicationSupportDirectory()).path, 'picked', name),
    );

    try {
      // The app's own file replaces the copy while the engine maps it.
      await FlutterEdgeAi.installModel(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.litertlm,
      ).fromFile(picked.path).install();

      expect(await _sourceOf(name), FileSource(picked.path));
      debugPrint(
        '[rule] loaded copy right after the install: '
        'exists=${copy.existsSync()}',
      );
      if (!Platform.isWindows) {
        // Unlinking a mapped file works on POSIX.
        expect(copy.existsSync(), isFalse);
      }
    } finally {
      await model.close();
    }

    await MobileModelManager().initialize();

    debugPrint('[rule] loaded copy after restart: exists=${copy.existsSync()}');
    expect(copy.existsSync(), isFalse);
    await FlutterEdgeAi.uninstallModel(name);
    await FlutterEdgeAi.clearActiveInferenceIdentity();
    await _cleanUp(name, [picked.path]);
  });

  testWidgets('a fromFile model is active after a restart and generates; '
      'uninstall keeps the file', (_) async {
    await registerTestEngines();
    final pushed = File(_stagedModel);
    expect(pushed.existsSync(), isTrue, reason: 'stage $_stagedModel');
    await FlutterEdgeAi.installModel(
      modelType: ModelType.functionGemma,
      fileType: ModelFileType.litertlm,
    ).fromFile(pushed.path).install();

    // A restart: a new manager restores from what this run persisted.
    final restarted = MobileModelManager();
    await restarted.initialize();
    final restored = restarted.activeInferenceModel as InferenceModelSpec?;
    debugPrint('[rule] restored=${restored?.modelSource}');
    expect(restored?.modelSource, FileSource(pushed.path));

    // The restored spec handed back is the same install, and it loads.
    await FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
      restored!,
    );
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );
    try {
      final chat = await model.createChat(modelType: ModelType.functionGemma);
      await chat.addQuery(
        const Message(text: 'What is 2+2? Answer briefly.', isUser: true),
      );
      final response = await chat.generateChatResponse();
      final text = response is TextResponse
          ? response.token
          : response.toString();
      debugPrint('[rule] response=$text');
      expect(text.trim(), isNotEmpty);
      await chat.close();
    } finally {
      await model.close();
    }

    await FlutterEdgeAi.uninstallModel(_modelFile);
    await FlutterEdgeAi.clearActiveInferenceIdentity();
    debugPrint('[rule] after uninstall: exists=${pushed.existsSync()}');
    expect(pushed.existsSync(), isTrue, reason: 'the app\'s file stays');
  });
}
