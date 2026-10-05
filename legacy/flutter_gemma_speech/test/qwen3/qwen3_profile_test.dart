// Qwen3-TTS `TtsModelProfile` wiring (Task 5.1). `Qwen3TtsCore.load`
// hardcodes its own manifest basenames, so the sealed `Qwen3Profile` variant
// carries NO file-role fields at all (see `tts_model_profile.dart`) —
// [pipeline] is the only load-bearing field for this model family, so that's
// what this test asserts, alongside the text-representation/G2P declarations
// the frontend seam (`tts_text_frontend.dart`) and worker (Task 5.3) branch
// on.

import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelType;
import 'package:flutter_gemma_speech/src/model/tts_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forType(qwen3) gives the qwen3ArCodec pipeline + subword/no-G2P text '
      'representation', () {
    final p = TtsModelProfile.forType(TtsModelType.qwen3);
    expect(p, isA<Qwen3Profile>());
    expect(p.pipeline, TtsPipelineKind.qwen3ArCodec);
    expect(p.representation, TextRepresentation.subwordTokens);
    expect(p.g2p, isNull);
    expect(p.locale, 'en_us');
  });

  test('TtsModelProfile.qwen3() const constructor matches forType(qwen3)', () {
    const p = TtsModelProfile.qwen3();
    expect(p.pipeline, TtsPipelineKind.qwen3ArCodec);
    expect(p.representation, TextRepresentation.subwordTokens);
    expect(p.g2p, isNull);
  });

  test('forType(supertonic) still throws UnimplementedError (fail-loud)', () {
    expect(
      () => TtsModelProfile.forType(TtsModelType.supertonic),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('forType(kokoro) still throws UnimplementedError (fail-loud)', () {
    expect(
      () => TtsModelProfile.forType(TtsModelType.kokoro),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
