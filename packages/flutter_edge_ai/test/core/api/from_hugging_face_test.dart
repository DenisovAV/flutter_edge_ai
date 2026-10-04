// One-call `installModel(...).fromHuggingFace(repo)` (no `file`): the builder
// resolves the repo's manifest at install() time via the registered resolver,
// installs the revision-pinned variant, and carries the manifest's overridable
// runtime defaults + notes on the InferenceInstallation result.
//
// Uses the same PathProvider-fixture + fake-DownloadService harness as
// test/core/api/install_identity_namespacing_test.dart, plus a scripted fake
// HuggingFaceResolver, so nothing hits the network.
//
// Run: flutter test test/core/api/from_hugging_face_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final _fakeModelBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory sourceDir;
  late _FixtureDownloadService download;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_hf_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_hf_support_');
    sourceDir = await Directory.systemTemp.createTemp('fg_hf_src_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    download = _FixtureDownloadService(_fakeModelBytes);
  });

  tearDown(() async {
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, sourceDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  group('fromHuggingFace argument validation (synchronous, no install)', () {
    test('a non-"main" revision without an explicit file throws', () {
      expect(
        () => FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.litertlm,
        ).fromHuggingFace('org/repo', revision: 'abc123'),
        throwsArgumentError,
      );
    });

    test('an empty repo throws', () {
      expect(
        () => FlutterEdgeAi.installModel(
          modelType: ModelType.general,
        ).fromHuggingFace('   '),
        throwsArgumentError,
      );
    });

    test('an explicit but empty file throws', () {
      expect(
        () => FlutterEdgeAi.installModel(
          modelType: ModelType.general,
        ).fromHuggingFace('org/repo', file: '  '),
        throwsArgumentError,
      );
    });
  });

  group('one-call manifest install (deferred resolution)', () {
    test('resolves the manifest, installs from the resolver URL '
        '(revision pinned), and returns the runtime defaults + notes', () async {
      await ServiceRegistry.initialize(downloadService: download);
      const pinnedUrl =
          'https://huggingface.co/org/repo/resolve/pinnedsha123/model.litertlm';
      final resolver = _ScriptedResolver(
        forFileType: ModelFileType.litertlm,
        result: const ResolvedHfModel(
          file: 'model.litertlm',
          url: pinnedUrl,
          fileType: ModelFileType.litertlm,
          modelType: ModelType.qwen3,
          runtime: ModelRuntimeDefaults(
            maxTokens: 4096,
            isThinking: true,
            minOutputTokens: 2048,
          ),
          notes: ['heads up: verified on cpu only'],
        ),
      );
      HuggingFaceResolverRegistry.instance.registerAll([resolver]);

      final install = await FlutterEdgeAi.installModel(
        modelType: ModelType.general, // fallback — manifest overrides
        fileType: ModelFileType.litertlm,
      ).fromHuggingFace('org/repo', token: 'hf_test').install();

      // Resolver selected for the builder's fileType, once, with the token.
      expect(resolver.resolveCalls, 1);
      expect(resolver.lastToken, 'hf_test');
      // Installed from the resolver's authoritative (revision-pinned) URL —
      // NOT a rebuilt main URL.
      expect(download.requestedUrls, contains(pinnedUrl));
      // Runtime defaults ride on the RESULT, not the spec.
      expect(install.runtime, isNotNull);
      expect(install.runtime!.maxTokens, 4096);
      expect(install.runtime!.isThinking, true);
      expect(install.runtime!.minOutputTokens, 2048);
      expect(install.notes, ['heads up: verified on cpu only']);
      // Manifest modelType wins over the passed fallback.
      expect(install.spec.modelType, ModelType.qwen3);
    });

    test(
      'a manifest silent on modelType falls back to the passed modelType',
      () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(
            forFileType: ModelFileType.litertlm,
            result: const ResolvedHfModel(
              file: 'model.litertlm',
              url:
                  'https://huggingface.co/org/repo/resolve/main/model.litertlm',
              fileType: ModelFileType.litertlm,
              // modelType omitted → resolver could not determine it
            ),
          ),
        ]);

        final install = await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        ).fromHuggingFace('org/repo').install();

        expect(install.spec.modelType, ModelType.gemmaIt);
        // No manifest runtime hints → all-null defaults, empty notes.
        expect(install.runtime, isNotNull);
        expect(install.runtime!.maxTokens, isNull);
        expect(install.notes, isEmpty);
      },
    );

    test('a SPECIFIC caller modelType wins over a differing manifest, and the '
        'conflict is surfaced in a release-visible note', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          forFileType: ModelFileType.litertlm,
          result: const ResolvedHfModel(
            file: 'model.litertlm',
            url: 'https://huggingface.co/org/repo/resolve/main/model.litertlm',
            fileType: ModelFileType.litertlm,
            modelType: ModelType.qwen3, // manifest disagrees with the caller
            notes: ['base note'],
          ),
        ),
      ]);

      // Caller deliberately passed a specific family, not ModelType.general.
      final install = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromHuggingFace('org/repo').install();

      // Explicit specific choice is KEPT, not overridden by the manifest.
      expect(install.spec.modelType, ModelType.gemmaIt);
      // The base note survives AND a conflict note naming both families is
      // appended (release-visible, not just edgeAiLog).
      expect(install.notes, contains('base note'));
      expect(
        install.notes.any((n) => n.contains('gemmaIt') && n.contains('qwen3')),
        isTrue,
        reason: 'a release-visible conflict note naming both families',
      );
    });

    test('install.notes is unmodifiable', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          forFileType: ModelFileType.litertlm,
          result: const ResolvedHfModel(
            file: 'model.litertlm',
            url: 'https://huggingface.co/org/repo/resolve/main/model.litertlm',
            fileType: ModelFileType.litertlm,
            notes: ['a note'],
          ),
        ),
      ]);

      final install = await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromHuggingFace('org/repo').install();

      expect(() => install.notes.add('x'), throwsUnsupportedError);
    });

    test('the resolver error surfaces from install BEFORE any download '
        '(.onnx → UnimplementedError)', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          forFileType: ModelFileType.onnx,
          throwError: UnimplementedError('not implemented yet ("org/repo")'),
        ),
      ]);

      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('org/repo').install(),
        throwsA(isA<UnimplementedError>()),
      );
      // Resolve-first ordering: nothing was downloaded.
      expect(download.requestedUrls, isEmpty);
    });

    test('an explicit source after fromHuggingFace cancels the deferred '
        'resolve (last source wins, resolver never called)', () async {
      await ServiceRegistry.initialize(downloadService: download);
      final resolver = _ScriptedResolver(
        forFileType: ModelFileType.litertlm,
        result: const ResolvedHfModel(
          file: 'm.litertlm',
          url: 'https://huggingface.co/o/r/resolve/main/m.litertlm',
          fileType: ModelFileType.litertlm,
        ),
      );
      HuggingFaceResolverRegistry.instance.registerAll([resolver]);

      final localModel = File(p.join(sourceDir.path, 'local.litertlm'));
      await localModel.writeAsBytes(_fakeModelBytes);

      final install = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromHuggingFace('o/r').fromFile(localModel.path).install();

      expect(resolver.resolveCalls, 0);
      expect(install.runtime, isNull);
      expect(install.spec.modelType, ModelType.gemmaIt);
    });
  });
}

/// Scripted resolver: claims exactly [forFileType]; [resolve] returns [result]
/// or throws [throwError]. Records call count + the token it was handed.
class _ScriptedResolver implements HuggingFaceResolver {
  _ScriptedResolver({required this.forFileType, this.result, this.throwError});
  final ModelFileType forFileType;
  final ResolvedHfModel? result;
  final Object? throwError;
  int resolveCalls = 0;
  String? lastToken;

  @override
  String get name => 'scripted';
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
  }) async {
    resolveCalls++;
    lastToken = token;
    if (throwError != null) throw throwError!;
    return result!;
  }
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

/// Writes [bytes] to whatever target it is asked to download to, recording each
/// requested URL so tests can assert which URL install() actually fetched.
class _FixtureDownloadService implements DownloadService {
  _FixtureDownloadService(this.bytes);
  final Uint8List bytes;
  final List<String> requestedUrls = [];

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
