// FlutterEdgeAi.catalog and installFromCatalog against core's real install
// path, with a download service that writes fixed bytes instead of fetching.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_fixtures.dart';

/// What every download writes; clears the handlers' minimum-size checks.
final _bytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late Directory support;
  late _Downloads downloads;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('catalog_docs_');
    support = await Directory.systemTemp.createTemp('catalog_support_');
    PathProviderPlatform.instance = _Paths(documents.path, support.path);
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    await FlutterEdgeAi.dispose();
    downloads = _Downloads();
  });

  tearDown(() async {
    await FlutterEdgeAi.dispose();
    for (final dir in [documents, support]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<void> initialize({List<TtsBackendProvider> tts = const []}) async {
    await ServiceRegistry.initialize(downloadService: downloads);
    await FlutterEdgeAi.initialize(ttsBackends: tts);
  }

  group('FlutterEdgeAi.catalog', () {
    test('throws before initialize', () {
      expect(() => FlutterEdgeAi.catalog, throwsStateError);
    });

    test('lists the catalogs of registered providers only', () async {
      final model = TestModel('tiny-llm', [TestLlm('generic')]);
      await initialize(
        tts: [
          _TtsWithCatalog(TestCatalog('c', [model])),
          _TtsWithoutCatalog(),
        ],
      );
      expect(FlutterEdgeAi.catalog.models, [same(model)]);
      await FlutterEdgeAi.dispose();
      expect(() => FlutterEdgeAi.catalog, throwsStateError);
    });
  });

  group('installFromCatalog, an LLM', () {
    test('installs with the variant\'s model and file type', () async {
      await initialize();
      final variant = TestLlm(
        'generic',
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      );
      final installation = await FlutterEdgeAi.installFromCatalog(
        variant,
      ).install();
      final spec = installation.spec as InferenceModelSpec;
      expect(spec.modelType, ModelType.gemma4);
      expect(spec.fileType, ModelFileType.litertlm);
      expect(spec.files.single.filename, 'generic.litertlm');
      expect(downloads.urls, [variant.file!.url]);
      expect(
        FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel?.name,
        spec.name,
      );
    });

    test('with activate false it is installed, not active', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeBefore = manager.activeInferenceModel?.name;
      final installation = await FlutterEdgeAi.installFromCatalog(
        TestLlm('inactive'),
      ).install(activate: false);
      expect(installation.spec, isA<InferenceModelSpec>());
      expect(installation.spec.name, 'inactive');
      expect(manager.activeInferenceModel?.name, activeBefore);
    });

    test('a file of another size than the catalog\'s fails loudly', () async {
      await initialize();
      final variant = TestLlm(
        'generic',
        file: artifact('generic.litertlm', size: 123),
      );
      await expectLater(
        FlutterEdgeAi.installFromCatalog(variant).install(),
        throwsA(
          isA<CatalogInstallException>().having(
            (e) => e.message,
            'message',
            allOf(contains('${_bytes.length} bytes'), contains('says 123')),
          ),
        ),
      );
    });

    test('the wrong size never becomes the active model', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      await FlutterEdgeAi.installFromCatalog(TestLlm('good')).install();
      await expectLater(
        FlutterEdgeAi.installFromCatalog(
          TestLlm('bad', file: artifact('bad.litertlm', size: 123)),
        ).install(),
        throwsA(isA<CatalogInstallException>()),
      );
      expect(manager.activeInferenceModel?.name, 'good');
    });

    test('a variant that runs on no backend here is refused before any '
        'download', () async {
      await initialize();
      await expectLater(
        FlutterEdgeAi.installFromCatalog(
          TestLlm('npu-elsewhere', backendsHere: const {}),
        ).install(),
        throwsUnsupportedError,
      );
      expect(downloads.urls, isEmpty);
    });

    test('progress ends at 100 when the file is already installed', () async {
      await initialize();
      await FlutterEdgeAi.installFromCatalog(TestLlm('again')).install();
      final progress = <int>[];
      await FlutterEdgeAi.installFromCatalog(
        TestLlm('again'),
      ).withProgress(progress.add).install();
      expect(downloads.urls, hasLength(1), reason: 'the second is skipped');
      expect(progress, isNotEmpty);
      expect(progress.last, 100);
    });

    test('an install name that is not the URL\'s file name is refused', () {
      final variant = TestLlm(
        'generic',
        file: artifact('generic.litertlm', installFilename: 'other.litertlm'),
      );
      expect(
        () => FlutterEdgeAi.installFromCatalog(variant).install(),
        throwsArgumentError,
      );
    });

    test('a variant with no file has nothing to install', () {
      expect(
        () => FlutterEdgeAi.installFromCatalog(
          TestLlm('builtin', noFile: true),
        ).install(),
        throwsUnsupportedError,
      );
    });
  });

  group('installFromCatalog, an embedder', () {
    TestEmbedder embedder() => TestEmbedder(
      model: artifact(
        'emb_256.tflite',
        installFilename: 'emb_256__rev-0123456789ab.tflite',
      ),
      tokenizer: artifact(
        'sentencepiece.model',
        installFilename: 'tiny-seq256__sentencepiece__rev-0123456789ab.model',
      ),
    );

    test('installs model and tokenizer under the catalog\'s names', () async {
      await initialize();
      final progress = <int>[];
      final installation = await FlutterEdgeAi.installFromCatalog(
        embedder(),
      ).withProgress(progress.add).install();
      expect(installation.spec.files.map((f) => f.filename), [
        'emb_256__rev-0123456789ab.tflite',
        'tiny-seq256__sentencepiece__rev-0123456789ab.model',
      ]);
      expect(progress.last, 100);
    });

    test('the wrong size never becomes the active embedder', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeBefore = manager.activeEmbeddingModel?.name;
      await expectLater(
        FlutterEdgeAi.installFromCatalog(
          TestEmbedder(
            model: artifact('bad_256.tflite', size: 123),
            tokenizer: artifact('sentencepiece.model'),
          ),
        ).install(),
        throwsA(isA<CatalogInstallException>()),
      );
      expect(manager.activeEmbeddingModel?.name, activeBefore);
      expect(activeBefore, isNot('bad_256'));
    });

    test('it cannot be installed without becoming active', () {
      expect(
        () => FlutterEdgeAi.installFromCatalog(
          embedder(),
        ).install(activate: false),
        throwsArgumentError,
      );
    });
  });
}

final class _Downloads implements DownloadService {
  final urls = <String>[];

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    urls.add(url);
    await File(targetPath).writeAsBytes(_bytes);
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
    urls.add(url);
    await File(targetPath).writeAsBytes(_bytes);
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

class _TtsWithoutCatalog implements TtsBackendProvider {
  @override
  String get name => 'tts without a catalog';

  @override
  int get priority => 0;

  @override
  bool canHandle(TtsModelSpec spec) => false;

  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

class _TtsWithCatalog extends _TtsWithoutCatalog implements ModelCatalogSource {
  _TtsWithCatalog(this.modelCatalog);

  @override
  final ModelCatalog modelCatalog;
}
