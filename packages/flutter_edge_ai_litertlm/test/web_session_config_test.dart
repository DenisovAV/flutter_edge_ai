// The SessionConfig web `.litertlm` sends, checked on the VM: the web model
// itself needs a browser and a model, and a sampler sent without its `type`
// is dropped by the engine without an error (#572).
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web_session_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampling = ResolvedSampling(
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    randomSeed: 7,
  );

  test('the sampler goes as TOP_P with every resolved value', () {
    expect(webSessionConfig(sampling)['samplerParams'], {
      'type': 2,
      'temperature': 1.0,
      'k': 64,
      'p': 0.95,
      'seed': 7,
    });
  });

  test('maxOutputTokens is sent only when set', () {
    expect(webSessionConfig(sampling).containsKey('maxOutputTokens'), isFalse);
    expect(
      webSessionConfig(sampling, maxOutputTokens: 128)['maxOutputTokens'],
      128,
    );
  });
}
