import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/core/api/tts_asset_listing.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/handlers/asset_source_handler.dart';
import 'package:flutter_edge_ai/core/infrastructure/flutter_asset_loader.dart';
import 'package:flutter_edge_ai/core/infrastructure/platform_file_system_service.dart';
import 'package:flutter_edge_ai/core/infrastructure/shared_preferences_model_repository.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The wired TTS families; the other enum values throw from `manifest`.
const _wiredTypes = [
  TtsModelType.matcha,
  TtsModelType.qwen3,
  TtsModelType.inflect,
];

const _bases = <TtsBundleBase>[
  TtsNetworkBase('https://example.com/m/'),
  TtsAssetBase('assets/tts/m'),
  TtsFileBase('/models/m'),
  TtsBundledBase(),
];

/// Where [fn] sits inside a local copy of [type]'s Hugging Face repo.
String _relative(TtsModelType type, String fn) =>
    switch (type.fetchLocationFor(fn)) {
      TtsRelativeSuffix(:final suffix) => suffix,
      TtsAbsoluteUrl() => fn,
    };

/// Bytes big enough to pass the install validators (1 MB for a graph).
Uint8List _bytesFor(String fn) =>
    Uint8List(fn.endsWith('.tflite') ? 1024 * 1024 + 1 : 2048);

