// ignore_for_file: avoid_print

// Integration test: basic smoke test for genkit_flutter_gemma.
// Run: flutter test integration_test/smoke_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  testWidgets('Smoke: generate via Genkit API', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();

    final ai = createTestGenkit();

    final response = await ai.generate(
      model: testModelRef,
      prompt: 'Say hello in one sentence.',
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );

    final text = response.text;
    print('[Smoke] Response: "${text.length > 200 ? text.substring(0, 200) : text}"');
    expect(text, isNotEmpty, reason: 'Smoke test response should be non-empty');
  }, timeout: const Timeout(kInferenceTimeout));
}
