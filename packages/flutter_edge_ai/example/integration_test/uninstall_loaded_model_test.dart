// Uninstalling a model while it is loaded, on a real engine: the model
// getActiveModel built, its chat, a generation in flight, a model of another
// file, and a model openModel opened on the same file.
//
// Model functiongemma-270M-it.litertlm, staged as for
// install_rule_device_test.dart: Android /data/local/tmp/flutter_gemma_test/,
// Linux and macOS ~/models (the app container's home on macOS), Windows
// %USERPROFILE%\models.
// Run: flutter test integration_test/uninstall_loaded_model_test.dart -d <id>
//
// No setUp/setUpAll: each test prepares itself, so a failure is reported as
// that test's failure, never as an empty, green run.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
// ignore: implementation_imports — writes the install records a download leaves
import 'package:flutter_edge_ai/src/di/service_registry.dart';
// ignore: implementation_imports — writes the install records a download leaves
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;

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

repo.ModelRepository get _records => ServiceRegistry.instance.modelRepository;

Future<String> _coreDir() =>
    ServiceRegistry.instance.fileSystemService.getModelStorageDirectory();

Future<void> _record(String name, File file) => _records.saveModel(
  repo.ModelInfo(
    id: name,
    source: NetworkSource('https://example.com/m/$name'),
    installedAt: DateTime.now(),
    sizeBytes: file.lengthSync(),
    type: repo.ModelType.inference,
    hasLoraWeights: false,
  ),
);

/// core's copy of the staged model under [name], recorded as a download and
/// made the active inference model.
Future<(InferenceModelSpec, File)> _activeCopy(String name) async {
  final staged = File(_stagedModel);
  expect(staged.existsSync(), isTrue, reason: 'stage $_stagedModel');
  final copy = staged.copySync(path.join(await _coreDir(), name));
  await _record(name, copy);
  final spec = InferenceModelSpec(
    name: path.basenameWithoutExtension(name),
    modelSource: NetworkSource('https://example.com/m/$name'),
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.litertlm,
  );
  await FlutterEdgeAiPlugin.instance.modelManager.ensureModelReadyFromSpec(
    spec,
  );
  return (spec, copy);
}

Future<InferenceModel> _active() => FlutterEdgeAi.getActiveModel(
  maxTokens: 1024,
  preferredBackend: PreferredBackend.cpu,
);

Future<String> _reply(InferenceChat chat) async {
  await chat.addQuery(
    const Message(text: 'What is 2+2? Answer briefly.', isUser: true),
  );
  final response = await chat.generateChatResponse();
  return response is TextResponse ? response.token : response.toString();
}

Future<String> _ask(InferenceModel model) async {
  final chat = await model.createChat(modelType: ModelType.functionGemma);
  try {
    return await _reply(chat);
  } finally {
    await chat.close();
  }
}

/// What [run] ended with: null when it completed, otherwise its error — a
/// hang included, as a [TimeoutException].
Future<Object?> _outcome(Future<Object?> Function() run) async {
  try {
    await run().timeout(const Duration(seconds: 90));
    return null;
  } catch (e) {
    return e;
  }
}

String _describe(Object? outcome) =>
    outcome == null ? 'ok' : '${outcome.runtimeType}: $outcome';

