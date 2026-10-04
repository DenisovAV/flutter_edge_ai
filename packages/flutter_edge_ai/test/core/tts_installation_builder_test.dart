import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    ServiceRegistry.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('TtsModelType is exported from the public barrel', () {
    // Compile-level check that users can reference the type + install API.
    expect(TtsModelType.matcha.name, 'matcha');
  });

  test('install() requires a base source', () {
    expect(FlutterEdgeAi.installTts().install(), throwsA(isA<StateError>()));
  });

  test('install() requires ofType', () {
    expect(
      FlutterEdgeAi.installTts().fromNetwork('https://x/').install(),
      throwsA(isA<StateError>()),
    );
  });

  test('getActiveTts throws with no active model', () {
    expect(FlutterEdgeAi.getActiveTts(), throwsA(isA<StateError>()));
  });

  test(
    'qwen3: install() wires the 4 embedding tables + demo voice through '
    'fetchLocationFor (the real joinUrl path, not a re-derivation) — their '
    'NetworkSource URL carries the HF tables/voices subdirectory, but the '
    'installed identity (TtsBundleFile.prefsKey, via TtsModelSpec.files) '
    'stays the PLAIN basename. Exercises TtsInstallationBuilder.install() '
    'end to end, so reverting the joinUrl/fetchLocationFor wiring in '
    'tts_installation_builder.dart fails this test (unlike the '
    'tts_model_spec_test.dart round-trip test, which builds sourceFor '
    'itself and would keep passing even if the builder wiring regressed).',
    () async {
      final fixtureDownload = _RecordingDownloadService(
        Uint8List.fromList(List.filled(2048, 7)),
      );
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      final installation = await FlutterEdgeAi.installTts()
          .fromNetwork(
            'https://huggingface.co/litert-community/'
            'Qwen3-TTS-12Hz-0.6B-Base/resolve/main/',
          )
          .ofType(TtsModelType.qwen3)
          .install();

      final spec = installation.spec;
      expect(spec.sources.length, 9);
      expect(spec.files.length, 9);

      // Map prefsKey (the installed identity / artifactPaths key) -> the
      // NetworkSource actually built by install()'s sourceFor/joinUrl.
      final sourceByKey = <String, ModelSource>{
        for (var i = 0; i < spec.files.length; i++)
          spec.files[i].prefsKey: spec.sources[i],
      };

      String urlOf(String prefsKey) {
        final source = sourceByKey[prefsKey];
        expect(source, isNotNull, reason: 'no bundle file for "$prefsKey"');
        expect(source, isA<NetworkSource>());
        return (source as NetworkSource).url;
      }

      // Fetch URL carries the HF subdirectory...
      expect(
        urlOf('text_embedding_fp16.npy'),
        endsWith('/tables/text_embedding_fp16.npy'),
      );
      expect(
        urlOf('text_projection_fp32.npz'),
        endsWith('/tables/text_projection_fp32.npz'),
      );
      expect(
        urlOf('codec_embedding_fp32.npy'),
        endsWith('/tables/codec_embedding_fp32.npy'),
      );
      expect(
        urlOf('mtp_embeddings_fp16.npy'),
        endsWith('/tables/mtp_embeddings_fp16.npy'),
      );
      expect(urlOf('demo_speaker.npy'), endsWith('/voices/demo_speaker.npy'));

      // ...but the installed identity (the map's KEYS, i.e. every
      // TtsBundleFile.prefsKey) is the plain basename — no leaked
      // tables/voices subdirectory anywhere in artifactPaths.
      for (final key in sourceByKey.keys) {
        expect(
          key.contains('/'),
          isFalse,
          reason: '"$key" must be a plain basename (no subdirectory)',
        );
      }
      expect(sourceByKey.containsKey('text_embedding_fp16.npy'), isTrue);
      expect(sourceByKey.containsKey('demo_speaker.npy'), isTrue);

      // Top-level members (no HF subdirectory) fetch from the plain name.
      expect(urlOf('talker_int4.tflite'), endsWith('/talker_int4.tflite'));
      expect(urlOf('tokenizer.json'), endsWith('/tokenizer.json'));

      // Every requested download went through the real URL built above —
      // proves the recorded urls above are what install() actually fetched
      // from, not just what the returned spec claims.
      expect(
        fixtureDownload.requestedUrls.any(
          (u) => u.endsWith('/tables/text_embedding_fp16.npy'),
        ),
        isTrue,
      );
      expect(
        fixtureDownload.requestedUrls.any(
          (u) => u.endsWith('/voices/demo_speaker.npy'),
        ),
        isTrue,
      );
    },
  );

  test(
    'matcha spot-check: install() keeps identity URLs for its top-level-only '
    'manifest (no subdirectory, fetchLocationFor is a relative no-op for '
    'non-qwen3 types)',
    () async {
      final fixtureDownload = _RecordingDownloadService(
        Uint8List.fromList(List.filled(2048, 3)),
      );
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      final installation = await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      final spec = installation.spec;
      final sourceByKey = <String, ModelSource>{
        for (var i = 0; i < spec.files.length; i++)
          spec.files[i].prefsKey: spec.sources[i],
      };
      final configUrl = (sourceByKey['config.json']! as NetworkSource).url;
      expect(configUrl, 'https://example.com/matcha/config.json');
    },
  );

  test(
    'matcha install: bundle is tagged tts (getInstalledModels) AND protected '
    'from cleanup — not reported orphaned (#391 + regression guard)',
    () async {
      final fixtureDownload = _RecordingDownloadService(
        Uint8List.fromList(List.filled(2048, 5)),
      );
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      final manager = FlutterEdgeAiPlugin.instance.modelManager;

      // #391: the installed bundle is listed under tts, not inference.
      expect(
        await manager.getInstalledModels(ModelManagementType.tts),
        isNotEmpty,
        reason: 'getInstalledModels(tts) must return the installed TTS bundle',
      );
      expect(
        await manager.getInstalledModels(ModelManagementType.inference),
        isEmpty,
        reason: 'a TTS install must not be tagged inference',
      );

      // Regression guard: correctly tagging tts must NOT drop the bundle out of
      // the storage keep-set. The files land in the managed dir (via the
      // download fake), so getOrphanedFiles() would report — and
      // cleanupStorage() would delete — them if _getProtectedFiles omitted tts.
      expect(
        await FlutterEdgeAi.getOrphanedFiles(),
        isEmpty,
        reason: 'installed TTS files must be protected from cleanup',
      );
    },
    // On regression the files are reported orphaned and the scan hangs in
    // background_downloader's platform channel (absent in the test host) — so a
    // hang here IS the failure. Cap it so a revert fails in ~20s with a reason
    // rather than the 2-minute default timeout.
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'an installed-but-INACTIVE tts bundle is still protected from cleanup — '
    'isolates the type-agnostic listInstalled keep-set (#391, limb 2)',
    () async {
      final fixtureDownload = _RecordingDownloadService(
        Uint8List.fromList(List.filled(2048, 5)),
      );
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      // Drop it from the ACTIVE slot so the active-spec limb of
      // _getProtectedFiles can no longer contribute — protection must now come
      // ONLY from the type-agnostic listInstalled() keep-set (the actual #391
      // anti-data-loss fix). Real-world case: a second TTS voice, or a TTS
      // installed while a different modality is active.
      await FlutterEdgeAiPlugin.instance.modelManager.clearActiveTtsIdentity();

      expect(
        await FlutterEdgeAi.getOrphanedFiles(),
        isEmpty,
        reason:
            'installed-but-inactive TTS files must still be protected; reverting '
            '_getAllProtectedFiles to a type-filtered set re-introduces #391',
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'getOrphanedFiles ABORTS (rethrows) when repository enumeration fails — a '
    'partial keep-set must never feed the destructive cleanup',
    () async {
      // If listInstalled() throws, _getProtectedFiles must NOT swallow it and
      // return a partial (active-only / empty) keep-set — cleanupStorage() would
      // then delete installed models it should protect. The failure must abort.
      await ServiceRegistry.initialize(modelRepository: _ThrowingRepository());

      await expectLater(
        FlutterEdgeAi.getOrphanedFiles(),
        throwsA(isA<StateError>()),
      );
    },
  );
}

/// A ModelRepository whose enumeration throws — models a transient repo failure
/// (e.g. MissingPluginException early in app lifecycle) during a storage scan.
class _ThrowingRepository implements ModelRepository {
  @override
  Future<List<ModelInfo>> listInstalled() async =>
      throw StateError('repo enumeration failed');
  @override
  Future<void> saveModel(ModelInfo info) async {}
  @override
  Future<ModelInfo?> loadModel(String id) async => null;
  @override
  Future<void> deleteModel(String id) async {}
  @override
  Future<bool> isInstalled(String id) async => false;
}

/// PathProviderPlatform stub mirroring
/// test/core/api/install_identity_namespacing_test.dart's fixture.
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

/// A real (non-mock) DownloadService fake that writes [bytes] to whatever
/// targetPath it's asked to download to, instead of making a real HTTP
/// request — and records every requested URL so a test can assert exactly
/// what install() fetched from, not just what the returned spec claims.
class _RecordingDownloadService implements DownloadService {
  final Uint8List bytes;
  final List<String> requestedUrls = [];
  _RecordingDownloadService(this.bytes);

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requestedUrls.add(url);
    await File(targetPath).writeAsBytes(bytes);
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
    await File(targetPath).writeAsBytes(bytes);
    yield 100;
  }
}
