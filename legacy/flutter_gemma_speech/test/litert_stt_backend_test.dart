import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LiteRtSttBackend identity', () {
    const b = LiteRtSttBackend();
    expect(b.name, 'LiteRT STT');
    expect(b.priority, 0);
  });

  test(
    'LiteRtSttBackend.canHandle is unconditionally true (sole STT backend)',
    () {
      const b = LiteRtSttBackend();
      for (final type in SttModelType.values) {
        final spec = SttModelSpec(
          name: 'test-$type',
          modelSource: NetworkSource('https://example.com/model.tflite'),
          tokenizerSource: NetworkSource('https://example.com/tokenizer.json'),
          sttModelType: type,
        );
        expect(b.canHandle(spec), isTrue, reason: 'must handle $type');
      }
    },
  );

  // The "unimplemented families throw, naming the type" regression test
  // that used to live here was removed: as of this commit all 3
  // SttModelType values (moonshine, whisper, parakeet) resolve to a real
  // SttModelProfile, so there is no remaining "still unimplemented" family
  // to iterate over. Backend genericity (spec.sttModelType selects the
  // profile, never hardcoded) is now proven structurally by
  // stt_model_profile_test.dart's forType coverage of all 3 types, and
  // end-to-end on-device by the 3 device gates (stt_moonshine_test.dart,
  // whisper_tiny_test.dart, parakeet_ctc_test.dart).

  test('createModel requires config.tokenizerPath', () async {
    const b = LiteRtSttBackend();
    final spec = SttModelSpec(
      name: 'test',
      modelSource: NetworkSource('https://example.com/model.tflite'),
      tokenizerSource: NetworkSource('https://example.com/tokenizer.json'),
      sttModelType: SttModelType.moonshine,
    );
    const config = RuntimeConfig(maxTokens: 0, modelPath: '/tmp/model.tflite');

    await expectLater(
      () => b.createModel(spec, config),
      throwsA(isA<StateError>()),
    );
  });
}
