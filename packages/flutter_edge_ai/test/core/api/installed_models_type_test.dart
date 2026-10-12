// Regression test for #391 — getInstalledModels(stt/tts/embedding) returned
// empty because every SourceHandler.install() hardcoded ModelType.inference
// when saving the ModelInfo, so the type-filtered listing never matched.
//
// These drive the REAL install flow (FileSourceHandler → repository.saveModel)
// over a temp filesystem, then assert the type-filtered listing.
//
// Run: flutter test test/core/api/installed_models_type_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/stt_registry.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final _fakeModelBytes = Uint8List(1024 * 1024 + 16);
final _fakeTokenizerBytes = Uint8List(2048);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory sourceDir;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_appsupport_');
    sourceDir = await Directory.systemTemp.createTemp('fg_src_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
    EmbeddingRegistry.instance.reset();
    await FlutterEdgeAiPlugin.instance.modelManager.clearActiveSttIdentity();
    await FlutterEdgeAiPlugin.instance.modelManager
        .clearActiveEmbeddingIdentity();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
    EmbeddingRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, sourceDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test(
    'an installed STT model is listed under stt, not inference (#391)',
    () async {
      await FlutterEdgeAi.initialize(sttBackends: [_FakeSttBackend()]);

      final modelFile = File(path.join(sourceDir.path, 'model.tflite'));
      await modelFile.writeAsBytes(_fakeModelBytes);
      final tokenizerFile = File(path.join(sourceDir.path, 'tokenizer.json'));
      await tokenizerFile.writeAsBytes(_fakeTokenizerBytes);

      await FlutterEdgeAi.installStt()
          .modelFromFile(modelFile.path)
          .tokenizerFromFile(tokenizerFile.path)
          .ofType(SttModelType.moonshine)
          .install();

      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final sttModels = await manager.getInstalledModels(
        ModelManagementType.stt,
      );
      final inferenceModels = await manager.getInstalledModels(
        ModelManagementType.inference,
      );

      // The just-installed STT model must show up under the stt filter...
      expect(
        sttModels,
        isNotEmpty,
        reason: 'getInstalledModels(stt) must return the installed STT model',
      );
      // ...and must NOT leak into the inference bucket (which would also make the
      // inference replace-policy cleanup delete STT files).
      expect(
        inferenceModels,
        isEmpty,
        reason: 'an STT install must not be tagged inference',
      );
    },
  );

  test(
    'an installed embedding model is listed under embedding, not inference (#391)',
    () async {
      await FlutterEdgeAi.initialize(
        embeddingBackends: [_FakeEmbeddingBackend()],
      );

      final modelFile = File(path.join(sourceDir.path, 'embed.tflite'));
      await modelFile.writeAsBytes(_fakeModelBytes);
      final tokenizerFile = File(
        path.join(sourceDir.path, 'embed_tokenizer.json'),
      );
      await tokenizerFile.writeAsBytes(_fakeTokenizerBytes);

      await FlutterEdgeAi.installEmbedder()
          .modelFromFile(modelFile.path)
          .tokenizerFromFile(tokenizerFile.path)
          .install();

      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final embedModels = await manager.getInstalledModels(
        ModelManagementType.embedding,
      );
      final inferenceModels = await manager.getInstalledModels(
        ModelManagementType.inference,
      );

      expect(
        embedModels,
        isNotEmpty,
        reason:
            'getInstalledModels(embedding) must return the installed embedder',
      );
      expect(
        inferenceModels,
        isEmpty,
        reason: 'an embedder install must not be tagged inference',
      );
    },
  );
}

/// Claims every spec and describes a trivial pass. These tests install and
/// introspect; nothing builds the embedder.
final class _FakeEmbeddingBackend extends EmbeddingBackendProvider {
  @override
  String get name => 'FakeEmbedding';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async => const EmbeddingPassDescriptor<String>(
    engineTag: 'Fake',
    factory: _buildFakePass,
    config: 'fake',
    activeBackend: PreferredBackend.cpu,
  );
}

EmbeddingPass _buildFakePass(String _) => _FakePass();

final class _FakePass extends EmbeddingPass {
  @override
  Future<EmbeddingPassInfo> load() async =>
      const EmbeddingPassInfo(dimension: 1);

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      const [0.0];

  @override
  Future<void> close() async {}
}

class _FakeSttBackend implements SttBackendProvider {
  @override
  String get name => 'FakeSTT';
  @override
  int get priority => 0;
  @override
  bool canHandle(SttModelSpec spec) => true;
  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) async => _FakeSpeechRecognizer();
}

class _FakeSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async =>
      'fake';
  @override
  Future<void> close() async => fireCloseListeners();
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
