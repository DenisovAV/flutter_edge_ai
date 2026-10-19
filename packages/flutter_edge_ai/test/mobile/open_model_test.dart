// FlutterEdgeAi.openModel: caller-owned models next to the cached active one.
//
// End-to-end against the real facade and both native shells; only the engine
// is faked (the fixture pattern of concurrent_get_active_model_test.dart).
//
// Run: flutter test test/mobile/open_model_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/src/registry/multi_model_engine.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';

final _fakeBundleBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_open_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_open_support_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
  });

  tearDown(() async {
    // The shells are singletons whose cache outlives a test; closing the
    // cached model clears it (see concurrent_get_active_model_test.dart).
    await FlutterEdgeAiPlugin.instance.initializedModel?.close();
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  for (final (label, shell) in <(String, FlutterEdgeAiPlugin Function())>[
    ('mobile', FlutterEdgeAiMobile.new),
    ('desktop', () => FlutterEdgeAiDesktop.instance),
  ]) {
    /// Installs `model.bin` as the active model with [engine] registered, and
    /// returns its spec.
    Future<InferenceModelSpec> useShell(InferenceEngineProvider engine) async {
      final previous = FlutterEdgeAiPlugin.instance;
      FlutterEdgeAiPlugin.instance = shell();
      addTearDown(() => FlutterEdgeAiPlugin.instance = previous);
      await ServiceRegistry.initialize(
        downloadService: _FixtureDownloadService(_fakeBundleBytes),
      );
      EngineRegistry.instance.registerAll([engine]);
      // As FlutterEdgeAi.initialize does at startup: the manager restores the
      // persisted active model first, not in the middle of a test.
      await FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
      final installation = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
      ).fromNetwork('https://example.com/model.bin').install();
      return installation.spec;
    }

    test('$label: two openModel calls build two models, both open', () async {
      final engine = _MultiEngine();
      final spec = await useShell(engine);

      final cpu = await FlutterEdgeAi.openModel(
        spec,
        preferredBackend: PreferredBackend.cpu,
      );
      final gpu = await FlutterEdgeAi.openModel(
        spec,
        preferredBackend: PreferredBackend.gpu,
      );

      expect(engine.built, hasLength(2));
      expect(identical(cpu, gpu), isFalse);
      expect(engine.configs.map((c) => c.preferredBackend), [
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]);
      expect(engine.built.every((m) => !m.isClosed), isTrue);
      // Never the cached model.
      expect(FlutterEdgeAiPlugin.instance.initializedModel, isNull);

      await cpu.close();
      expect((gpu as _FakeInferenceModel).isClosed, isFalse);
      await gpu.close();
    });

    test('$label: openModel applies the getActiveModel defaults', () async {
      final engine = _MultiEngine();
      final spec = await useShell(engine);

      final model = await FlutterEdgeAi.openModel(
        spec,
        defaults: const ModelRuntimeDefaults(maxTokens: 4096),
      );

      final config = engine.configs.single;
      expect(config.maxTokens, 4096);
      expect(config.multimodalOrder, MultimodalOrder.imagesAudioText);
      expect(config.modelPath, endsWith('model.bin'));
      await model.close();
    });

    test('$label: a getActiveModel rebuild leaves opened models open, and '
        'closing an opened model leaves the active one cached', () async {
      final engine = _MultiEngine();
      final spec = await useShell(engine);

      final active = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      final opened = await FlutterEdgeAi.openModel(spec, maxTokens: 1024);

      // One parameter changed: the active model is rebuilt.
      final rebuilt = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
      expect(identical(rebuilt, active), isFalse);
      expect((active as _FakeInferenceModel).isClosed, isTrue);
      expect((opened as _FakeInferenceModel).isClosed, isFalse);

      await opened.close();
      expect(FlutterEdgeAiPlugin.instance.initializedModel, same(rebuilt));
      expect(
        await FlutterEdgeAi.getActiveModel(maxTokens: 2048),
        same(rebuilt),
      );
    });

    test('$label: an engine without MultiModelEngine is refused before it '
        'builds anything', () async {
      final engine = _SingleEngine();
      final spec = await useShell(engine);

      await expectLater(
        FlutterEdgeAi.openModel(spec),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Single'),
          ),
        ),
      );
      expect(engine.createModelCallCount, 0);

      // The active lane still works for it.
      final active = await FlutterEdgeAi.getActiveModel();
      expect(engine.createModelCallCount, 1);
      await active.close();
    });

    test('$label: install(activate: false) leaves the active model, and '
        'openModel runs the file it installed', () async {
      final engine = _MultiEngine();
      final activeSpec = await useShell(engine);

      final other = await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
      ).fromNetwork('https://example.com/other.bin').install(activate: false);

      expect(other.spec.name, isNot(activeSpec.name));
      expect(FlutterEdgeAi.activeModelSpec?.name, activeSpec.name);

      final model = await FlutterEdgeAi.openModel(other.spec);
      expect(engine.configs.single.modelPath, endsWith('other.bin'));
      await model.close();

      final active = await FlutterEdgeAi.getActiveModel();
      expect(engine.configs.last.modelPath, endsWith('model.bin'));
      await active.close();
    });

    test('$label: a spec that is not installed is refused', () async {
      final engine = _MultiEngine();
      await useShell(engine);
      final missing = InferenceModelSpec(
        name: 'missing',
        modelSource: ModelSource.network('https://example.com/missing.bin'),
        modelType: ModelType.gemmaIt,
      );

      await expectLater(
        FlutterEdgeAi.openModel(missing),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('missing is not installed'),
          ),
        ),
      );
      expect(engine.built, isEmpty);
    });

    test(
      '$label: openModel does not wait for the active model to close',
      () async {
        final engine = _MultiEngine();
        final spec = await useShell(engine);

        final active = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
        final gate = (active as _FakeInferenceModel).closeGate =
            Completer<void>();
        // The rebuild closes the active model and waits for that close.
        final rebuilding = FlutterEdgeAi.getActiveModel(maxTokens: 2048);
        await pumpEventQueue();
        expect(engine.built, hasLength(1));

        final opened = await FlutterEdgeAi.openModel(spec);
        expect(engine.built, hasLength(2));
        expect(gate.isCompleted, isFalse);

        gate.complete();
        final rebuilt = await rebuilding;
        expect(engine.built, hasLength(3));
        await opened.close();
        await rebuilt.close();
      },
    );

    test('$label: the deprecated createModel is the active lane', () async {
      final engine = _MultiEngine();
      await useShell(engine);

      final viaFacade = await FlutterEdgeAi.getActiveModel();
      // ignore: deprecated_member_use_from_same_package
      final viaPlugin = await FlutterEdgeAiPlugin.instance.createModel(
        modelType: ModelType.general,
      );
      expect(viaPlugin, same(viaFacade));
      expect(engine.built, hasLength(1));
    });
  }
}

