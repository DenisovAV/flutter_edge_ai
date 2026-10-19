import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_loader.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EmbedderCache cache;
  late _Provider provider;
  late _Manager manager;
  Future<EmbeddingModel> load({
    PreferredBackend? backend,
    bool image = false,
  }) => cache.serialize(
    () => loadActiveEmbedder(
      manager: manager,
      cache: cache,
      preferredBackend: backend,
      supportImage: image,
      supportAudio: false,
      entryPoint:
          ({preferredBackend, supportImage = false, supportAudio = false}) =>
              load(backend: preferredBackend, image: supportImage),
    ),
  );

  setUp(() {
    cache = EmbedderCache();
    provider = _Provider();
    manager = _Manager();
    EmbeddingRegistry.instance.reset();
    EmbeddingRegistry.instance.registerAll([provider]);
    resetEmbedderBackendNotice();
    edgeAiLogLevel = EdgeAiLogLevel.info;
  });
  tearDown(() async {
    await cache.model?.close();
    EmbeddingRegistry.instance.reset();
    resetEmbedderBackendNotice();
    edgeAiLogLevel = EdgeAiLogLevel.info;
  });

  test(
    'GPU and default RAG-shaped requests alternate without closing holders',
    () async {
      final gpu = await load(backend: PreferredBackend.gpu);
      for (var i = 0; i < 10; i++) {
        expect(await load(), same(gpu));
        expect(await load(backend: PreferredBackend.gpu), same(gpu));
        expect(
          await gpu.embed(
            EmbeddingInput.text('query'),
            taskType: TaskType.retrievalQuery,
          ),
          [1, 0],
        );
      }
      expect(provider.configs, hasLength(1));
      expect(provider.capabilityCalls, 21);
      expect(gpu.isClosed, isFalse);
      expect(cache.params!.activeBackend, PreferredBackend.gpu);
      final cpu = await load(backend: PreferredBackend.cpu);
      expect(gpu.isClosed, isTrue);
      expect(cpu.activeBackend, PreferredBackend.cpu);
      expect(provider.configs, hasLength(2));
    },
  );

  test('media widening preserves a GPU cache key before loading', () {
    final params = ActiveEmbedderParams(
      modelPath: '/fixture',
      preferredBackend: PreferredBackend.gpu,
      normalizeBackend: false,
    );
    final widened = params.withMedia({EmbeddingModality.image});
    expect(widened.activeBackend, PreferredBackend.gpu);
    expect(widened.media, contains(EmbeddingModality.image));
  });

  test('automatic first load is recorded under its reported backend', () async {
    final model = await load();
    expect(model.activeBackend, PreferredBackend.gpu);
    expect(await load(backend: PreferredBackend.gpu), same(model));
    expect(provider.configs, hasLength(1));
  });

  test('GPU fallback is loud with logging disabled and CPU reuses it', () async {
    provider.loaded = PreferredBackend.cpu;
    edgeAiLogLevel = EdgeAiLogLevel.none;
    final lines = <String>[];
    await runZoned(
      () async {
        final model = await load(backend: PreferredBackend.gpu);
        expect(model.activeBackend, PreferredBackend.cpu);
        expect(await load(backend: PreferredBackend.cpu), same(model));
        expect(await load(), same(model));
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    expect(lines, [
      '[flutter_edge_ai] WARNING: embedding preferredBackend gpu '
          'fell back to cpu. Read EmbeddingModel.activeBackend for the backend in use.',
    ]);
    expect(provider.configs, hasLength(1));
  });

  test(
    'NPU requests keep a separate key even when capabilities claim CPU only',
    () async {
      provider.capabilities = {PreferredBackend.cpu};
      provider.loaded = PreferredBackend.cpu;
      final cpu = await load(backend: PreferredBackend.cpu);
      final npu = await load(backend: PreferredBackend.npu);
      expect(npu, isNot(same(cpu)));
      expect(cpu.isClosed, isTrue);
      expect(cache.params!.activeBackend, PreferredBackend.npu);
      expect(await load(), same(npu));
      final again = await load(backend: PreferredBackend.cpu);
      expect(again, isNot(same(npu)));
      expect(provider.configs, hasLength(3));
    },
  );

  for (final backend in [PreferredBackend.gpu, PreferredBackend.npu]) {
    test(
      'automatic media widening retains ${backend.name} key and placement',
      () async {
        provider.capabilities = PreferredBackend.values.toSet();
        final text = await load(backend: backend);
        final image = await load(image: true);
        expect(text.isClosed, isTrue);
        expect(provider.configs.last.preferredBackend, backend);
        expect(cache.params!.activeBackend, backend);
        expect(image.activeBackend, backend);
        expect(image.modalities, contains(EmbeddingModality.image));
        expect(await load(backend: backend, image: true), same(image));
        expect(provider.configs, hasLength(2));
      },
    );
  }

  test(
    'capability hook throws once, wrapped with cause and before eviction',
    () async {
      final model = await load();
      final cause = StateError('capability failed');
      provider.failure = cause;
      await expectLater(
        load(),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.cause,
            'cause',
            same(cause),
          ),
        ),
      );
      expect(provider.capabilityCalls, 2);
      expect(model.isClosed, isFalse);
      expect(provider.configs, hasLength(1));
    },
  );

  test(
    'GPU descriptor is not accepted without a loaded report; retry is clean',
    () async {
      provider.omitReport = true;
      provider.descriptorBackend = PreferredBackend.gpu;
      await expectLater(
        load(backend: PreferredBackend.gpu),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            contains('did not report'),
          ),
        ),
      );
      expect(cache.model, isNull);
      provider.omitReport = false;
      expect((await load()).activeBackend, PreferredBackend.gpu);
    },
  );

  test(
    'legacy fixed descriptor placement remains compatible, including web GPU',
    () async {
      provider.capabilities = {PreferredBackend.cpu, PreferredBackend.npu};
      provider.omitReport = true;
      provider.descriptorBackend = PreferredBackend.gpu;
      final model = await load();
      expect(model.activeBackend, PreferredBackend.gpu);
      expect(await load(), same(model));
    },
  );

  for (final capable in [false, true]) {
    test(
      '${capable ? "GPU-capable" : "default"} provider positive notice wiring',
      () async {
        if (!capable) {
          provider.capabilities = {PreferredBackend.cpu, PreferredBackend.npu};
        }
        final lines = <String>[];
        final original = debugPrint;
        debugPrint = (String? line, {int? wrapWidth}) {
          if (line != null) lines.add(line);
        };
        try {
          final model = await load(backend: PreferredBackend.gpu);
          expect(await load(backend: PreferredBackend.gpu), same(model));
        } finally {
          debugPrint = original;
        }
        final notices = lines.where(
          (line) => line.contains('preferredBackend'),
        );
        if (capable) {
          expect(notices, isEmpty);
        } else {
          expect(notices, [
            kIsWeb
                ? 'ℹ️  preferredBackend gpu is not applied to embeddings on web: the runtime picks the accelerator (WebGPU first, WASM as the fallback; EmbeddingGemma 2 .litertlm runs on WebGPU only). Read EmbeddingModel.activeBackend: gpu for EmbeddingGemma 2, null when the runtime does not report one; with LiteRT.js, window.getLiteRtEmbeddingAccelerator() names it after the first embedding.'
                : 'ℹ️  Embeddings run on CPU: preferredBackend gpu is not applied. Read EmbeddingModel.activeBackend for the backend in use — it is available in release builds, where this line is not.',
          ]);
        }
      },
    );
  }
}