/// Drops what a test left under [name]: its record, the active identity, and
/// the files at [paths].
Future<void> _cleanUp(String name, [List<String> paths = const []]) async {
  await _records.deleteModel(name);
  await FlutterEdgeAi.clearActiveInferenceIdentity();
  for (final p in paths) {
    final file = File(p);
    if (file.existsSync()) file.deleteSync();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uninstalling the loaded model\'s file closes that model', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'uninstall-loaded.litertlm';
    final (_, copy) = await _activeCopy(name);
    final model = await _active();
    final chat = await model.createChat(modelType: ModelType.functionGemma);
    InferenceModel? again;
    try {
      expect((await _reply(chat)).trim(), isNotEmpty);

      final uninstall = await _outcome(
        () => FlutterEdgeAi.uninstallModel(name),
      );
      final replyAfter = await _outcome(() => _reply(chat));
      final activeAfter = await _outcome(_active);
      debugPrint(
        '[b88] loaded: uninstall=${_describe(uninstall)} '
        'copyExists=${copy.existsSync()} isClosed=${model.isClosed} '
        'initializedModel=${FlutterEdgeAiPlugin.instance.initializedModel} '
        'replyAfter=${_describe(replyAfter)} '
        'getActiveModel=${_describe(activeAfter)}',
      );
      expect(uninstall, isNull);
      expect(copy.existsSync(), isFalse);
      expect(model.isClosed, isTrue);
      expect(FlutterEdgeAiPlugin.instance.initializedModel, isNull);
      expect(replyAfter, isNotNull, reason: 'the chat of a closed model');
      expect(activeAfter, isA<NoActiveModelError>());

      // Installed again, it is a new model, and it generates.
      await _activeCopy(name);
      again = await _active();
      expect(again, isNot(same(model)));
      expect((await _ask(again)).trim(), isNotEmpty);
    } finally {
      await _outcome(chat.close);
      await again?.close();
      await model.close();
      await _cleanUp(name, [copy.path]);
    }
  });

  testWidgets('uninstalling during a generation stops the generation', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'uninstall-streaming.litertlm';
    final (_, copy) = await _activeCopy(name);
    final model = await _active();
    // A session, the path every model's generation takes.
    final session = await model.createSession();
    StreamSubscription<String>? subscription;
    try {
      await session.addQueryChunk(
        const Message(
          text: 'Count from 1 to 300, one number per line.',
          isUser: true,
        ),
      );
      var chunks = 0;
      final first = Completer<void>();
      final ended = Completer<String>();
      subscription = session.getResponseAsync().listen(
        (_) {
          chunks++;
          if (!first.isCompleted) first.complete();
        },
        onError: (Object e) {
          if (!ended.isCompleted) ended.complete('error ${e.runtimeType}: $e');
        },
        onDone: () {
          if (!ended.isCompleted) ended.complete('done');
        },
      );
      await first.future.timeout(const Duration(seconds: 60));

      final chunksBefore = chunks;
      final watch = Stopwatch()..start();
      final uninstall = await _outcome(
        () => FlutterEdgeAi.uninstallModel(name),
      );
      final uninstallMs = watch.elapsedMilliseconds;
      final chunksAtReturn = chunks;
      final end = await ended.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => 'no end within 60 s',
      );
      debugPrint(
        '[b88] streaming: uninstall=${_describe(uninstall)} in ${uninstallMs}ms '
        'chunks before=$chunksBefore at return=$chunksAtReturn '
        'at end=$chunks end=$end copyExists=${copy.existsSync()} '
        'isClosed=${model.isClosed}',
      );
      expect(uninstall, isNull);
      expect(copy.existsSync(), isFalse);
      expect(model.isClosed, isTrue);
      expect(end, isNot('no end within 60 s'));
      // Stopped by the close the uninstall waited for, not run to its end:
      // left open, the model went on for tens of chunks after the uninstall
      // returned (macOS 42, Windows 19).
      expect(chunks - chunksAtReturn, lessThanOrEqualTo(1));
    } finally {
      await subscription?.cancel();
      await _outcome(session.close);
      await model.close();
      await _cleanUp(name, [copy.path]);
    }
  });

  testWidgets('uninstalling another file leaves the loaded model', (_) async {
    await registerTestEngines();
    const name = 'uninstall-kept.litertlm';
    const other = 'uninstall-other.task';
    final (_, copy) = await _activeCopy(name);
    final otherFile = File(path.join(await _coreDir(), other))
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(1024 * 1024 + 1));
    await _record(other, otherFile);
    final model = await _active();
    try {
      final uninstall = await _outcome(
        () => FlutterEdgeAi.uninstallModel(other),
      );
      debugPrint(
        '[b88] other: uninstall=${_describe(uninstall)} '
        'otherExists=${otherFile.existsSync()} isClosed=${model.isClosed}',
      );
      expect(uninstall, isNull);
      expect(otherFile.existsSync(), isFalse);
      expect(model.isClosed, isFalse);
      expect(FlutterEdgeAiPlugin.instance.initializedModel, same(model));
      expect(await _active(), same(model));
      expect((await _ask(model)).trim(), isNotEmpty);
    } finally {
      await model.close();
      await _records.deleteModel(other);
      await _cleanUp(name, [copy.path, otherFile.path]);
    }
  });

  testWidgets('uninstalling a file leaves the models openModel opened on it', (
    _,
  ) async {
    await registerTestEngines();
    const name = 'uninstall-opened.litertlm';
    final (spec, copy) = await _activeCopy(name);
    final opened = await FlutterEdgeAi.openModel(
      spec,
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );
    try {
      final uninstall = await _outcome(
        () => FlutterEdgeAi.uninstallModel(name),
      );
      final replyAfter = await _outcome(() => _ask(opened));
      debugPrint(
        '[b88] opened: uninstall=${_describe(uninstall)} '
        'copyExists=${copy.existsSync()} isClosed=${opened.isClosed} '
        'replyAfter=${_describe(replyAfter)}',
      );
      expect(opened.isClosed, isFalse);
      if (!Platform.isWindows) {
        // POSIX unlinks a mapped file; the open model keeps its pages.
        expect(uninstall, isNull);
        expect(replyAfter, isNull);
      }
    } finally {
      await opened.close();
      // Windows keeps a mapped file: the uninstall can only finish now.
      if (await _records.loadModel(name) != null) {
        await _outcome(() => FlutterEdgeAi.uninstallModel(name));
      }
      await _cleanUp(name, [copy.path]);
    }
  });
}
