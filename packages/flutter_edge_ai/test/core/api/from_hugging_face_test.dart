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

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
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
          family: ModelType.qwen3,
          runtime: ModelRuntimeDefaults(
            maxTokens: 4096,
            thinkingDeclared: true,
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
      expect(install.runtime!.thinkingDeclared, true);
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
              // family omitted → resolver could not determine it
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
            family: ModelType.qwen3, // manifest disagrees with the caller
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

  group('resolver roles', () {
    test('an inference and an embedding resolver both claiming onnx: each '
        'builder and resolveHuggingFace(type:) reach only their own', () async {
      await ServiceRegistry.initialize(downloadService: download);
      final llm = _ScriptedResolver(
        name: 'llm',
        forFileType: ModelFileType.onnx,
        throwError: StateError('llm resolver reached'),
      );
      final embedder = _ScriptedResolver(
        name: 'embedder',
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.onnx,
        result: const ResolvedHfModel(
          file: 'model.onnx',
          url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
          fileType: ModelFileType.onnx,
          files: [
            ResolvedHfFile(
              name: 'model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
            ),
            ResolvedHfFile(
              name: 'tokenizer.json',
              url: 'https://huggingface.co/o/e/resolve/abc/tokenizer.json',
            ),
          ],
          tokenizerFile: 'tokenizer.json',
        ),
      );
      // The embedding resolver registered FIRST: were the role ignored, it
      // would win the inference tie too.
      HuggingFaceResolverRegistry.instance.registerAll([embedder, llm]);

      final asEmbedder = await FlutterEdgeAi.resolveHuggingFace(
        'o/e',
        type: ModelManagementType.embedding,
        fileType: ModelFileType.onnx,
      );
      expect(asEmbedder.file, 'model.onnx');
      expect(embedder.resolveCalls, 1);
      expect(llm.resolveCalls, 0);

      await expectLater(
        FlutterEdgeAi.resolveHuggingFace('o/m', fileType: ModelFileType.onnx),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'llm resolver reached',
          ),
        ),
      );
      expect(llm.resolveCalls, 1);
      expect(embedder.resolveCalls, 1);

      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ).fromHuggingFace('o/m').install(),
        throwsA(isA<StateError>()),
      );
      expect(llm.resolveCalls, 2);
      expect(embedder.resolveCalls, 1);

      await FlutterEdgeAi.installEmbedder()
          .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
          .install();
      expect(embedder.resolveCalls, 2);
      expect(llm.resolveCalls, 2);
    });

    test('within a role the first-registered resolver wins the tie', () async {
      final first = _ScriptedResolver(
        name: 'first',
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.onnx,
      );
      final second = _ScriptedResolver(
        name: 'second',
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.onnx,
      );
      HuggingFaceResolverRegistry.instance.registerAll([first, second]);
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          'o/e',
          type: ModelManagementType.embedding,
          fileType: ModelFileType.onnx,
        ),
        same(first),
      );
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          'o/e',
          type: ModelManagementType.inference,
          fileType: ModelFileType.onnx,
        ),
        isNull,
      );
    });

    test('a tokenizerFile that is not among the files is refused', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          type: ModelManagementType.embedding,
          forFileType: ModelFileType.onnx,
          result: const ResolvedHfModel(
            file: 'model.onnx',
            url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
            fileType: ModelFileType.onnx,
            tokenizerFile: 'tokenizer.json',
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.resolveHuggingFace(
          'o/e',
          type: ModelManagementType.embedding,
          fileType: ModelFileType.onnx,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('tokenizerFile "tokenizer.json"'),
          ),
        ),
      );
    });
  });

  group('resolveHuggingFace refusals', () {
    test('a tokenizerFile that is the model file is refused, naming the '
        'resolver', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          name: 'twice',
          type: ModelManagementType.embedding,
          forFileType: ModelFileType.onnx,
          result: const ResolvedHfModel(
            file: 'model.onnx',
            url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
            fileType: ModelFileType.onnx,
            files: [ResolvedHfFile(name: 'model.onnx', url: 'u')],
            tokenizerFile: 'model.onnx',
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.resolveHuggingFace(
          'o/e',
          type: ModelManagementType.embedding,
          fileType: ModelFileType.onnx,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"twice"'), contains('model file "model.onnx"')),
          ),
        ),
      );
    });

    test('with no resolver of the role, one of another role that claims the '
        'repo is named', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(name: 'minilm', forFileType: ModelFileType.onnx),
      ]);
      await expectLater(
        FlutterEdgeAi.resolveHuggingFace(
          'o/e',
          type: ModelManagementType.embedding,
          fileType: ModelFileType.onnx,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              '"minilm" claims onnx but serves inference; check its '
              '`type`',
            ),
          ),
        ),
      );
      // A resolver that does not claim the file type is not named.
      await expectLater(
        FlutterEdgeAi.resolveHuggingFace(
          'o/e',
          type: ModelManagementType.embedding,
          fileType: ModelFileType.litertlm,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            isNot(contains('minilm')),
          ),
        ),
      );
    });
  });

  group('family', () {
    test('the inference installer refuses a family that is not a ModelType, '
        'before any download', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          forFileType: ModelFileType.litertlm,
          result: const ResolvedHfModel(
            file: 'model.litertlm',
            url: 'https://huggingface.co/o/r/resolve/main/model.litertlm',
            fileType: ModelFileType.litertlm,
            family: SttModelType.whisper,
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.installModel(
          modelType: ModelType.general,
          fileType: ModelFileType.litertlm,
        ).fromHuggingFace('o/r').install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('whisper'),
          ),
        ),
      );
      expect(download.requestedUrls, isEmpty);
    });
  });

  group('installEmbedder().fromHuggingFace', () {
    test('installs the model and its tokenizer from the resolver URLs, under '
        'their own names, and returns the runtime defaults', () async {
      await ServiceRegistry.initialize(downloadService: download);
      // A growable list: the installation must not hand it out writable.
      final resolverNotes = ['embedder note'];
      final resolver = _ScriptedResolver(
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.onnx,
        result: ResolvedHfModel(
          file: 'minilm-model.onnx',
          url: 'https://huggingface.co/o/e/resolve/abc/onnx/model.onnx',
          fileType: ModelFileType.onnx,
          files: [
            ResolvedHfFile(
              name: 'minilm-model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/onnx/model.onnx',
            ),
            ResolvedHfFile(
              name: 'minilm-tokenizer.json',
              url: 'https://huggingface.co/o/e/resolve/abc/tokenizer.json',
            ),
          ],
          tokenizerFile: 'minilm-tokenizer.json',
          runtime: ModelRuntimeDefaults(preferredBackend: PreferredBackend.cpu),
          notes: resolverNotes,
        ),
      );
      HuggingFaceResolverRegistry.instance.registerAll([resolver]);

      final install = await FlutterEdgeAi.installEmbedder()
          .fromHuggingFace('o/e', fileType: ModelFileType.onnx, token: 'hf_e')
          .install();

      // The per-call token reaches the resolution and both downloads.
      expect(resolver.lastToken, 'hf_e');
      expect(download.requestedTokens, ['hf_e', 'hf_e']);

      expect(download.requestedUrls, [
        'https://huggingface.co/o/e/resolve/abc/onnx/model.onnx',
        'https://huggingface.co/o/e/resolve/abc/tokenizer.json',
      ]);
      expect(install.spec.files.map((f) => f.filename), [
        'minilm-model.onnx',
        'minilm-tokenizer.json',
      ]);
      expect(install.runtime?.preferredBackend, PreferredBackend.cpu);
      // The resolver's notes reach the installation, unmodifiable.
      expect(install.notes, ['embedder note']);
      expect(() => install.notes.add('x'), throwsUnsupportedError);
      expect(FlutterEdgeAi.activeEmbedderSpec?.name, install.spec.name);
    });

    test('a single-file resolution installs that file under its leaf name, '
        'with no tokenizer', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          type: ModelManagementType.embedding,
          forFileType: ModelFileType.litertlm,
          result: const ResolvedHfModel(
            file: 'sub/eg2.litertlm',
            url: 'https://huggingface.co/o/e/resolve/abc/sub/eg2.litertlm',
            fileType: ModelFileType.litertlm,
          ),
        ),
      ]);
      final install = await FlutterEdgeAi.installEmbedder()
          .fromHuggingFace('o/e', fileType: ModelFileType.litertlm)
          .install();
      expect(install.spec.files.map((f) => f.filename), ['eg2.litertlm']);
      expect(download.requestedUrls, [
        'https://huggingface.co/o/e/resolve/abc/sub/eg2.litertlm',
      ]);
      expect(install.runtime, isNotNull);
    });

    test('a directory resolution is refused with UnsupportedError before any '
        'download', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          type: ModelManagementType.embedding,
          forFileType: ModelFileType.onnx,
          result: const ResolvedHfModel(
            file: 'model.onnx',
            url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
            fileType: ModelFileType.onnx,
            files: [
              ResolvedHfFile(
                name: 'model.onnx',
                url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
              ),
            ],
            directoryName: 'o__e',
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
            .install(),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('embedder directories are not supported yet'),
          ),
        ),
      );
      expect(download.requestedUrls, isEmpty);
    });

    test(
      'files beyond the model and its tokenizer are a directory too',
      () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(
            type: ModelManagementType.embedding,
            forFileType: ModelFileType.onnx,
            result: const ResolvedHfModel(
              file: 'model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
              fileType: ModelFileType.onnx,
              files: [
                ResolvedHfFile(name: 'model.onnx', url: 'u1'),
                ResolvedHfFile(name: 'model.onnx_data', url: 'u2'),
              ],
            ),
          ),
        ]);
        await expectLater(
          FlutterEdgeAi.installEmbedder()
              .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
              .install(),
          throwsA(isA<UnsupportedError>()),
        );
        expect(download.requestedUrls, isEmpty);
      },
    );

    test('a resolution with a model family is refused before any '
        'download', () async {
      await ServiceRegistry.initialize(downloadService: download);
      HuggingFaceResolverRegistry.instance.registerAll([
        _ScriptedResolver(
          type: ModelManagementType.embedding,
          forFileType: ModelFileType.litertlm,
          result: const ResolvedHfModel(
            file: 'eg2.litertlm',
            url: 'https://huggingface.co/o/e/resolve/abc/eg2.litertlm',
            fileType: ModelFileType.litertlm,
            family: ModelType.gemmaIt,
          ),
        ),
      ]);
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .fromHuggingFace('o/e', fileType: ModelFileType.litertlm)
            .install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('embedders have no family type'),
          ),
        ),
      );
      expect(download.requestedUrls, isEmpty);
    });

    test('a cancel during the resolution stops the install before the '
        'resolved files are checked', () async {
      await ServiceRegistry.initialize(downloadService: download);
      final resolver = _ScriptedResolver(
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.onnx,
        // A model with no tokenizer: checking it would throw StateError.
        result: const ResolvedHfModel(
          file: 'model.onnx',
          url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
          fileType: ModelFileType.onnx,
        ),
      );
      HuggingFaceResolverRegistry.instance.registerAll([resolver]);
      final token = CancelToken();
      resolver.onResolve = () => token.cancel('stop');
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
            .withCancelToken(token)
            .install(),
        throwsA(isA<DownloadCancelledException>()),
      );
    });

    test('a later source setter clears it; it clears an earlier source; '
        'cancel is checked right after the resolution', () async {
      await ServiceRegistry.initialize(downloadService: download);
      final resolver = _ScriptedResolver(
        type: ModelManagementType.embedding,
        forFileType: ModelFileType.litertlm,
        result: const ResolvedHfModel(
          file: 'eg2.litertlm',
          url: 'https://huggingface.co/o/e/resolve/abc/eg2.litertlm',
          fileType: ModelFileType.litertlm,
        ),
      );
      HuggingFaceResolverRegistry.instance.registerAll([resolver]);

      final local = File(p.join(sourceDir.path, 'local.litertlm'));
      await local.writeAsBytes(_fakeModelBytes);
      final viaFile = await FlutterEdgeAi.installEmbedder()
          .fromHuggingFace('o/e', fileType: ModelFileType.litertlm)
          .modelFromFile(local.path)
          .install();
      expect(resolver.resolveCalls, 0);
      expect(viaFile.runtime, isNull);
      expect(viaFile.notes, isEmpty);

      // An earlier source's expectation is cleared too: were the size of 1
      // applied to the resolved file, the install would fail.
      final viaHf = await FlutterEdgeAi.installEmbedder()
          .modelFromNetwork(
            'https://example.com/other.litertlm',
            expectedSize: 1,
          )
          .fromHuggingFace('o/e', fileType: ModelFileType.litertlm)
          .install();
      expect(resolver.resolveCalls, 1);
      expect(viaHf.spec.files.single.filename, 'eg2.litertlm');
      expect(download.requestedUrls, [
        'https://huggingface.co/o/e/resolve/abc/eg2.litertlm',
      ]);
      download.requestedUrls.clear();

      final token = CancelToken();
      final cancelled = FlutterEdgeAi.installEmbedder()
          .modelFromNetwork('https://example.com/other.litertlm')
          .fromHuggingFace('o/e', fileType: ModelFileType.litertlm)
          .withCancelToken(token);
      resolver.onResolve = () => token.cancel('stop');
      await expectLater(
        cancelled.install(),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(resolver.resolveCalls, 2);
      expect(download.requestedUrls, isEmpty);
    });

    group('sizes', () {
      const modelUrl = 'https://huggingface.co/o/e/resolve/abc/onnx/model.onnx';
      const tokUrl = 'https://huggingface.co/o/e/resolve/abc/tokenizer.json';
      // The active embedder outlives a test (the plugin's model manager is
      // process-wide), so each test installs files of its own names.
      ResolvedHfModel withSizes(String prefix, {int? model, int? tokenizer}) =>
          ResolvedHfModel(
            file: '$prefix-model.onnx',
            url: modelUrl,
            fileType: ModelFileType.onnx,
            files: [
              ResolvedHfFile(
                name: '$prefix-model.onnx',
                url: modelUrl,
                sizeBytes: model,
              ),
              ResolvedHfFile(
                name: '$prefix-tokenizer.json',
                url: tokUrl,
                sizeBytes: tokenizer,
              ),
            ],
            tokenizerFile: '$prefix-tokenizer.json',
          );
      void register(ResolvedHfModel result) =>
          HuggingFaceResolverRegistry.instance.registerAll([
            _ScriptedResolver(
              type: ModelManagementType.embedding,
              forFileType: result.fileType,
              result: result,
            ),
          ]);
      Future<EmbeddingInstallation> installIt(ModelFileType fileType) =>
          FlutterEdgeAi.installEmbedder()
              .fromHuggingFace('o/e', fileType: fileType)
              .install();

      test('files of the sizes the resolver gave install and activate, and '
          'progress asks the network for no size', () async {
        final probe = _RecordingProbe();
        await ServiceRegistry.initialize(
          downloadService: download,
          remoteSizeProbe: probe,
        );
        register(
          withSizes(
            'ok',
            model: _fakeModelBytes.length,
            tokenizer: _fakeModelBytes.length,
          ),
        );
        final progress = <int>[];
        final install = await FlutterEdgeAi.installEmbedder()
            .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
            .withProgress(progress.add)
            .install();
        expect(FlutterEdgeAi.activeEmbedderSpec?.name, install.spec.name);
        expect(probe.asked, isEmpty);
        expect(progress.last, 100);
      });

      test('a model of another size fails the install before it activates, '
          'and is deleted with its record', () async {
        await ServiceRegistry.initialize(downloadService: download);
        final activeBefore = FlutterEdgeAi.activeEmbedderSpec?.name;
        register(withSizes('bad-model', model: 123));
        await expectLater(
          installIt(ModelFileType.onnx),
          throwsA(
            isA<ModelValidationException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('bad-model-model.onnx'),
                contains('${_fakeModelBytes.length} bytes'),
                contains('123 expected'),
              ),
            ),
          ),
        );
        expect(FlutterEdgeAi.activeEmbedderSpec?.name, activeBefore);
        expect(
          await FlutterEdgeAi.isModelInstalled('bad-model-model.onnx'),
          isFalse,
        );
      });

      test('a tokenizer of another size fails the install too', () async {
        await ServiceRegistry.initialize(downloadService: download);
        final activeBefore = FlutterEdgeAi.activeEmbedderSpec?.name;
        register(withSizes('bad-tok', tokenizer: 7));
        await expectLater(
          installIt(ModelFileType.onnx),
          throwsA(
            isA<ModelValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('bad-tok-tokenizer.json'), contains('7 expected')),
            ),
          ),
        );
        expect(FlutterEdgeAi.activeEmbedderSpec?.name, activeBefore);
      });

      test('a single file of another size than ResolvedHfModel.sizeBytes '
          'fails the install', () async {
        await ServiceRegistry.initialize(downloadService: download);
        final activeBefore = FlutterEdgeAi.activeEmbedderSpec?.name;
        register(
          const ResolvedHfModel(
            file: 'single-bad.litertlm',
            url: 'https://huggingface.co/o/e/resolve/abc/single-bad.litertlm',
            fileType: ModelFileType.litertlm,
            sizeBytes: 99,
          ),
        );
        await expectLater(
          installIt(ModelFileType.litertlm),
          throwsA(
            isA<ModelValidationException>().having(
              (e) => e.message,
              'message',
              contains('99 expected'),
            ),
          ),
        );
        expect(FlutterEdgeAi.activeEmbedderSpec?.name, activeBefore);
      });

      test('a negative size is refused before any download', () async {
        await ServiceRegistry.initialize(downloadService: download);
        register(withSizes('negative', tokenizer: -1));
        await expectLater(installIt(ModelFileType.onnx), throwsArgumentError);
        expect(download.requestedUrls, isEmpty);
      });

      test('with a size, an install over the active embedder\'s file from '
          'another source is refused before it downloads', () async {
        await ServiceRegistry.initialize(downloadService: download);
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork('https://example.com/old/shared-eg2.litertlm')
            .install();
        download.requestedUrls.clear();
        register(
          ResolvedHfModel(
            file: 'shared-eg2.litertlm',
            url: 'https://huggingface.co/o/e/resolve/abc/shared-eg2.litertlm',
            fileType: ModelFileType.litertlm,
            sizeBytes: _fakeModelBytes.length,
          ),
        );
        await expectLater(
          installIt(ModelFileType.litertlm),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('the active embedding model shared-eg2 reads'),
            ),
          ),
        );
        expect(download.requestedUrls, isEmpty);
        expect(FlutterEdgeAi.activeEmbedderSpec?.name, 'shared-eg2');
      });
    });

    group('shapes', () {
      test('a nested file installs by the bare member name it has in '
          'files', () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(
            type: ModelManagementType.embedding,
            forFileType: ModelFileType.onnx,
            result: const ResolvedHfModel(
              file: 'onnx/n-model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/onnx/n-model.onnx',
              fileType: ModelFileType.onnx,
              files: [
                ResolvedHfFile(
                  name: 'n-model.onnx',
                  url:
                      'https://huggingface.co/o/e/resolve/abc/onnx/n-model.onnx',
                ),
                ResolvedHfFile(
                  name: 'n-tokenizer.json',
                  url: 'https://huggingface.co/o/e/resolve/abc/tokenizer.json',
                ),
              ],
              tokenizerFile: 'n-tokenizer.json',
            ),
          ),
        ]);
        final install = await FlutterEdgeAi.installEmbedder()
            .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
            .install();
        expect(install.spec.files.map((f) => f.filename), [
          'n-model.onnx',
          'n-tokenizer.json',
        ]);
      });

      test('a file that is not among the files is refused, naming the repo '
          'and the file', () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(
            type: ModelManagementType.embedding,
            forFileType: ModelFileType.onnx,
            result: const ResolvedHfModel(
              file: 'model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
              fileType: ModelFileType.onnx,
              files: [ResolvedHfFile(name: 'tokenizer.json', url: 'u')],
              tokenizerFile: 'tokenizer.json',
            ),
          ),
        ]);
        await expectLater(
          FlutterEdgeAi.installEmbedder()
              .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
              .install(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('"o/e"'),
                contains('file "model.onnx", which is not among its files'),
              ),
            ),
          ),
        );
        expect(download.requestedUrls, isEmpty);
      });

      test('a model that needs a tokenizer resolved without one is refused, '
          'naming the resolver', () async {
        await ServiceRegistry.initialize(downloadService: download);
        HuggingFaceResolverRegistry.instance.registerAll([
          _ScriptedResolver(
            name: 'minilm-resolver',
            type: ModelManagementType.embedding,
            forFileType: ModelFileType.onnx,
            result: const ResolvedHfModel(
              file: 'model.onnx',
              url: 'https://huggingface.co/o/e/resolve/abc/model.onnx',
              fileType: ModelFileType.onnx,
            ),
          ),
        ]);
        await expectLater(
          FlutterEdgeAi.installEmbedder()
              .fromHuggingFace('o/e', fileType: ModelFileType.onnx)
              .install(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('"minilm-resolver"'),
                contains('"o/e"'),
                contains('resolved "o/e" without a tokenizerFile'),
              ),
            ),
          ),
        );
        expect(download.requestedUrls, isEmpty);
      });
    });
  });
}

/// Scripted resolver: claims exactly [forFileType]; [resolve] returns [result]
/// or throws [throwError]. Records call count + the token it was handed.
class _ScriptedResolver implements HuggingFaceResolver {
  _ScriptedResolver({
    required this.forFileType,
    this.result,
    this.throwError,
    this.type = ModelManagementType.inference,
    this.name = 'scripted',
  });
  final ModelFileType forFileType;
  @override
  final ModelManagementType type;
  @override
  final String name;
  final ResolvedHfModel? result;
  final Object? throwError;
  int resolveCalls = 0;
  String? lastToken;
  void Function()? onResolve;

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
    onResolve?.call();
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
  final List<String?> requestedTokens = [];

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requestedUrls.add(url);
    requestedTokens.add(token);
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
    requestedTokens.add(token);
    await File(targetPath).writeAsBytes(bytes);
    yield 100;
  }
}

/// Records every HEAD a byte-weighted progress asks for; knows no size.
final class _RecordingProbe implements RemoteSizeProbe {
  final asked = <String>[];

  @override
  Future<int?> sizeOf(
    String url, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    asked.add(url);
    return null;
  }
}