final class _Manager implements ModelFileManager {
  @override
  final activeEmbeddingModel = EmbeddingModelSpec(
    name: 'fixture',
    modelSource: ModelSource.network('https://models.test/eg2.gguf'),
  );
  @override
  Future<Map<String, String>?> getModelFilePaths(ModelSpec spec) async => {
    PreferencesKeys.embeddingModelFile: '/fixture/eg2.gguf',
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Provider extends EmbeddingBackendProvider {
  Set<PreferredBackend> capabilities = {
    PreferredBackend.cpu,
    PreferredBackend.gpu,
  };
  PreferredBackend? loaded;
  PreferredBackend? descriptorBackend;
  bool omitReport = false;
  Object? failure;
  int capabilityCalls = 0;
  final configs = <RuntimeConfig>[];
  @override
  String get name => 'placement fixture';
  @override
  bool canHandle(EmbeddingModelSpec spec) => true;
  @override
  Set<PreferredBackend> honouredBackends(EmbeddingModelSpec spec) {
    capabilityCalls++;
    if (failure != null) throw failure!;
    return capabilities;
  }

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    configs.add(config);
    return EmbeddingPassDescriptor<_Config>(
      engineTag: name,
      factory: _build,
      config: _Config(
        omitReport
            ? null
            : loaded ?? config.preferredBackend ?? PreferredBackend.gpu,
        config.supportImage,
      ),
      activeBackend: descriptorBackend,
    );
  }
}

final class _Config {
  const _Config(this.backend, this.image);
  final PreferredBackend? backend;
  final bool image;
}

EmbeddingPass _build(_Config config) => _Pass(config);

final class _Pass extends EmbeddingPass {
  _Pass(this.config);
  final _Config config;
  @override
  Future<EmbeddingPassInfo> load() async => EmbeddingPassInfo(
    dimension: 2,
    activeBackend: config.backend,
    modalities: {
      EmbeddingModality.text,
      if (config.image) EmbeddingModality.image,
    },
    imageFormats: {if (config.image) EncodedMediaFormat.png},
  );
  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async => [
    1,
    0,
  ];
  @override
  Future<void> close() async {}
}
