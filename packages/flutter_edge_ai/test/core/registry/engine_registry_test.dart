import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show InferenceModel;
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show InferenceModelSpec;

class _FakeEngine implements InferenceEngineProvider {
  _FakeEngine(this.name, this._canHandle, {this.priority = 0});
  @override
  final String name;
  @override
  final int priority;
  final bool Function(InferenceModelSpec) _canHandle;
  @override
  bool canHandle(InferenceModelSpec spec) => _canHandle(spec);
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

InferenceModelSpec _spec(ModelFileType ft) => InferenceModelSpec(
  name: 'test',
  modelSource: AssetSource('models/test.bin'),
  modelType: ModelType.general,
  fileType: ft,
);

void main() {
  setUp(() => EngineRegistry.instance.reset());

  test('findFor returns the first engine whose canHandle is true', () {
    final mp = _FakeEngine(
      'MediaPipe',
      (s) => s.fileType == ModelFileType.task,
    );
    final lr = _FakeEngine(
      'LiteRT-LM',
      (s) => s.fileType == ModelFileType.litertlm,
    );
    EngineRegistry.instance.registerAll([mp, lr]);
    expect(
      EngineRegistry.instance.findFor(_spec(ModelFileType.task)),
      same(mp),
    );
    expect(
      EngineRegistry.instance.findFor(_spec(ModelFileType.litertlm)),
      same(lr),
    );
  });

  test('findFor returns null when no engine can handle the spec', () {
    EngineRegistry.instance.registerAll([
      _FakeEngine('MediaPipe', (s) => s.fileType == ModelFileType.task),
    ]);
    expect(
      EngineRegistry.instance.findFor(_spec(ModelFileType.litertlm)),
      isNull,
    );
  });

  test('higher priority wins when two engines both canHandle', () {
    final core = _FakeEngine('Core', (_) => true, priority: 0);
    final third = _FakeEngine('ThirdParty', (_) => true, priority: 10);
    EngineRegistry.instance.registerAll([core, third]);
    expect(
      EngineRegistry.instance.findFor(_spec(ModelFileType.task)),
      same(third),
    );
  });

  test('equal priority -> first registered wins', () {
    final a = _FakeEngine('A', (_) => true);
    final b = _FakeEngine('B', (_) => true);
    EngineRegistry.instance.registerAll([a, b]);
    expect(EngineRegistry.instance.findFor(_spec(ModelFileType.task)), same(a));
  });

  test('registered exposes all engines in registration order', () {
    final a = _FakeEngine('A', (_) => false);
    final b = _FakeEngine('B', (_) => false);
    EngineRegistry.instance.registerAll([a, b]);
    expect(EngineRegistry.instance.registered.map((e) => e.name), ['A', 'B']);
  });

  test('explicitly registered engine is used by findFor (initialize path)', () {
    final custom = _FakeEngine(
      'Custom',
      (s) => s.fileType == ModelFileType.task,
    );
    EngineRegistry.instance.registerAll([custom]);
    expect(EngineRegistry.instance.registered.single, same(custom));
    expect(
      EngineRegistry.instance.findFor(_spec(ModelFileType.task)),
      same(custom),
    );
  });
}