/// Writes [type]'s bundle under [root] in the repo layout, leaving out [skip].
Future<void> _writeBundle(
  Directory root,
  TtsModelType type, {
  Set<String> skip = const {},
}) async {
  for (final fn in type.manifest) {
    if (skip.contains(fn)) continue;
    final file = File('${root.path}/${_relative(type, fn)}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_bytesFor(fn));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory userDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeDocuments = await Directory.systemTemp.createTemp('tts_src_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('tts_src_support_');
    userDir = await Directory.systemTemp.createTemp('tts_src_user_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    ServiceRegistry.reset();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    listAppAssets = _realListAssets;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, userDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  group('TtsModelTypeManifest.sourceFor', () {
    test('network keeps the URLs install has always fetched', () {
      expect(
        TtsModelType.matcha.sourceFor(
          'config.json',
          const TtsNetworkBase('https://h/matcha'),
        ),
        ModelSource.network('https://h/matcha/config.json'),
      );
      expect(
        TtsModelType.qwen3.sourceFor(
          'text_embedding_fp16.npy',
          const TtsNetworkBase('https://h/qwen3/'),
        ),
        ModelSource.network('https://h/qwen3/tables/text_embedding_fp16.npy'),
      );
      // Inflect's reused Matcha G2P file comes from the Matcha repo, with the
      // same token as the rest of the bundle.
      final g2p = TtsModelType.inflect.sourceFor(
        'g2p_dict.txt.gz',
        const TtsNetworkBase('https://h/inflect/', token: 't'),
      );
      expect(g2p, isA<NetworkSource>());
      expect(
        (g2p as NetworkSource).url,
        startsWith('https://huggingface.co/litert-community/Matcha-TTS/'),
      );
      expect(g2p.authToken, 't');
    });

    test('asset and file mirror the repo; cross-repo members sit flat', () {
      expect(
        TtsModelType.qwen3.sourceFor(
          'demo_speaker.npy',
          const TtsAssetBase('assets/tts/qwen3/'),
        ),
        ModelSource.asset('assets/tts/qwen3/voices/demo_speaker.npy'),
      );
      expect(
        TtsModelType.inflect.sourceFor(
          'g2p_meta.json',
          const TtsAssetBase('assets/tts/inflect'),
        ),
        ModelSource.asset('assets/tts/inflect/g2p_meta.json'),
      );
      expect(
        TtsModelType.qwen3.sourceFor(
          'mtp_embeddings_fp16.npy',
          const TtsFileBase('/m/qwen3'),
        ),
        ModelSource.file('/m/qwen3/tables/mtp_embeddings_fp16.npy'),
      );
    });

    test('bundled resources are flat and carry the type prefix', () {
      expect(
        TtsModelType.matcha.sourceFor('config.json', const TtsBundledBase()),
        ModelSource.bundled('matcha__config.json'),
      );
      expect(
        TtsModelType.qwen3.sourceFor(
          'text_embedding_fp16.npy',
          const TtsBundledBase(),
        ),
        ModelSource.bundled('qwen3__text_embedding_fp16.npy'),
      );
    });

    test('every base keeps the plain name as prefsKey and namespaces the '
        'filename — the keys the speech runtime and restore look up', () {
      for (final type in _wiredTypes) {
        for (final base in _bases) {
          for (final fn in type.manifest) {
            final file = TtsBundleFile.fromSource(
              type.sourceFor(fn, base),
              modelId: type.name,
            );
            final where = '$type / ${base.runtimeType} / $fn';
            expect(file.prefsKey, fn, reason: where);
            expect(file.filename, '${type.name}__$fn', reason: where);
          }
        }
      }
    });
  });

  group('fromFile', () {
    test('uses the files in place, subdirectories included', () async {
      await ServiceRegistry.initialize();
      await _writeBundle(userDir, TtsModelType.qwen3);

      final installation = await FlutterEdgeAi.installTts()
          .fromFile(userDir.path)
          .ofType(TtsModelType.qwen3)
          .install();

      final paths = await FlutterEdgeAiPlugin.instance.modelManager
          .getModelFilePaths(installation.spec);
      expect(paths, isNotNull);
      expect(
        paths!['text_embedding_fp16.npy'],
        '${userDir.path}/tables/text_embedding_fp16.npy',
      );
      expect(
        paths['demo_speaker.npy'],
        '${userDir.path}/voices/demo_speaker.npy',
      );
      // Nothing was copied into the managed directory.
      final managed = Directory('${fakeAppSupport.path}/flutter_gemma');
      final copies = await managed.exists()
          ? await managed.list().map((e) => e.path).toList()
          : <String>[];
      expect(copies.where((p) => p.contains('qwen3__')), isEmpty);
    });

    test('names every missing file and installs none', () async {
      await ServiceRegistry.initialize();
      await _writeBundle(
        userDir,
        TtsModelType.qwen3,
        skip: {'tokenizer.json', 'codec_embedding_fp32.npy'},
      );

      await expectLater(
        FlutterEdgeAi.installTts()
            .fromFile(userDir.path)
            .ofType(TtsModelType.qwen3)
            .install(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('2 of 9'),
              contains('${userDir.path}/tokenizer.json'),
              contains('${userDir.path}/tables/codec_embedding_fp32.npy'),
            ),
          ),
        ),
      );
      expect(
        await ServiceRegistry.instance.modelRepository.listInstalled(),
        isEmpty,
      );
    });

    test(
      'survives a restart: restore finds the files where they are',
      () async {
        await ServiceRegistry.initialize();
        await _writeBundle(userDir, TtsModelType.matcha);
        await FlutterEdgeAi.installTts()
            .fromFile(userDir.path)
            .ofType(TtsModelType.matcha)
            .install();

        final restarted = MobileModelManager();
        await restarted.initialize();

        final restored = restarted.activeTtsModel;
        expect(restored, isA<TtsModelSpec>());
        final sources = (restored! as TtsModelSpec).sources;
        expect(sources, hasLength(8));
        expect(sources, contains(FileSource('${userDir.path}/config.json')));
      },
    );

    test('a later fromNetwork downloads every file and stops referencing the '
        "user's files without deleting them", () async {
      final download = _RecordingDownloadService();
      await ServiceRegistry.initialize(downloadService: download);
      await _writeBundle(userDir, TtsModelType.matcha);
      await FlutterEdgeAi.installTts()
          .fromFile(userDir.path)
          .ofType(TtsModelType.matcha)
          .install();

      final network = await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      expect(download.requestedUrls, hasLength(8));
      final protectedFiles = ServiceRegistry.instance.protectedFilesRegistry;
      for (final file in network.spec.files) {
        expect(await protectedFiles.getExternalPath(file.filename), isNull);
        expect(await protectedFiles.isProtected(file.filename), isFalse);
      }
      expect(File('${userDir.path}/config.json').existsSync(), isTrue);
      final paths = await FlutterEdgeAiPlugin.instance.modelManager
          .getModelFilePaths(network.spec);
      expect(paths!['config.json'], startsWith(fakeAppSupport.path));

      // Same base again: everything is already there.
      await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();
      expect(download.requestedUrls, hasLength(8));
    });
  });

  group('switching away from fromFile', () {
    test('a failed download keeps the user files registered', () async {
      await ServiceRegistry.initialize(
        downloadService: _FailingDownloadService(),
      );
      await _writeBundle(userDir, TtsModelType.matcha);
      final file = await FlutterEdgeAi.installTts()
          .fromFile(userDir.path)
          .ofType(TtsModelType.matcha)
          .install();

      await expectLater(
        FlutterEdgeAi.installTts()
            .fromNetwork('https://example.com/matcha/')
            .ofType(TtsModelType.matcha)
            .install(),
        throwsA(anything),
      );

      final protectedFiles = ServiceRegistry.instance.protectedFilesRegistry;
      final first = file.spec.files.first;
      expect(
        await protectedFiles.getExternalPath(first.filename),
        (first.source as FileSource).path,
      );
      expect(await protectedFiles.isProtected(first.filename), isTrue);
    });

    test(
      'a later fromFile deletes the downloaded copies, not the user files',
      () async {
        await ServiceRegistry.initialize(
          downloadService: _RecordingDownloadService(),
        );
        final network = await FlutterEdgeAi.installTts()
            .fromNetwork('https://example.com/matcha/')
            .ofType(TtsModelType.matcha)
            .install();
        final managed = [
          for (final f in network.spec.files)
            File('${fakeAppSupport.path}/flutter_gemma/${f.filename}'),
        ];
        expect(managed.every((f) => f.existsSync()), isTrue);

        await _writeBundle(userDir, TtsModelType.matcha);
        final local = await FlutterEdgeAi.installTts()
            .fromFile(userDir.path)
            .ofType(TtsModelType.matcha)
            .install();

        expect(managed.where((f) => f.existsSync()), isEmpty);
        final paths = await FlutterEdgeAiPlugin.instance.modelManager
            .getModelFilePaths(local.spec);
        expect(paths!['config.json'], '${userDir.path}/config.json');
        expect(File('${userDir.path}/config.json').existsSync(), isTrue);
      },
    );
  });

  group('fromAsset', () {
    test('installs from an asset directory laid out like the repo', () async {
      final keys = {
        for (final fn in TtsModelType.qwen3.manifest)
          'assets/tts/qwen3/${_relative(TtsModelType.qwen3, fn)}',
      };
      listAppAssets = () async => keys;
      _serveAssets(keys);
      await ServiceRegistry.initialize();

      final installation = await FlutterEdgeAi.installTts()
          .fromAsset('assets/tts/qwen3/')
          .ofType(TtsModelType.qwen3)
          .install();

      final paths = await FlutterEdgeAiPlugin.instance.modelManager
          .getModelFilePaths(installation.spec);
      expect(paths, isNotNull);
      expect(
        paths!['text_embedding_fp16.npy'],
        startsWith(fakeAppSupport.path),
      );
      expect(File(paths['text_embedding_fp16.npy']!).lengthSync(), 2048);
    });

    test('names every missing asset and installs none', () async {
      final keys = {
        for (final fn in TtsModelType.inflect.manifest)
          if (fn != 'g2p_meta.json') 'assets/tts/inflect/$fn',
      };
      listAppAssets = () async => keys;
      await ServiceRegistry.initialize();

      await expectLater(
        FlutterEdgeAi.installTts()
            .fromAsset('assets/tts/inflect')
            .ofType(TtsModelType.inflect)
            .install(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('1 of 6'),
              contains('assets/tts/inflect/g2p_meta.json'),
            ),
          ),
        ),
      );
      expect(
        await ServiceRegistry.instance.modelRepository.listInstalled(),
        isEmpty,
      );
    });
  });

  group('fromBundled', () {
    test('is refused off Android and iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      // Resources that would resolve, so only the platform check can refuse.
      await ServiceRegistry.initialize(
        fileSystemService: _BundleFileSystem(
          Directory('${userDir.path}/bundle'),
        ),
      );

      await expectLater(
        FlutterEdgeAi.installTts()
            .fromBundled()
            .ofType(TtsModelType.matcha)
            .install(),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('names every missing resource', () async {
      final fs = _BundleFileSystem(
        Directory('${userDir.path}/bundle'),
        missing: {'matcha__emb.bin', 'matcha__g2p_meta.json'},
      );
      await ServiceRegistry.initialize(fileSystemService: fs);

      await expectLater(
        FlutterEdgeAi.installTts()
            .fromBundled()
            .ofType(TtsModelType.matcha)
            .install(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('2 of 8'),
              contains('matcha__emb.bin'),
              contains('matcha__g2p_meta.json'),
            ),
          ),
        ),
      );
      // The six present resources were resolved but none was recorded, so a
      // restart cannot rebuild a half-replaced voice.
      expect(
        await ServiceRegistry.instance.modelRepository.listInstalled(),
        isEmpty,
      );
    });

    test('replacing a download deletes the copies it no longer uses', () async {
      await ServiceRegistry.initialize(
        downloadService: _RecordingDownloadService(),
        fileSystemService: _BundleFileSystem(
          Directory('${userDir.path}/bundle'),
        ),
      );
      final network = await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();
      final managed = [
        for (final f in network.spec.files)
          File('${fakeAppSupport.path}/flutter_gemma/${f.filename}'),
      ];
      expect(managed.every((f) => f.existsSync()), isTrue);

      await FlutterEdgeAi.installTts()
          .fromBundled()
          .ofType(TtsModelType.matcha)
          .install();

      expect(managed.where((f) => f.existsSync()), isEmpty);
    });

    test('survives a restart: restore resolves each resource again', () async {
      final fs = _BundleFileSystem(Directory('${userDir.path}/bundle'));
      await ServiceRegistry.initialize(fileSystemService: fs);
      await FlutterEdgeAi.installTts()
          .fromBundled()
          .ofType(TtsModelType.matcha)
          .install();

      final restarted = MobileModelManager();
      await restarted.initialize();

      final restored = restarted.activeTtsModel;
      expect(restored, isA<TtsModelSpec>());
      expect(
        (restored! as TtsModelSpec).sources,
        contains(FileSource('${userDir.path}/bundle/matcha__config.json')),
      );
    });
  });

  group('AssetSourceHandler on desktop', () {
    test('writes the copy where models are read, not into Documents', () async {
      // The test host is a desktop, as Platform sees it.
      _serveAssets({'assets/m/config.json'});
      final loader = _DocumentsCopyingAssetLoader(fakeDocuments);
      final fs = PlatformFileSystemService();
      final handler = AssetSourceHandler(
        assetLoader: loader,
        fileSystem: fs,
        repository: SharedPreferencesModelRepository(),
      );

      await handler.install(
        ModelSource.asset('assets/m/config.json'),
        targetFilename: 'm__config.json',
        modelType: repo.ModelType.tts,
      );

      await handler
          .installWithProgress(
            ModelSource.asset('assets/m/config.json'),
            targetFilename: 'm2__config.json',
            modelType: repo.ModelType.tts,
          )
          .drain<void>();

      expect(loader.copies, isEmpty);
      for (final name in ['m__config.json', 'm2__config.json']) {
        expect(File(await fs.getReadTargetPath(name)).lengthSync(), 2048);
      }
    });
  });
}

