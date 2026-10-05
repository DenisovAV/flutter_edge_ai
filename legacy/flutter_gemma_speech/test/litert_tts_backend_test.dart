import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma_speech/src/litert_tts_backend.dart';
import 'package:flutter_test/flutter_test.dart';

TtsModelSpec _spec() => TtsModelSpec.fromManifest(
  name: 'matcha',
  ttsModelType: TtsModelType.matcha,
  sourceFor: (fn) => ModelSource.network('https://x/$fn'),
);

void main() {
  const backend = LiteRtTtsBackend();

  test('canHandle is true (sole backend)', () {
    expect(backend.canHandle(_spec()), isTrue);
    expect(backend.name, isNotEmpty);
  });

  test('createModel throws StateError without artifactPaths', () {
    expect(
      backend.createModel(
        _spec(),
        const RuntimeConfig(maxTokens: 0, modelPath: ''),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
