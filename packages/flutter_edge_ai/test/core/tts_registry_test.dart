import 'package:flutter_edge_ai/core/registry/tts_registry.dart';
import 'package:flutter_edge_ai/core/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _P implements TtsBackendProvider {
  _P(this._n, this._pri);
  final String _n;
  final int _pri;
  @override
  String get name => _n;
  @override
  int get priority => _pri;
  @override
  bool canHandle(TtsModelSpec spec) => true;
  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec s,
    RuntimeConfig c,
  ) async => throw UnimplementedError();
}

TtsModelSpec _spec() => TtsModelSpec.fromManifest(
  name: 'm',
  ttsModelType: TtsModelType.matcha,
  sourceFor: (fn) => ModelSource.network('https://x/$fn'),
);

void main() {
  setUp(() => TtsRegistry.instance.reset());

  test('registry picks highest priority', () {
    TtsRegistry.instance.registerAll([_P('low', 0), _P('high', 10)]);
    expect(TtsRegistry.instance.findFor(_spec())!.name, 'high');
  });

  test('findFor returns null when empty; hasAny false', () {
    expect(TtsRegistry.instance.findFor(_spec()), isNull);
    expect(TtsRegistry.instance.hasAny, isFalse);
  });

  test('registerAll dedups + hasAny true after register', () {
    final p = _P('x', 0);
    TtsRegistry.instance.registerAll([p, p]);
    expect(TtsRegistry.instance.registered.length, 1);
    expect(TtsRegistry.instance.hasAny, isTrue);
  });
}
