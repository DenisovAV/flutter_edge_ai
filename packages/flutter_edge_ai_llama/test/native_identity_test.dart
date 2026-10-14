@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports — creates a fresh platform shell to simulate a process restart.
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
// ignore: implementation_imports — isolates persisted storage between restart fixtures.
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_edge_ai_llama/src/llama_engine_provider.dart'
    show createLlamaProviderForTest;
import 'package:flutter_edge_ai_llama/src/llama_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('edge-llama-identity-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(scratch.path);
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    edge.FlutterEdgeAiPlugin.instance = FlutterEdgeAiMobile();
    await edge.FlutterEdgeAi.initialize(
      inferenceEngines: const [LlamaEngineProvider()],
    );
  });
  tearDown(() async {
    await edge.FlutterEdgeAi.dispose();
    ServiceRegistry.reset();
    PathProviderPlatform.instance = originalPaths;
    await scratch.delete(recursive: true);
  });

  Future<(File, File, edge.InferenceModelSpec)> installPair() async {
    final model = File('${scratch.path}/model.gguf');
    final adapter = File('${scratch.path}/adapter.gguf');
    final bytes = Uint8List(1024 * 1024 + 1);
    await model.writeAsBytes(bytes);
    await adapter.writeAsBytes(bytes);
    final installed = await edge.FlutterEdgeAi.installModel(
      modelType: edge.ModelType.general,
      fileType: edge.ModelFileType.gguf,
    ).fromFile(model.path).withLoraFromFile(adapter.path).install();
    return (model, adapter, installed.spec);
  }

  Future<edge.InferenceModelSpec?> restart() async {
    edge.FlutterEdgeAiPlugin.instance = FlutterEdgeAiMobile();
    final manager = edge.FlutterEdgeAiPlugin.instance.modelManager;
    await manager.ensureInitialized();
    return manager.activeInferenceModel as edge.InferenceModelSpec?;
  }

  test(
    'core restart restores the GGUF adapter and provider resolves its path',
    () async {
      final (model, adapter, installed) = await installPair();
      expect(installed.files[1].filename, 'model__adapter.gguf');
      final restored = await restart();
      expect(restored, isNotNull);
      expect(restored!.fileType, edge.ModelFileType.gguf);
      expect(restored.loraSource, edge.FileSource(adapter.path));
      expect(
        restored.files.map((f) => f.filename),
        installed.files.map((f) => f.filename),
      );
      final paths = await edge.FlutterEdgeAiPlugin.instance.modelManager
          .getModelFilePaths(restored);
      expect(paths?[restored.files[1].prefsKey], adapter.path);
      final engine = _Engine();
      final provider = createLlamaProviderForTest(
        loader: (location, _) async {
          expect(location, model.path);
          return engine;
        },
      );
      final loaded =
          await provider.createModel(
                restored,
                RuntimeConfig(modelPath: model.path, maxTokens: 2048),
              )
              as LlamaInferenceModel;
      try {
        expect(loaded.defaultLoraPath, adapter.path);
        expect(loaded.fileType, edge.ModelFileType.gguf);
      } finally {
        await loaded.close();
      }
    },
  );

  test('missing GGUF adapter prevents core restoring the base alone', () async {
    final (model, adapter, _) = await installPair();
    await adapter.delete();
    expect(await model.exists(), isTrue);
    expect(await restart(), isNull);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Backend implements llama.LlamaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine extends llama.LlamaEngine {
  _Engine() : super(_Backend());
  @override
  llama.LlamaRuntime get runtime => llama.LlamaRuntime.llamaCpp;
  @override
  Future<int?> getResolvedGpuLayers() async => 0;
  @override
  Future<String> getBackendName() async => 'CPU';
  @override
  Future<int> getContextSize() async => 2048;
  @override
  Future<void> dispose() async {}
}
