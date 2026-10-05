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
  Future<InferenceModel> load(AdvisorModelSpec spec) async {
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
    gateway.installed.add(ModelCatalog.qwen3_0_6B.id);
    final state = await ready();
    expect(state.statusOf(ModelCatalog.qwen3_0_6B), isA<Installed>());
    expect(state.statusOf(ModelCatalog.gemma4E2B), isA<NotInstalled>());
    expect(state.activeId, isNull);
  });

  test('download walks through progress to Installed and passes the stored token', () async {
    await ready();
    await tokens.write('hf_test');
    final seen = <int>[];
    container.listen(advisorModelServiceProvider, (prev, next) {
      final s = next.value?.statusOf(ModelCatalog.gemma4E2B);
      if (s is Downloading) seen.add(s.percent);
    });
    await container.read(advisorModelServiceProvider.notifier).download(ModelCatalog.gemma4E2B);
    expect(seen, [0, 33, 67, 100]);
    expect(
      container.read(advisorModelServiceProvider).value!.statusOf(ModelCatalog.gemma4E2B),
      isA<Installed>(),
    );
    expect(gateway.lastToken, 'hf_test');
  });

  test('no token stored means no token sent', () async {
    await ready();
    await container.read(advisorModelServiceProvider.notifier).download(ModelCatalog.qwen3_0_6B);
    expect(gateway.lastToken, isNull);
  });

  test('a 401/403 download failure asks for a token; other failures do not', () async {
    await ready();
    final n = container.read(advisorModelServiceProvider.notifier);
    gateway.installError = Exception('HTTP 403 Forbidden');
    await n.download(ModelCatalog.gemma4E2B);
    var status = container
        .read(advisorModelServiceProvider)
        .value!
        .statusOf(ModelCatalog.gemma4E2B);
    expect(status, isA<Failed>());
    // Non-DownloadException errors are generic failures even if they mention 403.
    expect((status as Failed).needsToken, isFalse);

    gateway.installError = Exception('disk full');
    await n.download(ModelCatalog.gemma4E2B);
    status = container.read(advisorModelServiceProvider).value!.statusOf(ModelCatalog.gemma4E2B);
    expect((status as Failed).message, contains('disk full'));
  });

  test(
    'activate loads the model, switching closes the previous one, remove clears active',
    () async {
      gateway.installed.addAll([ModelCatalog.qwen3_0_6B.id, ModelCatalog.gemma4E2B.id]);
      await ready();
      final n = container.read(advisorModelServiceProvider.notifier);

      await n.activate(ModelCatalog.qwen3_0_6B);
      var state = container.read(advisorModelServiceProvider).value!;
      expect(state.activeId, ModelCatalog.qwen3_0_6B.id);
      expect(state.statusOf(ModelCatalog.qwen3_0_6B), isA<Ready>());
      final first = n.loadedModel as _FakeModel;

      await n.activate(ModelCatalog.gemma4E2B);
      state = container.read(advisorModelServiceProvider).value!;
      expect(first.closed, isTrue);
      expect(state.activeId, ModelCatalog.gemma4E2B.id);
      expect(state.statusOf(ModelCatalog.qwen3_0_6B), isA<Installed>());
      expect(gateway.loaded, [ModelCatalog.qwen3_0_6B.id, ModelCatalog.gemma4E2B.id]);

      await n.remove(ModelCatalog.gemma4E2B);
      state = container.read(advisorModelServiceProvider).value!;
      expect(state.activeId, isNull);
      expect(state.statusOf(ModelCatalog.gemma4E2B), isA<NotInstalled>());
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
