import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = ShellFixture();
  setUp(() async {
    await fixture.setUp();
    EmbeddingRegistry.instance.reset();
  });
  tearDown(() async {
    await fixture.tearDown();
    EmbeddingRegistry.instance.reset();
  });

  for (final shell in shells) {
    test('${shell.name}: CPU/GPU/auto keys survive caching', () async {
      final backend = _Backend();
      EmbeddingRegistry.instance.registerAll([backend]);
      final plugin = shell.create();
      await fixture.activate(plugin, model: 'eg2.gguf');
      final cpu = await plugin.createEmbeddingModel(
        preferredBackend: PreferredBackend.cpu,
      );
      expect(cpu.activeBackend, PreferredBackend.cpu);
      expect(
        await plugin.createEmbeddingModel(
          preferredBackend: PreferredBackend.cpu,
        ),
        same(cpu),
      );
      final gpu = await plugin.createEmbeddingModel(
        preferredBackend: PreferredBackend.gpu,
      );
      expect(cpu.isClosed, isTrue);
      expect(
        gpu.activeBackend,
        PreferredBackend.gpu,
        reason: 'the loaded answer overrides the descriptor',
      );
      expect(backend.requests, [PreferredBackend.cpu, PreferredBackend.gpu]);
      final auto = await plugin.createEmbeddingModel();
      expect(gpu.isClosed, isTrue);
      expect(auto.activeBackend, isNull, reason: 'unknown is not CPU');
      expect(await plugin.createEmbeddingModel(), same(auto));
      await expectLater(
        plugin.createEmbeddingModel(preferredBackend: PreferredBackend.npu),
        throwsA(isA<EmbeddingLoadException>()),
      );
      expect(
        auto.isClosed,
        isFalse,
        reason: 'refused request preserves cached model',
      );
      expect(await plugin.createEmbeddingModel(), same(auto));
      await auto.close();
    });
  }
}

final class _Backend extends EmbeddingBackendProvider {
  final requests = <PreferredBackend?>[];
  @override
  String get name => 'GPU capable';
  @override
  bool canHandle(EmbeddingModelSpec spec) => true;
  @override
  PreferredBackend? cacheBackend(PreferredBackend? requested) => requested;
  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    requests.add(config.preferredBackend);
    if (config.preferredBackend == PreferredBackend.npu) {
      throw const EmbeddingLoadException('No NPU', engine: 'test');
    }
    return EmbeddingPassDescriptor<BackendBox>(
      engineTag: 'test',
      factory: _build,
      config: BackendBox(config.preferredBackend),
      activeBackend: config.preferredBackend == null
          ? null
          : PreferredBackend.cpu,
    );
  }
}

final class BackendBox {
  const BackendBox(this.backend);
  final PreferredBackend? backend;
}

EmbeddingPass _build(BackendBox config) => _Pass(config.backend);

final class _Pass extends EmbeddingPass {
  _Pass(this.backend);
  final PreferredBackend? backend;
  @override
  Future<EmbeddingPassInfo> load() async =>
      EmbeddingPassInfo(dimension: 2, activeBackend: backend);
  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async => [
    1,
    0,
  ];
  @override
  Future<void> close() async {}
}
