// installEmbedder().install() (R5 §5.2-5.3): every refusal happens before
// anything is downloaded, a .litertlm bundle installs as one file, and an
// embedder no registered backend can run is refused up front (D13) — on web
// that is what keeps a 165-485 MB EmbeddingGemma 2 download from starting.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_edge_ai/src/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// FileSourceHandler's size floor: 1 MB for model files, 1 KB for .model.
final _modelBytes = Uint8List(1024 * 1024 + 16);
final _tokenizerBytes = Uint8List(2048);

final class _Backend extends EmbeddingBackendProvider {
  const _Backend(this.handles);

  final bool Function(EmbeddingModelSpec spec) handles;

  @override
  String get name => 'Test backend';

  @override
  bool canHandle(EmbeddingModelSpec spec) => handles(spec);

  /// Never reached: these tests stop at install, before any embedder is
  /// built.
  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) => Future.error(UnsupportedError('install pre-check tests build nothing'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late Directory support;
  late Directory sources;
  late String bundlePath;
  late String tflitePath;
  late String tokenizerPath;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('emb_precheck_docs_');
    support = await Directory.systemTemp.createTemp('emb_precheck_sup_');
    sources = await Directory.systemTemp.createTemp('emb_precheck_src_');
    PathProviderPlatform.instance = _FixedPathProvider(
      documents.path,
      support.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EmbeddingRegistry.instance.reset();
    await ServiceRegistry.initialize();

    bundlePath = path.join(sources.path, 'embedder.litertlm');
    await File(bundlePath).writeAsBytes(_modelBytes);
    tflitePath = path.join(sources.path, 'embedder.tflite');
    await File(tflitePath).writeAsBytes(_modelBytes);
    tokenizerPath = path.join(sources.path, 'sentencepiece.model');
    await File(tokenizerPath).writeAsBytes(_tokenizerBytes);
  });

  tearDown(() async {
    ServiceRegistry.reset();
    EmbeddingRegistry.instance.reset();
    for (final dir in [documents, support, sources]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<bool> installed(String filename) =>
      ServiceRegistry.instance.modelRepository.isInstalled(filename);

  group('refused before anything is downloaded', () {
    test('no model source', () async {
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .tokenizerFromFile(tokenizerPath)
            .install(),
        throwsStateError,
      );
      expect(await installed('sentencepiece.model'), isFalse);
    });

    test('a .litertlm bundle with a tokenizer', () async {
      await expectLater(
        FlutterEdgeAi.installEmbedder()
            .modelFromFile(bundlePath)
            .tokenizerFromFile(tokenizerPath)
            .install(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('carries its own tokenizer'),
          ),
        ),
      );
      expect(await installed('embedder.litertlm'), isFalse);
    });

    test('a model that needs a tokenizer, without one', () async {
      await expectLater(
        FlutterEdgeAi.installEmbedder().modelFromFile(tflitePath).install(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Both model and tokenizer required'),
          ),
        ),
      );
      expect(await installed('embedder.tflite'), isFalse);
    });

    test('no registered backend can run it (the install pre-check)', () async {
      EmbeddingRegistry.instance.registerAll([
        _Backend((spec) => !spec.isSelfContained),
      ]);
      await expectLater(
        FlutterEdgeAi.installEmbedder().modelFromFile(bundlePath).install(),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('embedder.litertlm'), contains('Test backend')),
          ),
        ),
      );
      expect(await installed('embedder.litertlm'), isFalse);
      expect(FlutterEdgeAi.hasActiveEmbedder(), isFalse);
    });
  });

  test(
    'a .litertlm bundle installs alone and becomes the active embedder',
    () async {
      EmbeddingRegistry.instance.registerAll([_Backend((_) => true)]);
      final installation = await FlutterEdgeAi.installEmbedder()
          .modelFromFile(bundlePath)
          .install();

      expect(installation.spec.isSelfContained, isTrue);
      expect(await installed('embedder.litertlm'), isTrue);
      expect(FlutterEdgeAi.activeEmbedderSpec, installation.spec);

      final prefs = await SharedPreferences.getInstance();
      final record = ActiveEmbeddingIdentityRecord.tryDecode(
        prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
      );
      expect(record?.schemaVersion, 2, reason: 'persisted as identity v2');
    },
  );

  test(
    'a fresh manager restores the self-contained embedder (identity v2)',
    () async {
      EmbeddingRegistry.instance.registerAll([_Backend((_) => true)]);
      final installation = await FlutterEdgeAi.installEmbedder()
          .modelFromFile(bundlePath)
          .install();

      final fresh = MobileModelManager();
      await fresh.initialize();
      final restored = fresh.activeEmbeddingModel;
      expect(restored, isA<EmbeddingModelSpec>());
      final spec = restored! as EmbeddingModelSpec;
      expect(spec.isSelfContained, isTrue);
      expect(
        spec.files.single.filename,
        installation.spec.files.single.filename,
      );
      expect(spec.modelSource, isA<FileSource>());
    },
  );

  test('a v2 record whose bundle is gone restores nothing', () async {
    EmbeddingRegistry.instance.registerAll([_Backend((_) => true)]);
    await FlutterEdgeAi.installEmbedder().modelFromFile(bundlePath).install();
    await File(bundlePath).delete();

    final fresh = MobileModelManager();
    await fresh.initialize();
    expect(fresh.activeEmbeddingModel, isNull);
  });

  test('with no backend registered the install goes ahead', () async {
    final installation = await FlutterEdgeAi.installEmbedder()
        .modelFromFile(tflitePath)
        .tokenizerFromFile(tokenizerPath)
        .install();
    expect(installation.spec.files, hasLength(2));
    expect(await installed('embedder.tflite'), isTrue);
  });
}

final class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this._documents, this._support);

  final String _documents;
  final String _support;

  @override
  Future<String?> getApplicationDocumentsPath() async => _documents;

  @override
  Future<String?> getApplicationSupportPath() async => _support;

  @override
  Future<String?> getTemporaryPath() async => _support;
}
