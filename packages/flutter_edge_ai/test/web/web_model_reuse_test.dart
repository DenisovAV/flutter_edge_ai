// The web shell keeps its model while the active model and the runtime knobs
// stay the same, and builds a new one when either changes.
//
// It used to close and rebuild on every getActiveModel: its spec was a
// synthetic 'web-active', so a reuse check could not have seen the active
// model change. End-to-end through the real FlutterEdgeAi facade; only the
// engine is faked.
//
// FlutterEdgeAiWeb pulls in dart:js_interop, so this runs in a browser and
// `tool/test_all.sh` (VM only) does not pick it up:
//   flutter test test/web/web_model_reuse_test.dart --platform chrome
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/web/flutter_edge_ai_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

InferenceModelSpec _spec(String name, {String host = 'x', String? lora}) =>
    InferenceModelSpec(
      name: name,
      modelSource: ModelSource.network('https://$host/$name.litertlm'),
      loraSource: lora == null ? null : ModelSource.network('https://x/$lora'),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingEngine engine;

  Future<void> activate(String name, {String host = 'x', String? lora}) async {
    final manager =
        FlutterEdgeAiPlugin.instance.modelManager as WebModelManager;
    await manager.ensureInitialized();
    await manager.activateInstalledModel(_spec(name, host: host, lora: lora));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
    engine = _CountingEngine();
    EngineRegistry.instance
      ..reset()
      ..registerAll([engine]);
    await activate('model-a');
  });

  tearDown(() async {
    await FlutterEdgeAiPlugin.instance.initializedModel?.close();
    EngineRegistry.instance.reset();
    ServiceRegistry.reset();
  });

  test('the same model and knobs are reused, not loaded again', () async {
    final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final second = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);

    expect(engine.builds, 1);
    expect(second, same(first));
    expect((first as _FakeModel).isClosed, isFalse);
  });

  test('other knobs build a new model and close the old one', () async {
    final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final second = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);

    expect(engine.builds, 2);
    expect(second, isNot(same(first)));
    expect((first as _FakeModel).isClosed, isTrue);
  });

  test(
    'another active model builds a new model, even with the same knobs',
    () async {
      final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      await activate('model-b');
      final second = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);

      expect(engine.builds, 2);
      expect(engine.specNames, ['model-a', 'model-b']);
      expect(second, isNot(same(first)));
      expect((first as _FakeModel).isClosed, isTrue);
    },
  );

  test(
    'the same name from another source, or with LoRA, builds a new model',
    () async {
      final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      // Re-installed from another URL under the same file name.
      await activate('model-a', host: 'y');
      final second = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      await activate('model-a', host: 'y', lora: 'adapter.bin');
      final third = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);

      expect(engine.builds, 3);
      expect((first as _FakeModel).isClosed, isTrue);
      expect((second as _FakeModel).isClosed, isTrue);
      expect(third, isNot(same(second)));
    },
  );

  test(
    'a call while the cached model is closing waits, then builds a new one',
    () async {
      final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      final gate = (first as _FakeModel).closeGate = Completer<void>();
      final closing = first.close();

      final pending = FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      await pumpEventQueue();
      expect(engine.builds, 1, reason: 'nothing is built while it closes');

      gate.complete();
      final second = await pending;
      await closing;
      expect(engine.builds, 2);
      expect(second, isNot(same(first)));
      expect((second as _FakeModel).isClosed, isFalse);
      expect(FlutterEdgeAiPlugin.instance.initializedModel, same(second));
    },
  );

  test('a caller racing a build for other knobs gets its own model', () async {
    final results = await Future.wait([
      FlutterEdgeAi.getActiveModel(maxTokens: 1024),
      FlutterEdgeAi.getActiveModel(maxTokens: 2048),
    ]);

    expect(engine.builds, 2);
    expect((results[0] as _FakeModel).config.maxTokens, 1024);
    expect((results[1] as _FakeModel).config.maxTokens, 2048);
  });

  test('a model closed by its owner is built again on the next call', () async {
    final first = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    await first.close();
    final second = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);

    expect(engine.builds, 2);
    expect(second, isNot(same(first)));
  });
}

class _CountingEngine implements InferenceEngineProvider {
  int builds = 0;
  final specNames = <String>[];

  @override
  String get name => 'Counting';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    builds++;
    specNames.add(spec.name);
    // A real engine takes time to load; the race test needs the build to be
    // in flight when the second caller arrives.
    await Future<void>.delayed(Duration.zero);
    return _FakeModel(config);
  }
}

class _FakeModel with CloseNotifier implements InferenceModel {
  _FakeModel(this.config);

  final RuntimeConfig config;
  bool isClosed = false;

  /// Fires the close listeners after an asynchronous gap, as every real model
  /// does.
  /// When set, the teardown waits for it, so a test can hold the model in
  /// the closing state for as long as it needs.
  Completer<void>? closeGate;

  Future<void>? _closing;

  /// Every caller gets the one teardown, as the real models' `close()` does.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    isClosed = true;
    await Future<void>.delayed(Duration.zero);
    await closeGate?.future;
    fireCloseListeners();
  }

  // The shell only calls close() and addCloseListener() on the model it
  // caches; anything else should fail loudly.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