class _MultiEngine implements InferenceEngineProvider, MultiModelEngine {
  final configs = <RuntimeConfig>[];
  final built = <_FakeInferenceModel>[];

  @override
  String get name => 'Multi';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    configs.add(config);
    final model = _FakeInferenceModel(config);
    built.add(model);
    return model;
  }
}

class _SingleEngine implements InferenceEngineProvider {
  int createModelCallCount = 0;

  @override
  String get name => 'Single';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    createModelCallCount++;
    return _FakeInferenceModel(config);
  }
}

class _FakeInferenceModel with CloseNotifier implements InferenceModel {
  _FakeInferenceModel(this.config);
  final RuntimeConfig config;

  bool isClosed = false;

  /// When set, the teardown waits for it, so a test can hold the model in
  /// the closing state.
  Completer<void>? closeGate;

  Future<void>? _closing;

  @override
  Future<void> close() => _closing ??= _close();

  // Fires the listeners after an asynchronous gap, as every real model does.
  Future<void> _close() async {
    isClosed = true;
    await Future<void>.delayed(Duration.zero);
    await closeGate?.future;
    fireCloseListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _FixtureDownloadService implements DownloadService {
  _FixtureDownloadService(this.bytes);
  final Uint8List bytes;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
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
    await File(targetPath).writeAsBytes(bytes);
    yield 100;
  }
}
