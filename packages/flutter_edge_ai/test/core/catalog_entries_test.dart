// The installation builders' catalog entries and the options under them:
// an LLM under a name of its own (fromNetwork(filename:)), expectedSize
// before activation, and the embedder and STT withProgress by bytes.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart'
    show activeFileRefusal;
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/catalog_fixtures.dart' show clearActiveModels;

/// Over the 1 MiB core requires of a model file.
const _unit = 2 * 1024 * 1024;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late Directory support;
  late _Downloads downloads;
  late _Probe probe;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    documents = await Directory.systemTemp.createTemp('catalog_entries_docs_');
    support = await Directory.systemTemp.createTemp('catalog_entries_sup_');
    PathProviderPlatform.instance = _Paths(documents.path, support.path);
    ServiceRegistry.reset();
    final sizes = {
      'model.litertlm': _unit,
      'emb.tflite': 3 * _unit,
      'tok.model': _unit,
      'stt.tflite': 3 * _unit,
      'tokenizer.json': _unit,
    };
    downloads = _Downloads(sizes);
    probe = _Probe(sizes);
    await ServiceRegistry.initialize(
      downloadService: downloads,
      remoteSizeProbe: probe,
    );
    await clearActiveModels();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [documents, support]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  InferenceInstallationBuilder llm() => FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  );

  group('an LLM under a name of its own', () {
    test('installs, is found, has a path, uninstalls by that name', () async {
      final installation = await llm()
          .fromNetwork(
            'https://example.com/repo/model.litertlm',
            filename: 'phi-4-mini-reasoning.litertlm',
          )
          .install();
      expect(
        installation.spec.files.single.filename,
        'phi-4-mini-reasoning.litertlm',
      );
      expect(
        await FlutterEdgeAi.isModelInstalled('phi-4-mini-reasoning.litertlm'),
        isTrue,
      );
      expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isFalse);
      expect(
        await FlutterEdgeAi.getModelPath('phi-4-mini-reasoning.litertlm'),
        endsWith('phi-4-mini-reasoning.litertlm'),
      );
      await FlutterEdgeAi.uninstallModel('phi-4-mini-reasoning.litertlm');
      expect(
        await FlutterEdgeAi.isModelInstalled('phi-4-mini-reasoning.litertlm'),
        isFalse,
      );
    });

    test('is the active model again after a restart', () async {
      await llm()
          .fromNetwork(
            'https://example.com/repo/model.litertlm',
            filename: 'phi-4-mini-reasoning.litertlm',
          )
          .install();
      final restarted = MobileModelManager();
      await restarted.initialize();
      final active = restarted.activeInferenceModel;
      expect(active, isA<InferenceModelSpec>());
      expect(active!.files.single.filename, 'phi-4-mini-reasoning.litertlm');
    });

    test('a name its URL gives is restored as it was installed, even one '
        'that is not portable', () async {
      await llm()
          .fromNetwork('https://example.com/repo/gemma%3A2b.litertlm')
          .install();
      final restarted = MobileModelManager();
      await restarted.initialize();
      expect(
        restarted.activeInferenceModel?.files.single.filename,
        'gemma:2b.litertlm',
      );
    });

    test('keeps the source\'s extension', () {
      expect(
        () => InferenceModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://example.com/model.task'),
          modelType: ModelType.gemmaIt,
          filename: 'x.litertlm',
        ),
        throwsArgumentError,
      );
      expect(
        () => InferenceModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://example.com/model.task'),
          modelType: ModelType.gemmaIt,
          filename: 'dir/x.task',
        ),
        throwsArgumentError,
      );
      for (final name in ['CON.task', 'a:b.task']) {
        expect(
          () => InferenceModelSpec(
            name: 'x',
            modelSource: ModelSource.network('https://example.com/model.task'),
            modelType: ModelType.gemmaIt,
            filename: name,
          ),
          throwsArgumentError,
          reason: name,
        );
      }
    });
  });

  group('expectedSize', () {
    test('a file of another size is deleted with its record; a retry '
        'downloads it again', () async {
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      Future<void> attempt() => expectLater(
        llm()
            .fromNetwork(
              'https://example.com/repo/model.litertlm',
              expectedSize: 123,
            )
            .install(),
        throwsA(
          isA<ModelValidationException>()
              .having((e) => e.expectedSize, 'expectedSize', 123)
              .having((e) => e.actualSize, 'actualSize', _unit)
              .having((e) => e.toString(), 'toString', contains('123 bytes'))
              .having((e) => e.message, 'message', contains('deleted')),
        ),
      );
      await attempt();
      expect(manager.activeInferenceModel, isNull);
      expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isFalse);
      final path = await ServiceRegistry.instance.fileSystemService
          .getReadTargetPath('model.litertlm');
      expect(File(path).existsSync(), isFalse);
      await attempt();
      expect(downloads.count, 2);
    });

    test('a file installed earlier is checked again; the active model\'s '
        'file is kept', () async {
      await llm()
          .fromNetwork('https://example.com/repo/model.litertlm')
          .install();
      await expectLater(
        llm()
            .fromNetwork(
              'https://example.com/repo/model.litertlm',
              expectedSize: 123,
            )
            .install(),
        throwsA(
          isA<ModelValidationException>().having(
            (e) => e.message,
            'message',
            contains('so it was kept'),
          ),
        ),
      );
      expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isTrue);
    });

    test(
      'a mismatch whose file cannot be deleted still loses its record',
      () async {
        if (Platform.isWindows) return; // directory permissions differ
        final locked = <String>[];
        downloads.afterWrite = (path) {
          locked.add(File(path).parent.path);
          Process.runSync('chmod', ['555', File(path).parent.path]);
        };
        addTearDown(() {
          for (final dir in locked) {
            Process.runSync('chmod', ['755', dir]);
          }
        });
        await expectLater(
          llm()
              .fromNetwork(
                'https://example.com/repo/model.litertlm',
                expectedSize: 123,
              )
              .install(),
          throwsA(
            isA<ModelValidationException>().having(
              (e) => e.cause,
              'cause',
              isNotNull,
            ),
          ),
        );
        expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isFalse);
      },
    );

    test('a negative size is refused before a download', () {
      expect(
        () => llm().fromNetwork(
          'https://example.com/m.litertlm',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => FlutterEdgeAi.installEmbedder().modelFromNetwork(
          'https://example.com/emb.tflite',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => FlutterEdgeAi.installStt().tokenizerFromNetwork(
          'https://example.com/tokenizer.json',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(downloads.count, 0);
    });

    test('an install over a file another kind\'s active model reads is '
        'refused', () async {
      await llm()
          .fromNetwork('https://example.com/repo/shared.litertlm')
          .install();
      final before = downloads.count;
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(
              'https://example.com/other/shared.litertlm',
              expectedSize: _unit,
            )
            .install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('the active inference model shared reads'),
          ),
        ),
      );
      expect(downloads.count, before);
    });

    test('the refusal names the kind and the uninstall call, in the words '
        'the example app reads', () {
      // example/lib/services/catalog_install.dart parses these sentences.
      expect(
        activeFileRefusal(
          "it's.litertlm",
          InferenceModelSpec(
            name: 'm',
            modelSource: ModelSource.network('https://example.com/m.litertlm'),
            modelType: ModelType.general,
            fileType: ModelFileType.litertlm,
          ),
        ),
        contains(r"(FlutterEdgeAi.uninstallModel('it\'s.litertlm'))"),
      );
      // A directory model (ORT-GenAI) is uninstalled by its name.
      expect(
        activeFileRefusal(
          'phi/genai_config.json',
          InferenceModelSpec(
            name: 'phi',
            modelSource: ModelSource.network('https://example.com/m.onnx'),
            modelType: ModelType.general,
            fileType: ModelFileType.onnx,
          ),
        ),
        contains("(FlutterEdgeAi.uninstallModel('phi'))"),
      );
      expect(
        activeFileRefusal(
          'm.litertlm',
          InferenceModelSpec(
            name: 'm',
            modelSource: ModelSource.network('https://example.com/m.litertlm'),
            modelType: ModelType.general,
            fileType: ModelFileType.litertlm,
          ),
        ),
        'This install would write m.litertlm over the file the active '
        'inference model m reads, and checks it only afterwards. Uninstall '
        "that model first (FlutterEdgeAi.uninstallModel('m.litertlm')), or "
        'install under another file name.',
      );
      for (final (spec, kind, call) in [
        (
          EmbeddingModelSpec(
            name: 'emb',
            modelSource: ModelSource.network('https://example.com/emb.tflite'),
            tokenizerSource: ModelSource.network(
              'https://example.com/tok.model',
            ),
          ),
          'embedding',
          'uninstallEmbedder()',
        ),
        (
          SttModelSpec(
            name: 'stt',
            modelSource: ModelSource.network('https://example.com/stt.tflite'),
            tokenizerSource: ModelSource.network(
              'https://example.com/tokenizer.json',
            ),
            sttModelType: SttModelType.moonshine,
          ),
          'speech-to-text',
          'uninstallStt()',
        ),
        (
          TtsModelSpec(
            name: 'matcha',
            sources: [ModelSource.network('https://example.com/m/a.tflite')],
            ttsModelType: TtsModelType.matcha,
          ),
          'text-to-speech',
          'uninstallTts()',
        ),
        (
          // The file in the way is named, quoted as a Dart string.
          InferenceModelSpec(
            name: "it's",
            modelSource: ModelSource.network('https://example.com/x'),
            modelType: ModelType.general,
            fileType: ModelFileType.litertlm,
          ),
          'inference',
          r"uninstallModel('x')",
        ),
      ]) {
        expect(
          activeFileRefusal('x', spec),
          'This install would write x over the file the active $kind model '
          '${spec.name} reads, and checks it only afterwards. Uninstall that '
          'model first (FlutterEdgeAi.$call), or install under another file '
          'name.',
        );
      }
    });

    test('a refused expectation leaves the builder as it was', () async {
      final builder = FlutterEdgeAi.installEmbedder().fromCatalog(_Embedder());
      expect(
        () => builder.modelFromNetwork(
          'https://example.com/x.tflite',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => builder.tokenizerFromNetwork(
          'https://example.com/x.model',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => builder.modelFromNetwork(
          'https://example.com/x.tflite',
          filename: '../x.tflite',
        ),
        throwsArgumentError,
      );
      // Still the catalog's files, not x.tflite.
      await builder.install();
      expect(await FlutterEdgeAi.isModelInstalled('emb.tflite'), isTrue);
      expect(await FlutterEdgeAi.isModelInstalled('x.tflite'), isFalse);
      expect(await FlutterEdgeAi.isModelInstalled('x.model'), isFalse);
    });

    test('a refused STT expectation leaves the builder as it was', () async {
      final builder = FlutterEdgeAi.installStt()
          .modelFromNetwork('https://example.com/stt.tflite')
          .tokenizerFromNetwork('https://example.com/tokenizer.json')
          .ofType(SttModelType.moonshine);
      expect(
        () => builder.modelFromNetwork(
          'https://example.com/x.tflite',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => builder.tokenizerFromNetwork(
          'https://example.com/x.json',
          expectedSize: -1,
        ),
        throwsArgumentError,
      );
      await builder.install();
      final active =
          FlutterEdgeAiPlugin.instance.modelManager.activeSttModel!
              as SttModelSpec;
      expect(
        active.modelSource,
        ModelSource.network('https://example.com/stt.tflite'),
      );
      expect(
        active.tokenizerSource,
        ModelSource.network('https://example.com/tokenizer.json'),
      );
    });

    test('fromCatalog with a tokenizer it refuses leaves the model as it '
        'was', () async {
      final builder = FlutterEdgeAi.installEmbedder()
          .modelFromNetwork('https://example.com/mine.tflite')
          .tokenizerFromNetwork('https://example.com/mine.model');
      expect(
        () => builder.fromCatalog(_Embedder(tokenizerSize: -1)),
        throwsArgumentError,
      );
      await builder.install();
      expect(
        FlutterEdgeAiPlugin.instance.modelManager.activeEmbeddingModel?.name,
        'mine',
      );
      expect(await FlutterEdgeAi.isModelInstalled('emb.tflite'), isFalse);
    });

    test('the embedder checks each file before it is active', () async {
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeBefore = manager.activeEmbeddingModel?.name;
      expect(activeBefore, isNot('emb'));
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .modelFromNetwork('https://example.com/emb.tflite')
            .tokenizerFromNetwork(
              'https://example.com/tok.model',
              expectedSize: 5,
            )
            .install(),
        throwsA(isA<ModelValidationException>()),
      );
      expect(manager.activeEmbeddingModel?.name, activeBefore);
    });
  });

  group('withProgress by bytes', () {
    test('the embedder weights its model and tokenizer by size', () async {
      final progress = <int>[];
      await FlutterEdgeAi.installEmbedder()
          .modelFromNetwork('https://example.com/emb.tflite')
          .tokenizerFromNetwork('https://example.com/tok.model')
          .withProgress(progress.add)
          .install();
      // 3 + 1 units; half of the model = 1.5 / 4 = 37%. Counting files: 25%.
      expect(progress.first, 37);
      expect(progress.last, 100);
      expect(probe.asked, hasLength(2));
    });

    test('STT weights its model and tokenizer by size', () async {
      final progress = <int>[];
      await FlutterEdgeAi.installStt()
          .modelFromNetwork('https://example.com/stt.tflite')
          .tokenizerFromNetwork('https://example.com/tokenizer.json')
          .ofType(SttModelType.moonshine)
          .withProgress(progress.add)
          .install();
      expect(progress.first, 37);
      expect(progress.last, 100);
    });

    test('embedder and STT say 100 only once the model is active', () async {
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final embedderAtHundred = <String?>[];
      await FlutterEdgeAi.installEmbedder()
          .modelFromNetwork('https://example.com/emb.tflite')
          .tokenizerFromNetwork('https://example.com/tok.model')
          .withProgress((p) {
            if (p == 100) {
              embedderAtHundred.add(manager.activeEmbeddingModel?.name);
            }
          })
          .install();
      expect(embedderAtHundred, ['emb']);
      final sttAtHundred = <String?>[];
      await FlutterEdgeAi.installStt()
          .modelFromNetwork('https://example.com/stt.tflite')
          .tokenizerFromNetwork('https://example.com/tokenizer.json')
          .ofType(SttModelType.moonshine)
          .withProgress((p) {
            if (p == 100) sttAtHundred.add(manager.activeSttModel?.name);
          })
          .install();
      expect(sttAtHundred, ['stt']);
    });

    test('the per-file callbacks still report each file', () async {
      final model = <int>[];
      final tokenizer = <int>[];
      await FlutterEdgeAi.installEmbedder()
          .modelFromNetwork('https://example.com/emb.tflite')
          .tokenizerFromNetwork('https://example.com/tok.model')
          .withModelProgress(model.add)
          .withTokenizerProgress(tokenizer.add)
          .withProgress((_) {})
          .install();
      expect(model, [50, 100]);
      expect(tokenizer, [50, 100]);
    });

    test('a catalog embedder uses its pinned sizes, with no HEAD', () async {
      final progress = <int>[];
      await FlutterEdgeAi.installEmbedder()
          .fromCatalog(_Embedder())
          .withProgress(progress.add)
          .install();
      expect(probe.asked, isEmpty);
      expect(progress.first, 37);
    });
  });
}