final _realListAssets = listAppAssets;

/// Serves [_bytesFor]-sized bytes for each of [keys] through the asset channel that
/// `rootBundle` reads in tests.
void _serveAssets(Set<String> keys) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        final key = Uri.decodeFull(
          String.fromCharCodes(message!.buffer.asUint8List()),
        );
        if (!keys.contains(key)) return null;
        return ByteData.sublistView(_bytesFor(key));
      });
}

/// Models large_file_handler 0.5 on desktop: the copy "succeeds" into
/// Documents, a directory desktop never reads models from.
class _DocumentsCopyingAssetLoader extends FlutterAssetLoader {
  final Directory documents;
  final List<String> copies = [];
  _DocumentsCopyingAssetLoader(this.documents);

  @override
  Future<void> copyAssetToFile(String assetPath, String targetPath) async {
    copies.add(assetPath);
    await File('${documents.path}/$targetPath').writeAsBytes(Uint8List(2048));
  }

  @override
  Stream<int> copyAssetToFileWithProgress(
    String assetPath,
    String targetPath,
  ) async* {
    await copyAssetToFile(assetPath, targetPath);
    yield 100;
  }
}

/// A file system whose bundled resources are files under [bundle], except the
/// [missing] ones, which fail the way the iOS channel does.
class _BundleFileSystem extends PlatformFileSystemService {
  final Directory bundle;
  final Set<String> missing;
  _BundleFileSystem(this.bundle, {this.missing = const {}});

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    if (missing.contains(resourceName)) {
      throw PlatformException(code: 'NOT_FOUND', message: resourceName);
    }
    final file = File('${bundle.path}/$resourceName');
    if (!file.existsSync()) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_bytesFor(resourceName));
    }
    return file.path;
  }
}

class _FixedPathProviderPlatform extends PathProviderPlatform {
  final String documentsPath;
  final String appSupportPath;

  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

/// A download that always fails, like a lost connection.
class _FailingDownloadService implements DownloadService {
  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async => throw const SocketException('offline');

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    throw const SocketException('offline');
  }
}

/// Writes bytes sized for each file instead of downloading, and records the
/// URLs it was asked for.
class _RecordingDownloadService implements DownloadService {
  final List<String> requestedUrls = [];

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requestedUrls.add(url);
    await File(targetPath).writeAsBytes(_bytesFor(url.split('/').last));
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
