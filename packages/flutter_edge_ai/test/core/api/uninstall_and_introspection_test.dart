// Unit test for the 1.5.0 facade API-completeness surface:
//   - destructive uninstallEmbedder() (deletes model + tokenizer, clears the
//     active identity, no-op when nothing is active),
//   - the typed identity getters (activeEmbedderSpec vs the other modalities),
//   - getModelPath() resolving an installed file's on-device path.
//
// Mirrors stt_install_plumbing_test.dart: drives the real
// FlutterEdgeAiPlugin.instance.modelManager singleton end-to-end in a plain
// `flutter test` via a SharedPreferences mock + a PathProviderPlatform stub —
// no device, no native engine.
//
// Run: flutter test test/core/api/uninstall_and_introspection_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// FileSourceHandler enforces a minimum size per extension (1MB for model
// files, 1KB for small/config extensions like .json) to catch truncated
// downloads — the fixtures below must clear both thresholds or "install"
// rejects them as corrupted.
final _fakeModelBytes = Uint8List(1024 * 1024 + 16);
final _fakeTokenizerBytes = Uint8List(2048);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory sourceDir;
  late _FixedPathProviderPlatform mockProvider;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    sourceDir = await Directory.systemTemp.createTemp('flutter_edge_ai_src_');
    mockProvider = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    PathProviderPlatform.instance = mockProvider;
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EmbeddingRegistry.instance.reset();
    // The default FlutterEdgeAiPlugin instance (and its model manager) is a
    // process-wide singleton that outlives each test — clear any active
    // embedder identity a previous test left behind so tests stay independent.
    await FlutterEdgeAiPlugin.instance.modelManager
        .clearActiveEmbeddingIdentity();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    EmbeddingRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, sourceDir]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  // FileSourceHandler references external files in place (no copy). To
  // exercise the real managed-storage deletion path, seed the fixtures INSIDE
  // the managed model directory (Application Support/flutter_gemma on the
  // desktop test host; the name is kept across the rename) so the "external" path IS the managed path — then
  // getModelPath resolves to them and uninstall deletes them.
  Future<EmbeddingModelSpec> installEmbedder() async {
    final managedDir = Directory(
      path.join(fakeAppSupport.path, 'flutter_gemma'),
    );
    await managedDir.create(recursive: true);

    final modelFile = File(path.join(managedDir.path, 'model.tflite'));
    await modelFile.writeAsBytes(_fakeModelBytes);
    final tokenizerFile = File(path.join(managedDir.path, 'tokenizer.json'));
    await tokenizerFile.writeAsBytes(_fakeTokenizerBytes);

    final installation = await FlutterEdgeAi.installEmbedder()
        .modelFromFile(modelFile.path)
        .tokenizerFromFile(tokenizerFile.path)
        .install();
    return installation.spec;
  }

  group('uninstallEmbedder + introspection', () {
    test(
      'install sets a typed active spec; getModelPath resolves both files',
      () async {
        await FlutterEdgeAi.initialize(
          embeddingBackends: [_FakeEmbeddingBackend()],
        );

        final spec = await installEmbedder();
        expect(spec, isA<EmbeddingModelSpec>());

        // Typed getter returns the right runtime type; the other modalities
        // are null (guards against a copy-paste miswire reading a sibling
        // slot).
        expect(FlutterEdgeAi.hasActiveEmbedder(), isTrue);
        expect(FlutterEdgeAi.activeEmbedderSpec, isA<EmbeddingModelSpec>());
        expect(FlutterEdgeAi.activeModelSpec, isNull);
        expect(FlutterEdgeAi.activeSttSpec, isNull);
        expect(FlutterEdgeAi.activeTtsSpec, isNull);

        // Both installed files (model + tokenizer) resolve to a real on-disk
        // path via getModelPath.
        expect(spec.files.length, 2);
        for (final file in spec.files) {
          final resolved = await FlutterEdgeAi.getModelPath(file.filename);
          expect(
            File(resolved).existsSync(),
            isTrue,
            reason: '${file.filename} should exist after install',
          );
        }
      },
    );

    test(
      'uninstallEmbedder deletes ALL files and clears the active identity',
      () async {
        await FlutterEdgeAi.initialize(
          embeddingBackends: [_FakeEmbeddingBackend()],
        );

        final spec = await installEmbedder();
        final paths = [
          for (final file in spec.files)
            await FlutterEdgeAi.getModelPath(file.filename),
        ];
        expect(paths.every((p) => File(p).existsSync()), isTrue);

        await FlutterEdgeAi.uninstallEmbedder();

        // Both the model AND the tokenizer are gone — not just one file.
        for (final p in paths) {
          expect(
            File(p).existsSync(),
            isFalse,
            reason: '$p should be deleted by uninstallEmbedder',
          );
        }
        // Identity cleared → getActiveEmbedder now fails fast.
        expect(FlutterEdgeAi.hasActiveEmbedder(), isFalse);
        expect(FlutterEdgeAi.activeEmbedderSpec, isNull);
        expect(() => FlutterEdgeAi.getActiveEmbedder(), throwsStateError);
      },
    );

    test('uninstallEmbedder is a no-op when nothing is active', () async {
      await FlutterEdgeAi.initialize(
        embeddingBackends: [_FakeEmbeddingBackend()],
      );
      expect(FlutterEdgeAi.hasActiveEmbedder(), isFalse);
      // Must complete without throwing.
      await FlutterEdgeAi.uninstallEmbedder();
      expect(FlutterEdgeAi.hasActiveEmbedder(), isFalse);
    });
  });
}

class _FakeEmbeddingBackend implements EmbeddingBackendProvider {
  @override
  String get name => 'FakeEmbedding';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingModel> createModel(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async => _FakeEmbeddingModel();
}

class _FakeEmbeddingModel extends EmbeddingModel with CloseNotifier {
  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [0.0];

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [
    [0.0],
  ];

  @override
  Future<int> getDimension() async => 1;

  @override
  Future<void> close() async {
    fireCloseListeners();
  }
}

/// PathProviderPlatform stub returning fixed Documents / ApplicationSupport
/// paths so the model manager resolves into temp dirs under test.
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
