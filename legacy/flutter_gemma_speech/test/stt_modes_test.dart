import 'package:flutter_gemma_speech/src/model/stt_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('moonshine profile declares batch-only modes', () {
    const p = SttModelProfile.moonshine();
    expect(p.modes, {SttMode.batch});
    expect(p.supportsStreaming, isFalse);
  });

  test('SttMode has exactly batch and streaming', () {
    expect(SttMode.values, [SttMode.batch, SttMode.streaming]);
  });
}
