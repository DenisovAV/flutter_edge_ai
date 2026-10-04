// Directory (ORT-GenAI) install: `installModel(fileType: onnx).fromHuggingFace(repo)`
// with a resolver that returns a multi-file `ResolvedHfModel` installs every
// file into a per-model subdirectory with its BARE leaf name, builds a directory
// InferenceModelSpec whose primary is genai_config.json, restores that spec on a
// cold relaunch, and cleans up the subdir on delete.
//
// Run: flutter test test/core/api/onnx_directory_install_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show DirectoryBundleFile, InferenceModelSpec;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/utils/file_name_utils.dart'
    show FileNameUtils;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;

const _modelId = 'org__repo__cpu';
const _dirModel = ResolvedHfModel(
  file: 'genai_config.json', // primary (bare leaf)
  url: 'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
  fileType: ModelFileType.onnx,
  modelType: ModelType.qwen3, // manifest declares the family
  directoryName: _modelId,
  files: [
    ResolvedHfFile(
      name: 'genai_config.json',
      url: 'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
    ),
    ResolvedHfFile(
      name: 'model.onnx',
      url: 'https://huggingface.co/org/repo/resolve/main/cpu/model.onnx',
    ),
    ResolvedHfFile(
      name: 'tokenizer.json',
      url: 'https://huggingface.co/org/repo/resolve/main/cpu/tokenizer.json',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late _FixtureDownloadService download;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_onnx_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_onnx_support_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    download = _FixtureDownloadService(
      Uint8List.fromList(List.filled(2048, 7)),
    );
  });

  tearDown(() async {
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    for (final d in [fakeDocuments, fakeAppSupport]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<String> storageDir() =>
      ServiceRegistry.instance.fileSystemService.getModelStorageDirectory();

  test('installs every file into <modelId>/ with bare names; spec is a '
      'directory model whose primary is genai_config.json', () async {
    await ServiceRegistry.initialize(downloadService: download);
    HuggingFaceResolverRegistry.instance.registerAll([
      _ScriptedResolver(ModelFileType.onnx, _dirModel),
    ]);

    final install = await FlutterEdgeAi.installModel(
      modelType: ModelType.general, // manifest overrides → qwen3
      fileType: ModelFileType.onnx,
    ).fromHuggingFace('org/repo').install();

    // Each file landed under <modelId>/ with its BARE leaf name.
    final dir = await storageDir();
    for (final name in ['genai_config.json', 'model.onnx', 'tokenizer.json']) {
      expect(
        File(p.join(dir, _modelId, name)).existsSync(),
        isTrue,
        reason: '$name must be inside the $_modelId subdir with its bare name',
      );
    }
    // Downloaded from the resolver's pinned URLs, bare-named in the subdir.
    expect(
      download.requestedUrls,
      containsAll(_dirModel.files!.map((f) => f.url)),
    );

    // The active spec is a directory model (3 files), family from the manifest.
    final spec = install.spec;
    expect(spec.directoryFiles, isNotNull);
    expect(spec.directoryFiles!.length, 3);
    expect(spec.modelType, ModelType.qwen3);
    expect(spec.name, _modelId);

    // getModelFilePaths.values.first (the engine's modelPath) resolves to
    // genai_config.json INSIDE the subdir → File(modelPath).parent == the dir.
    final manager =
        FlutterEdgeAiPlugin.instance.modelManager as MobileModelManager;
    final paths = await manager.getModelFilePaths(spec);
    expect(paths, isNotNull);
    final modelPath = paths!.values.first;
    expect(p.basename(modelPath), 'genai_config.json');
    expect(p.basename(File(modelPath).parent.path), _modelId);
  });

  test('the directory model restores on a cold relaunch (repository is the '
      'source of truth, not a FileSource)', () async {
    await ServiceRegistry.initialize(downloadService: download);
    HuggingFaceResolverRegistry.instance.registerAll([
      _ScriptedResolver(ModelFileType.onnx, _dirModel),
    ]);
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.onnx,
    ).fromHuggingFace('org/repo').install();

    // setActiveModel persists the active identity fire-and-forget
    // (`unawaited`); let that SharedPreferences write flush before a cold
    // relaunch reads it. (In production the app restarts long after; only a
    // tight test races the two.)
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Cold relaunch: a fresh manager restores from persisted identity + repo.
    final fresh = MobileModelManager();
    await fresh.initialize();

    expect(fresh.activeInferenceModel, isNotNull);
    final restored = fresh.activeInferenceModel! as InferenceModelSpec;
    expect(restored.directoryFiles, isNotNull);
    expect(restored.directoryFiles!.length, 3);
    expect(restored.name, _modelId);
    expect(restored.modelType, ModelType.qwen3);
    // The restored spec still resolves inside the subdir (no bare-leaf drift).
    final paths = await fresh.getModelFilePaths(restored);
    expect(paths, isNotNull);
    expect(p.basename(paths!.values.first), 'genai_config.json');
    expect(await fresh.isModelInstalled(restored), isTrue);
  });

  test('deleteModel removes the per-model subdirectory', () async {
    await ServiceRegistry.initialize(downloadService: download);
    HuggingFaceResolverRegistry.instance.registerAll([
      _ScriptedResolver(ModelFileType.onnx, _dirModel),
    ]);
    final install = await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.onnx,
    ).fromHuggingFace('org/repo').install();

    final dir = await storageDir();
    expect(Directory(p.join(dir, _modelId)).existsSync(), isTrue);

    final manager =
        FlutterEdgeAiPlugin.instance.modelManager as MobileModelManager;
    await manager.deleteModel(install.spec);

    expect(
      Directory(p.join(dir, _modelId)).existsSync(),
      isFalse,
      reason: 'the emptied <modelId>/ subdir must be removed',
    );
  });

  group('review fixes (codex)', () {
    test('a directory model without directoryName is rejected (no repo-only '
        'fallback that would collide EP variants)', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          ModelFileType.onnx,
          const ResolvedHfModel(
            file: 'genai_config.json',
            url:
                'https://huggingface.co/org/repo/resolve/main/genai_config.json',
            fileType: ModelFileType.onnx,
            // directoryName omitted → must throw, not fall back to repo-only.
            files: [
              ResolvedHfFile(
                name: 'genai_config.json',
                url:
                    'https://huggingface.co/org/repo/resolve/main/genai_config.json',
              ),
            ],
          ),
        ),
      ]);

      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('org/repo').install(),
        throwsArgumentError,
      );
    });

    test('a traversing directoryName ("..") is rejected before any download '
        '(would let deleteModel escape the storage dir)', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          ModelFileType.onnx,
          const ResolvedHfModel(
            file: 'genai_config.json',
            url:
                'https://huggingface.co/org/repo/resolve/main/genai_config.json',
            fileType: ModelFileType.onnx,
            directoryName: '..', // traversal — must be refused
            files: [
              ResolvedHfFile(
                name: 'genai_config.json',
                url:
                    'https://huggingface.co/org/repo/resolve/main/genai_config.json',
              ),
              ResolvedHfFile(
                name: 'model.onnx',
                url: 'https://huggingface.co/org/repo/resolve/main/model.onnx',
              ),
            ],
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('org/repo').install(),
        throwsArgumentError,
      );
      expect(download.requestedUrls, isEmpty);
    });

    test('a directory bundle with no .onnx weight is refused', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          ModelFileType.onnx,
          const ResolvedHfModel(
            file: 'genai_config.json',
            url:
                'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
            fileType: ModelFileType.onnx,
            directoryName: 'org__repo__cpu',
            files: [
              ResolvedHfFile(
                name: 'genai_config.json',
                url:
                    'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
              ),
              ResolvedHfFile(
                name: 'tokenizer.json',
                url:
                    'https://huggingface.co/org/repo/resolve/main/cpu/tokenizer.json',
              ),
            ],
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('org/repo').install(),
        throwsA(isA<StateError>()),
      );
    });

    test('sanitizeHfDirName rejects a dot-only / empty result', () {
      expect(() => FileNameUtils.sanitizeHfDirName('..'), throwsArgumentError);
      expect(() => FileNameUtils.sanitizeHfDirName('.'), throwsArgumentError);
      expect(() => FileNameUtils.sanitizeHfDirName('@@'), throwsArgumentError);
      // A normal repo/variant sanitizes to a safe single segment.
      expect(
        FileNameUtils.sanitizeHfDirName(
          'org/repo',
          variant: 'cpu_and_mobile/x',
        ),
        'org__repo__cpu_and_mobile__x',
      );
    });

    test(
      'LoRA + a directory model is rejected (not silently dropped)',
      () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(ModelFileType.onnx, _dirModel),
        ]);

        await expectLater(
          FlutterEdgeAi.installModel(
                modelType: ModelType.general,
                fileType: ModelFileType.onnx,
              )
              .fromHuggingFace('org/repo')
              .withLoraFromNetwork('https://example.com/adapter.bin')
              .install(),
          throwsArgumentError,
        );
      },
    );

    test('a file name with a path-traversal segment is rejected before any '
        'download', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          ModelFileType.onnx,
          const ResolvedHfModel(
            file: 'genai_config.json',
            url:
                'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
            fileType: ModelFileType.onnx,
            directoryName: 'org__repo__cpu',
            files: [
              ResolvedHfFile(
                name: 'genai_config.json',
                url:
                    'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
              ),
              ResolvedHfFile(
                name: '../victim.onnx', // escapes the model directory
                url:
                    'https://huggingface.co/org/repo/resolve/main/cpu/model.onnx',
              ),
            ],
          ),
        ),
      ]);

      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('org/repo').install(),
        throwsArgumentError,
      );
      expect(download.requestedUrls, isEmpty);
    });

    test('two directory specs with different members are not equal', () {
      InferenceModelSpec dir(List<String> leaves) => InferenceModelSpec(
        name: 'm',
        modelSource: ModelSource.network(
          'https://huggingface.co/o/r/resolve/main/m/genai_config.json',
        ),
        modelType: ModelType.general,
        fileType: ModelFileType.onnx,
        directoryFiles: [
          for (final leaf in leaves)
            DirectoryBundleFile.member(
              modelId: 'm',
              bareName: leaf,
              primaryName: 'genai_config.json',
              source: ModelSource.network(
                'https://huggingface.co/o/r/resolve/main/m/$leaf',
              ),
            ),
        ],
      );
      final a = dir(['genai_config.json', 'model.onnx']);
      final b = dir(['genai_config.json', 'model.onnx', 'tokenizer.json']);
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
      expect(a == dir(['genai_config.json', 'model.onnx']), isTrue);
    });

    test('an empty directory bundle is rejected by InferenceModelSpec — a '
        'release guard, not a debug-only assert (else files.first throws far '
        'downstream)', () {
      expect(
        () => InferenceModelSpec(
          name: 'm',
          modelSource: ModelSource.network(
            'https://huggingface.co/o/r/resolve/main/m/genai_config.json',
          ),
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
          directoryFiles: const [],
        ),
        throwsArgumentError,
      );
    });
  });
}

class _ScriptedResolver implements HuggingFaceResolver {
  _ScriptedResolver(this.forFileType, this.result);
  final ModelFileType forFileType;
  final ResolvedHfModel result;
  @override
  String get name => 'scripted-dir';
  @override
  int get priority => 0;
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) =>
      fileType == forFileType;
  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async => result;
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

/// Writes [bytes] to the requested target path, creating parent dirs (a
/// directory install targets `<storage>/<modelId>/<file>`). Records URLs.
class _FixtureDownloadService implements DownloadService {
  _FixtureDownloadService(this.bytes);
  final Uint8List bytes;
  final List<String> requestedUrls = [];

  Future<void> _write(String targetPath) async {
    final f = File(targetPath);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requestedUrls.add(url);
    await _write(targetPath);
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
    requestedUrls.add(url);
    await _write(targetPath);
    yield 100;
  }
}
