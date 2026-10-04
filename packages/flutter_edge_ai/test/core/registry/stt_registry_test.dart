import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/registry/stt_registry.dart';
import 'package:flutter_edge_ai/core/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show SpeechRecognizer;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show SttModelSpec, SttModelType;

class _FakeStt implements SttBackendProvider {
  _FakeStt(this.name, this._canHandle, {this.priority = 0});
  @override
  final String name;
  @override
  final int priority;
  final bool Function(SttModelSpec) _canHandle;
  @override
  bool canHandle(SttModelSpec spec) => _canHandle(spec);
  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

SttModelSpec _spec(SttModelType type) => SttModelSpec(
  name: 'test',
  modelSource: AssetSource('models/test.tflite'),
  tokenizerSource: AssetSource('models/tokenizer.json'),
  sttModelType: type,
);

void main() {
  setUp(() => SttRegistry.instance.reset());

  test('findFor returns the first backend whose canHandle is true', () {
    final moonshine = _FakeStt(
      'Moonshine',
      (s) => s.sttModelType == SttModelType.moonshine,
    );
    final whisper = _FakeStt(
      'Whisper',
      (s) => s.sttModelType == SttModelType.whisper,
    );
    SttRegistry.instance.registerAll([moonshine, whisper]);
    expect(
      SttRegistry.instance.findFor(_spec(SttModelType.moonshine)),
      same(moonshine),
    );
    expect(
      SttRegistry.instance.findFor(_spec(SttModelType.whisper)),
      same(whisper),
    );
  });

  test('findFor returns null when no backend can handle the spec', () {
    SttRegistry.instance.registerAll([
      _FakeStt('Moonshine', (s) => s.sttModelType == SttModelType.moonshine),
    ]);
    expect(SttRegistry.instance.findFor(_spec(SttModelType.parakeet)), isNull);
  });

  test('higher priority wins when two backends both canHandle', () {
    final core = _FakeStt('Core', (_) => true, priority: 0);
    final third = _FakeStt('ThirdParty', (_) => true, priority: 10);
    SttRegistry.instance.registerAll([core, third]);
    expect(
      SttRegistry.instance.findFor(_spec(SttModelType.moonshine)),
      same(third),
    );
  });

  test('equal priority -> first registered wins', () {
    final a = _FakeStt('A', (_) => true);
    final b = _FakeStt('B', (_) => true);
    SttRegistry.instance.registerAll([a, b]);
    expect(
      SttRegistry.instance.findFor(_spec(SttModelType.moonshine)),
      same(a),
    );
  });

  test('registered exposes all backends in registration order', () {
    final a = _FakeStt('A', (_) => false);
    final b = _FakeStt('B', (_) => false);
    SttRegistry.instance.registerAll([a, b]);
    expect(SttRegistry.instance.registered.map((e) => e.name), ['A', 'B']);
  });

  test(
    'explicitly registered backend is used by findFor (initialize path)',
    () {
      final custom = _FakeStt(
        'Custom',
        (s) => s.sttModelType == SttModelType.moonshine,
      );
      SttRegistry.instance.registerAll([custom]);
      expect(SttRegistry.instance.registered.single, same(custom));
      expect(
        SttRegistry.instance.findFor(_spec(SttModelType.moonshine)),
        same(custom),
      );
    },
  );
}