ModelArtifact _artifact(String path, int size) => ModelArtifact(
  repo: 'org/tiny',
  revision: '0123456789abcdef0123456789abcdef01234567',
  path: path,
  sha256: 'a' * 64,
  sizeBytes: size,
  installFilename: path,
);

final class _Embedder extends EmbedderVariant {
  _Embedder({this.tokenizerSize = _unit});

  final int tokenizerSize;

  @override
  ModelArtifact get model => _artifact('emb.tflite', 3 * _unit);

  @override
  ModelArtifact? get tokenizer => _artifact('tok.model', tokenizerSize);

  @override
  String get ragProfileId => 'tiny-v1';

  @override
  String get id => 'tiny/seq256';

  @override
  String get modelId => 'tiny';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.cpu};

  @override
  int get dimension => 8;

  @override
  int get maxInputTokens => 256;

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};
}

/// Answers each URL's size by its file name; records what it was asked.
final class _Probe implements RemoteSizeProbe {
  _Probe(this._sizes);

  final Map<String, int> _sizes;
  final asked = <String>[];

  @override
  Future<int?> sizeOf(
    String url, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    asked.add(url);
    return _sizes[Uri.parse(url).pathSegments.last];
  }
}

/// Writes each file at its size (zeros), reporting 50 and then 100.
final class _Downloads implements DownloadService {
  _Downloads(this._sizes);

  final Map<String, int> _sizes;

  Uint8List _bytesFor(String url) =>
      Uint8List(_sizes[Uri.parse(url).pathSegments.last] ?? _unit);

  /// Files written so far.
  int count = 0;

  /// Runs after each file is written, with its path.
  void Function(String path)? afterWrite;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    count++;
    await File(targetPath).writeAsBytes(_bytesFor(url));
    afterWrite?.call(targetPath);
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
    count++;
    yield 50;
    await File(targetPath).writeAsBytes(_bytesFor(url));
    afterWrite?.call(targetPath);
    yield 100;
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.documents, this.support);

  final String documents;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}
