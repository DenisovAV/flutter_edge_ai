import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/models/model_catalog.dart';
import 'package:motormind/services/advisor_model_service.dart';
import 'package:motormind/services/token_store.dart';

/// Scripted SDK stand-in: no native code, no network.
class FakeGateway implements EdgeAiGateway {
  final installed = <String>{};
  final loaded = <String>[];
  String? lastToken;
  Object? installError;
  int progressSteps = 3;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isInstalled(AdvisorModelSpec spec) async => installed.contains(spec.id);

  @override
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  }) async {
    lastToken = token;
    for (var i = 1; i <= progressSteps; i++) {
      await Future<void>.delayed(Duration.zero);
      onProgress((100 * i / progressSteps).round());
    }
    if (installError != null) throw installError!;
    installed.add(spec.id);
  }

  @override
  Future<void> uninstall(AdvisorModelSpec spec) async => installed.remove(spec.id);

  @override
  Future<InferenceModel> load(AdvisorModelSpec spec, {String? token}) async {
    loaded.add(spec.id);
    return _FakeModel();
  }
}

class _FakeModel implements InferenceModel {
  bool closed = false;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  late FakeGateway gateway;
  late MemoryTokenStore tokens;
  late ProviderContainer container;

  setUp(() {
    gateway = FakeGateway();
    tokens = MemoryTokenStore();
    container = ProviderContainer(
      overrides: [
        edgeAiGatewayProvider.overrideWithValue(gateway),
        tokenStoreProvider.overrideWithValue(tokens),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<ModelsState> ready() => container.read(advisorModelServiceProvider.future);

  test('reports installed models from the gateway on build', () async {
    gateway.installed.add(ModelCatalog.qwen3Small.id);
    final state = await ready();
    expect(state.statusOf(ModelCatalog.qwen3Small), isA<ModelInstalled>());
    expect(state.statusOf(ModelCatalog.gemma4E2B), isA<ModelNotInstalled>());
    expect(state.activeId, isNull);
  });

  test('download walks through progress to Installed and passes the stored token', () async {
    await ready();
    await tokens.write('hf_test');
    final seen = <int>[];
    container.listen(advisorModelServiceProvider, (prev, next) {
      final s = next.value?.statusOf(ModelCatalog.gemma4E2B);
      if (s is ModelDownloading) seen.add(s.percent);
    });
    await container.read(advisorModelServiceProvider.notifier).download(ModelCatalog.gemma4E2B);
    expect(seen, [0, 33, 67, 100]);
    expect(
      container.read(advisorModelServiceProvider).value!.statusOf(ModelCatalog.gemma4E2B),
      isA<ModelInstalled>(),
    );
    expect(gateway.lastToken, 'hf_test');
  });

  test('no token stored means no token sent', () async {
    await ready();
    await container.read(advisorModelServiceProvider.notifier).download(ModelCatalog.qwen3Small);
    expect(gateway.lastToken, isNull);
  });

  test('a forbidden download asks for a token; any other failure does not', () async {
    await ready();
    final n = container.read(advisorModelServiceProvider.notifier);
    gateway.installError = const DownloadException(ForbiddenError());
    await n.download(ModelCatalog.gemma4E2B);
    var status = container
        .read(advisorModelServiceProvider)
        .value!
        .statusOf(ModelCatalog.gemma4E2B);
    expect(status, isA<ModelFailed>());
    expect((status as ModelFailed).needsToken, isTrue);

    // A plain exception is a generic failure with a sentence for the person,
    // never the engine's own text.
    gateway.installError = Exception('disk full');
    await n.download(ModelCatalog.gemma4E2B);
    status = container.read(advisorModelServiceProvider).value!.statusOf(ModelCatalog.gemma4E2B);
    expect((status as ModelFailed).needsToken, isFalse);
    expect(status.message, isNot(contains('disk full')));
  });

  test('activating a model that is not installed fails with a sentence', () async {
    await ready();
    final n = container.read(advisorModelServiceProvider.notifier);
    await n.activate(ModelCatalog.gemma4E2B);
    final status = container
        .read(advisorModelServiceProvider)
        .value!
        .statusOf(ModelCatalog.gemma4E2B);
    expect(status, isA<ModelFailed>());
    expect(gateway.loaded, isEmpty);
  });

  test('the context window shrinks with free memory and never grows past the catalog', () {
    expect(windowForFreeMemory(8.0, ceiling: 8192), 8192);
    expect(windowForFreeMemory(5.0, ceiling: 8192), 4096);
    expect(windowForFreeMemory(2.5, ceiling: 8192), 2048);
    expect(windowForFreeMemory(2.5, ceiling: 1024), 1024);
  });

  test(
    'activate loads the model, switching closes the previous one, remove clears active',
    () async {
      gateway.installed.addAll([ModelCatalog.qwen3Small.id, ModelCatalog.gemma4E2B.id]);
      await ready();
      final n = container.read(advisorModelServiceProvider.notifier);

      await n.activate(ModelCatalog.qwen3Small);
      var state = container.read(advisorModelServiceProvider).value!;
      expect(state.activeId, ModelCatalog.qwen3Small.id);
      expect(state.statusOf(ModelCatalog.qwen3Small), isA<ModelReady>());
      final first = n.loadedModel as _FakeModel;

      await n.activate(ModelCatalog.gemma4E2B);
      state = container.read(advisorModelServiceProvider).value!;
      expect(first.closed, isTrue);
      expect(state.activeId, ModelCatalog.gemma4E2B.id);
      expect(state.statusOf(ModelCatalog.qwen3Small), isA<ModelInstalled>());
      expect(gateway.loaded, [ModelCatalog.qwen3Small.id, ModelCatalog.gemma4E2B.id]);

      await n.remove(ModelCatalog.gemma4E2B);
      state = container.read(advisorModelServiceProvider).value!;
      expect(state.activeId, isNull);
      expect(state.statusOf(ModelCatalog.gemma4E2B), isA<ModelNotInstalled>());
      expect(n.loadedModel, isNull);
    },
  );

  test('catalog entries are public litert-community bundles and the default is Gemma 4 E2B', () {
    expect(ModelCatalog.defaultModel, ModelCatalog.gemma4E2B);
    for (final m in ModelCatalog.all) {
      expect(m.url, startsWith('https://huggingface.co/litert-community/'));
      expect(m.needsToken, isFalse);
      expect(m.supportsTools, isTrue);
    }
  });
}
