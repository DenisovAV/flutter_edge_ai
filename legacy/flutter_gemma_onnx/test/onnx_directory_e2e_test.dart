// End-to-end contract test: resolver → core directory install → OnnxEngine
// .createModel → the directory handed to GenAiClient.load. Pins the implicit
// contract that the active spec's modelPath resolves inside the per-model
// subdirectory, so `File(modelPath).parent` is the ORT-GenAI directory the
// engine loads. All FFI/native is faked (FakeGenAiClient); no network.
//
// Run: flutter test test/onnx_directory_e2e_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart';
import 'package:flutter_gemma/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/mobile/flutter_gemma_mobile.dart'
    show MobileModelManager;

import 'package:flutter_gemma_onnx/src/onnx_engine.dart';

import 'fakes/fake_gen_ai_client.dart';

const _modelId = 'org__repo__cpu';
const _dirModel = ResolvedHfModel(
  file: 'genai_config.json',
  url: 'https://huggingface.co/org/repo/resolve/main/cpu/genai_config.json',
  fileType: ModelFileType.onnx,
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

  late Directory docs;
  late Directory support;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('fg_onnx_e2e_docs_');
    support = await Directory.systemTemp.createTemp('fg_onnx_e2e_support_');
    PathProviderPlatform.instance = _FixedPathProvider(docs.path, support.path);
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    OnnxEngine.debugForceUnsupportedHost = null;
  });

  tearDown(() async {
    ServiceRegistry.reset();
    HuggingFaceResolverRegistry.instance.reset();
    OnnxEngine.debugForceUnsupportedHost = null;
    for (final d in [docs, support]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  test('resolver → install → OnnxEngine.createModel hands GenAiClient the '
      'per-model directory (its genai_config.json parent)', () async {
    await ServiceRegistry.initialize(
      downloadService: _FixtureDownload(Uint8List.fromList(List.filled(64, 7))),
    );
    HuggingFaceResolverRegistry.instance.registerAll([_ScriptedResolver()]);

    final install = await FlutterGemma.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.onnx,
    ).fromHuggingFace('org/repo').install();

    // The active directory spec + its resolved modelPath (the engine input).
    final manager =
        FlutterGemmaPlugin.instance.modelManager as MobileModelManager;
    final spec = install.spec;
    final paths = await manager.getModelFilePaths(spec);
    expect(paths, isNotNull);
    final modelPath = paths!.values.first;
    expect(p.basename(modelPath), 'genai_config.json');

    // createModel on a real supported host (macOS arm64) with a FAKE client:
    // the genai_config precheck passes (the bundle is on disk) and the model
    // directory is handed to client.load — this is the resolver→install→engine
    // contract Phase 1+2 rely on.
    final fake = FakeGenAiClient();
    final engine = OnnxEngine(clientFactory: () => fake);
    final model = await engine.createModel(
      spec,
      RuntimeConfig(maxTokens: 1024, modelPath: modelPath),
    );

    expect(fake.loaded, isTrue);
    expect(p.basename(fake.loadedModelDir!), _modelId);
    expect(
      File(p.join(fake.loadedModelDir!, 'genai_config.json')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(fake.loadedModelDir!, 'model.onnx')).existsSync(),
      isTrue,
    );
    await model.close();
  });
}

class _ScriptedResolver implements HuggingFaceResolver {
  @override
  String get name => 'scripted-e2e';
  @override
  int get priority => 0;
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) =>
      fileType == ModelFileType.onnx;
  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async => _dirModel;
}

class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this.docs, this.support);
  final String docs;
  final String support;
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
  @override
  Future<String?> getApplicationSupportPath() async => support;
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

class _FixtureDownload implements DownloadService {
  _FixtureDownload(this.bytes);
  final Uint8List bytes;
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
  }) async => _write(targetPath);

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    await _write(targetPath);
    yield 100;
  }
}
