// The installation builders' catalog entries and the options under them:
// an LLM under a name of its own (fromNetwork(filename:)), expectedSize /
// expectedSha256 before activation, and the embedder and STT withProgress by
// bytes.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    });
  });

  group('expectedSize and expectedSha256', () {
    test('a file of another size stays installed, not active', () async {
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeBefore = manager.activeInferenceModel?.name;
      expect(activeBefore, isNot('model'));
      await expectLater(
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
              .having((e) => e.toString(), 'toString', contains('123 bytes')),
        ),
      );
      expect(manager.activeInferenceModel?.name, activeBefore);
      expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isTrue);
    });

    test('the right sha256 passes; another one throws', () async {
      final right = '${sha256.convert(Uint8List(_unit))}';
      await llm()
          .fromNetwork(
            'https://example.com/repo/model.litertlm',
            expectedSha256: right,
          )
          .install();
      await expectLater(
        llm()
            .fromNetwork(
              'https://example.com/repo/model.litertlm',
              expectedSha256: 'f' * 64,
            )
            .install(),
        throwsA(
          isA<ModelValidationException>().having(
            (e) => e.message,
            'message',
            contains('sha256'),
          ),
        ),
      );
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
  sha256: 'aa',
  sizeBytes: size,
  installFilename: path,
);

final class _Embedder extends EmbedderVariant {
  @override
  ModelArtifact get model => _artifact('emb.tflite', 3 * _unit);

  @override
  ModelArtifact? get tokenizer => _artifact('tok.model', _unit);

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

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) => File(targetPath).writeAsBytes(_bytesFor(url));

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    yield 50;
    await File(targetPath).writeAsBytes(_bytesFor(url));
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
