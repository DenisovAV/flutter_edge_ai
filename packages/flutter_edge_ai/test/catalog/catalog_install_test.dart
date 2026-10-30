// FlutterEdgeAi.catalog and the fromCatalog installs against core's real install
// path, with a download service that writes fixed bytes instead of fetching.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart'
    show
        FileExpectation,
        checkInstalledFiles,
        refuseTooLargeForWebCache,
        webCacheLimitBytes;
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
    await clearActiveModels();
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

    test('is built once per initialize, again after the next', () async {
      final model = TestModel('tiny-llm', [TestLlm('generic')]);
      await initialize(
        tts: [
          _TtsWithCatalog(TestCatalog('c', [model])),
        ],
      );
      final first = FlutterEdgeAi.catalog;
      expect(FlutterEdgeAi.catalog, same(first));
      await FlutterEdgeAi.dispose();
      ServiceRegistry.reset();
      await initialize(
        tts: [
          _TtsWithCatalog(TestCatalog('c', [model])),
        ],
      );
      expect(FlutterEdgeAi.catalog, isNot(same(first)));
    });
  });

  group('installModelFromCatalog', () {
    test(
      'progress holds at 99 until the model is checked and active',
      () async {
        await initialize();
        final progress = <int>[];
        await FlutterEdgeAi.installModelFromCatalog(
          TestLlm('progress'),
        ).withProgress(progress.add).install();
        expect(progress, [50, 99, 100]);
      },
    );

    test('installs with the variant\'s model and file type', () async {
      await initialize();
      final variant = TestLlm(
        'generic',
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      );
      final installation = await FlutterEdgeAi.installModelFromCatalog(
        variant,
      ).install();
      final spec = installation.spec;
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
      final installation = await FlutterEdgeAi.installModelFromCatalog(
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
        FlutterEdgeAi.installModelFromCatalog(variant).install(),
        throwsA(
          isA<ModelValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('${_bytes.length} bytes'), contains('123 expected')),
          ),
        ),
      );
    });

    test('the wrong size never becomes the active model', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      await FlutterEdgeAi.installModelFromCatalog(TestLlm('good')).install();
      await expectLater(
        FlutterEdgeAi.installModelFromCatalog(
          TestLlm('bad', file: artifact('bad.litertlm', size: 123)),
        ).install(),
        throwsA(isA<ModelValidationException>()),
      );
      expect(manager.activeInferenceModel?.name, 'good');
    });

    test('a variant that runs on no backend here is refused before any '
        'download', () async {
      await initialize();
      await expectLater(
        FlutterEdgeAi.installModelFromCatalog(
          TestLlm('npu-elsewhere', backendsHere: const {}),
        ).install(),
        throwsUnsupportedError,
      );
      expect(downloads.urls, isEmpty);
    });

    test(
      'a cancel after the last download stops it before activation',
      () async {
        await initialize();
        final manager = FlutterEdgeAiPlugin.instance.modelManager;
        await FlutterEdgeAi.installModelFromCatalog(
          TestLlm('before'),
        ).install();
        final cancel = CancelToken();
        downloads.onDownloaded = cancel.cancel;
        await expectLater(
          FlutterEdgeAi.installModelFromCatalog(
            TestLlm('cancelled'),
          ).withCancelToken(cancel).install(),
          throwsA(isA<DownloadCancelledException>()),
        );
        expect(manager.activeInferenceModel?.name, 'before');
      },
    );

    test('an install over the active model\'s file is refused before it '
        'downloads', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      await FlutterEdgeAi.installModelFromCatalog(TestLlm('shared')).install();
      final downloaded = downloads.urls.length;
      // Another revision of the same file name: core would write over the
      // active model's file, and check it only afterwards.
      final other = ModelArtifact(
        repo: 'litert-community/tiny',
        revision: 'f' * 40,
        path: 'shared.litertlm',
        sha256: sha64,
        sizeBytes: 123,
        installFilename: 'shared.litertlm',
      );
      await expectLater(
        FlutterEdgeAi.installModelFromCatalog(
          TestLlm('shared', file: other),
        ).install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('the active inference model shared reads'),
          ),
        ),
      );
      expect(downloads.urls, hasLength(downloaded));
      expect(manager.activeInferenceModel?.name, 'shared');
      final path = await FlutterEdgeAi.getModelPath('shared.litertlm');
      expect(await File(path).length(), _bytes.length);
    });

    test('it installs under the catalog\'s name, not the URL\'s', () async {
      await initialize();
      final variant = TestLlm(
        'generic',
        file: artifact('model.litertlm', installFilename: 'tiny-llm.litertlm'),
      );
      final installation = await FlutterEdgeAi.installModelFromCatalog(
        variant,
      ).install();
      expect(installation.spec.files.single.filename, 'tiny-llm.litertlm');
      expect(await FlutterEdgeAi.isModelInstalled('tiny-llm.litertlm'), isTrue);
      expect(await FlutterEdgeAi.isModelInstalled('model.litertlm'), isFalse);
      expect(
        await FlutterEdgeAi.getModelPath('tiny-llm.litertlm'),
        endsWith('tiny-llm.litertlm'),
      );
      await FlutterEdgeAi.uninstallModel('tiny-llm.litertlm');
      expect(
        await FlutterEdgeAi.isModelInstalled('tiny-llm.litertlm'),
        isFalse,
      );
    });

    test('a variant with no file is refused, unless it is built in', () async {
      expect(
        () => FlutterEdgeAi.installModelFromCatalog(
          TestLlm('nofile', noFile: true),
        ).install(),
        throwsUnsupportedError,
      );
      await initialize();
      final installation = await FlutterEdgeAi.installModelFromCatalog(
        TestLlm('os', noFile: true, fileType: ModelFileType.builtIn),
      ).install();
      expect(installation.spec.fileType, ModelFileType.builtIn);
      expect(installation.spec.name, 'tiny-llm');
      expect(downloads.urls, isEmpty);
      expect(
        FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel?.name,
        'tiny-llm',
      );
    });
  });

  group('installEmbedder().fromCatalog', () {
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
      final installation = await FlutterEdgeAi.installEmbedder()
          .fromCatalog(embedder())
          .withProgress(progress.add)
          .install();
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
        FlutterEdgeAi.installEmbedder()
            .fromCatalog(
              TestEmbedder(
                model: artifact('bad_256.tflite', size: 123),
                tokenizer: artifact('sentencepiece.model'),
              ),
            )
            .install(),
        throwsA(isA<ModelValidationException>()),
      );
      expect(manager.activeEmbeddingModel?.name, activeBefore);
      expect(activeBefore, isNot('bad_256'));
    });
  });

  group('installStt().fromCatalog', () {
    test('an install name that is not the URL\'s file name is refused before '
        'any download', () async {
      await initialize();
      await expectLater(
        FlutterEdgeAi.installStt()
            .fromCatalog(TestStt(modelInstallFilename: 'other.tflite'))
            .install(),
        throwsArgumentError,
      );
      expect(downloads.urls, isEmpty);
    });

    test('the wrong size never becomes the active STT model', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeBefore = manager.activeSttModel?.name;
      await expectLater(
        FlutterEdgeAi.installStt()
            .fromCatalog(TestStt(modelSize: 123))
            .install(),
        throwsA(isA<ModelValidationException>()),
      );
      expect(manager.activeSttModel?.name, activeBefore);
    });
  });

  test(
    'an install stopped before its check is checked by the next one',
    () async {
      await initialize();
      final cancel = CancelToken();
      downloads.onDownloaded = cancel.cancel;
      InferenceInstallationBuilder wrongSize() => FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromNetwork('https://example.com/x/m.litertlm', expectedSize: 123);
      await expectLater(
        wrongSize().withCancelToken(cancel).install(),
        throwsA(isA<DownloadCancelledException>()),
      );
      downloads.onDownloaded = null;
      // The stopped install's file is still there: the next one checks it
      // without downloading it again.
      final downloaded = downloads.urls.length;
      await expectLater(
        wrongSize().install(),
        throwsA(isA<ModelValidationException>()),
      );
      expect(downloads.urls, hasLength(downloaded));
      expect(
        FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel,
        isNull,
      );
    },
  );

  group('checkInstalledFiles', () {
    late InferenceModelSpec spec;
    late List<String> forgotten;

    Future<void> check(
      Map<String, FileExpectation> expected, {
      Map<String, String>? paths,
      bool usePaths = true,
      Map<String, ModelSpec> keep = const {},
    }) async {
      final fs = ServiceRegistry.instance.fileSystemService;
      await checkInstalledFiles(
        spec,
        expected,
        paths: usePaths
            ? paths ??
                  await FlutterEdgeAiPlugin.instance.modelManager
                      .getModelFilePaths(spec)
            : null,
        fileSystem: fs,
        keep: keep,
        forget: (file, _) async => forgotten.add(file.filename),
      );
    }

    setUp(() async {
      forgotten = [];
    });

    Future<void> install() async {
      await initialize();
      spec = (await FlutterEdgeAi.installModelFromCatalog(
        TestLlm('pathless'),
      ).install(activate: false)).spec;
    }

    test('a file core has no path for is a validation error, and is '
        'forgotten', () async {
      await install();
      final expected = {'pathless.litertlm': const FileExpectation(size: 1)};
      await expectLater(
        check(expected, paths: const {}),
        throwsA(
          isA<ModelValidationException>().having(
            (e) => e.message,
            'message',
            contains('no file'),
          ),
        ),
      );
      await expectLater(
        check(expected, usePaths: false),
        throwsA(isA<ModelValidationException>()),
      );
      expect(forgotten, ['pathless.litertlm', 'pathless.litertlm']);
    });

    test('a missing file an active model names keeps its record', () async {
      await install();
      await expectLater(
        check(
          {'pathless.litertlm': const FileExpectation(size: 1)},
          paths: const {},
          keep: {'pathless.litertlm': spec},
        ),
        throwsA(
          isA<ModelValidationException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('so it was kept'),
              contains("(FlutterEdgeAi.uninstallModel('pathless.litertlm'))"),
            ),
          ),
        ),
      );
      expect(forgotten, isEmpty);
    });

    test('a delete that fails is the cause, not the error', () async {
      await install();
      final fs = ServiceRegistry.instance.fileSystemService;
      await expectLater(
        checkInstalledFiles(
          spec,
          {'pathless.litertlm': const FileExpectation(size: 1)},
          paths: await FlutterEdgeAiPlugin.instance.modelManager
              .getModelFilePaths(spec),
          fileSystem: fs,
          forget: (_, _) async =>
              throw const FileSystemException('in use', 'x'),
        ),
        throwsA(
          isA<ModelValidationException>()
              .having((e) => e.cause, 'cause', isA<FileSystemException>())
              .having(
                (e) => e.message,
                'message',
                contains('uninstall it before installing again'),
              ),
        ),
      );
    });

    test('an expectation for a file the spec does not have throws', () async {
      await install();
      await expectLater(
        check({'other.litertlm': const FileExpectation(size: 1)}),
        throwsStateError,
      );
    });
  });

  group('a builder re-pointed after fromCatalog', () {
    final notRefusedForTheVariant = isNot(
      predicate((e) => '$e'.contains('does not run here')),
    );
    final nowhere = <PreferredBackend>{};

    test(
      'inference: fromNetwork drops the variant, its name and size',
      () async {
        await initialize();
        final installation = await FlutterEdgeAi.installModelFromCatalog(
          TestLlm(
            'cat',
            backendsHere: nowhere,
            file: artifact(
              'm.litertlm',
              size: 5,
              installFilename: 'cat.litertlm',
            ),
          ),
        ).fromNetwork('https://example.com/other.litertlm').install();
        expect(installation.spec.files.single.filename, 'other.litertlm');
      },
    );

    test('inference: a deferred fromHuggingFace drops the variant', () async {
      await initialize();
      await expectLater(
        FlutterEdgeAi.installModelFromCatalog(
          TestLlm('cat', backendsHere: nowhere),
        ).fromHuggingFace('org/x').install(),
        throwsA(notRefusedForTheVariant),
      );
    });

    test('embedder: modelFromNetwork drops the variant', () async {
      await initialize();
      await FlutterEdgeAi.installEmbedder()
          .fromCatalog(
            TestEmbedder(
              model: artifact('e.litertlm', size: 5),
              backendsHere: nowhere,
            ),
          )
          .modelFromNetwork('https://example.com/e2.litertlm')
          .install();
    });

    test('STT: fromCatalog with a tokenizer it refuses leaves the builder '
        'as it was', () async {
      await initialize();
      final builder = FlutterEdgeAi.installStt()
          .modelFromNetwork('https://example.com/mine_stt.tflite')
          .tokenizerFromNetwork('https://example.com/mine.json')
          .ofType(SttModelType.moonshine);
      expect(
        () => builder.fromCatalog(TestStt(tokenizerSize: -1)),
        throwsArgumentError,
      );
      await builder.install();
      final active =
          FlutterEdgeAiPlugin.instance.modelManager.activeSttModel!
              as SttModelSpec;
      expect(
        active.modelSource,
        ModelSource.network('https://example.com/mine_stt.tflite'),
      );
      expect(active.sttModelType, SttModelType.moonshine);
    });

    test('STT: modelFromNetwork, or another type, drops the variant', () async {
      await initialize();
      await FlutterEdgeAi.installStt()
          .fromCatalog(TestStt(backendsHere: nowhere))
          .modelFromNetwork('https://example.com/tiny_stt.tflite')
          .install();
      await expectLater(
        FlutterEdgeAi.installStt()
            .fromCatalog(TestStt(backendsHere: nowhere))
            .ofType(SttModelType.whisper)
            .install(),
        throwsA(notRefusedForTheVariant),
      );
    });
  });

  group('the web\'s default storage', () {
    final huge = {'big.litertlm': const FileExpectation(size: 3000000000)};
    test('refuses a file over 2 GiB unless the app streams', () {
      expect(
        () => refuseTooLargeForWebCache(huge, web: true, streaming: false),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('WebStorageMode.streaming'),
          ),
        ),
      );
      refuseTooLargeForWebCache(huge, web: true, streaming: true);
      refuseTooLargeForWebCache(huge, web: false, streaming: false);
      refuseTooLargeForWebCache(
        {'small.litertlm': const FileExpectation(size: webCacheLimitBytes)},
        web: true,
        streaming: false,
      );
    });
  });

  group('checkCatalogVariant', () {
    for (final (what, file) in [
      ('a branch', artifact('a.litertlm', revision: 'main')),
      ('a short sha256', artifact('b.litertlm', sha: 'aa')),
      ('no size', artifact('c.litertlm', size: 0)),
      (
        'a name with a colon',
        artifact('d.litertlm', installFilename: 'd:x.litertlm'),
      ),
    ]) {
      test('refuses $what before a download', () async {
        await initialize();
        await expectLater(
          FlutterEdgeAi.installModelFromCatalog(
            TestLlm('x', file: file),
          ).install(),
          throwsArgumentError,
        );
        expect(downloads.urls, isEmpty);
      });
    }
  });

  group('installTts().fromCatalog', () {
    test('a bundle over the active voice is refused before it downloads, and '
        'the voice stays active', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      await FlutterEdgeAi.installTts().fromCatalog(TestTts()).install();
      final downloaded = downloads.urls.length;
      await expectLater(
        FlutterEdgeAi.installTts()
            .fromCatalog(TestTts(size: 123, revision: 'f' * 40))
            .install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('the active text-to-speech model matcha reads'),
          ),
        ),
      );
      expect(downloads.urls, hasLength(downloaded));
      final active = manager.activeTtsModel;
      expect(
        active is TtsModelSpec && active.ttsModelType.name == 'matcha',
        isTrue,
      );
    });

    test(
      'a variant listing other URLs than the install fetches is refused',
      () async {
        await initialize();
        await expectLater(
          FlutterEdgeAi.installTts()
              .fromCatalog(TestTts(baseUrl: 'https://example.com/elsewhere/'))
              .install(),
          throwsArgumentError,
        );
        expect(downloads.urls, isEmpty);
      },
    );

    test('the wrong size never becomes the active voice', () async {
      await initialize();
      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      await expectLater(
        FlutterEdgeAi.installTts()
            .fromCatalog(TestTts(size: 123, type: TtsModelType.inflect))
            .install(),
        throwsA(isA<ModelValidationException>()),
      );
      final active = manager.activeTtsModel;
      expect(
        active is TtsModelSpec && active.ttsModelType == TtsModelType.inflect,
        isFalse,
      );
    });

    test('a bundle file the catalog does not list is refused before any '
        'download', () async {
      await initialize();
      await expectLater(
        FlutterEdgeAi.installTts()
            .fromCatalog(TestTts(type: TtsModelType.inflect, dropLast: true))
            .install(),
        throwsArgumentError,
      );
      expect(downloads.urls, isEmpty);
    });

    test('progress is weighted by bytes, not by finished files', () async {
      await initialize();
      final variant = TestTts();
      final progress = <int>[];
      await FlutterEdgeAi.installTts()
          .fromCatalog(variant)
          .withProgress(progress.add)
          .install();
      final n = variant.files.length;
      // Each download reports 50 and then 100: halfway through the first of
      // n equal files is 100 / (2 n) percent of the bytes, where counting
      // finished files would first say 100 / n.
      expect(progress.first, (100 / (2 * n)).round());
      expect(progress, contains((100 * 3 / (2 * n)).floor()));
      expect(progress.last, 100);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(downloads.urls, hasLength(n));
    });

    test('an already installed bundle still ends at 100', () async {
      await initialize();
      await FlutterEdgeAi.installTts().fromCatalog(TestTts()).install();
      final progress = <int>[];
      await FlutterEdgeAi.installTts()
          .fromCatalog(TestTts())
          .withProgress(progress.add)
          .install();
      expect(progress.last, 100);
    });
  });
}

final class _Downloads implements DownloadService {
  final urls = <String>[];

  /// Runs after each file is written.
  void Function()? onDownloaded;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    urls.add(url);
    await File(targetPath).writeAsBytes(_bytes);
    onDownloaded?.call();
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
    yield 50;
    await File(targetPath).writeAsBytes(_bytes);
    onDownloaded?.call();
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
