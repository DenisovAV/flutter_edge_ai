// ignore_for_file: avoid_print

// Integration test: model lifecycle and caching through Genkit API.
// Run: flutter test integration_test/caching_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  late Genkit ai;

  testWidgets('Caching: setUpAll — install model', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();
    ai = createTestGenkit();
  }, timeout: const Timeout(kInstallTimeout));

  testWidgets('Caching: model reuse — same config twice', (tester) async {
    // First call: creates InferenceModel internally.
    final response1 = await ai.generate(
      model: testModelRef,
      prompt: 'Say one.',
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );
    expect(response1.text, isNotEmpty, reason: 'First call should succeed');
    print('[Reuse] Response 1: "${response1.text}"');

    // Second call: should reuse cached InferenceModel.
    final response2 = await ai.generate(
      model: testModelRef,
      prompt: 'Say two.',
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );
    expect(response2.text, isNotEmpty, reason: 'Second call should succeed');
    print('[Reuse] Response 2: "${response2.text}"');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Caching: model recreation — different maxTokens',
      (tester) async {
    // First call with large maxTokens.
    final response1 = await ai.generate(
      model: testModelRef,
      prompt: 'Say hello.',
      config: FlutterGemmaModelOptions(maxTokens: 1024),
    );
    expect(response1.text, isNotEmpty,
        reason: 'Call with maxTokens=1024 should succeed');
    print('[Recreation] Response 1 (1024): "${response1.text}"');

    // Second call with smaller maxTokens — forces model recreation.
    final response2 = await ai.generate(
      model: testModelRef,
      prompt: 'Say goodbye.',
      config: FlutterGemmaModelOptions(maxTokens: 512),
    );
    expect(response2.text, isNotEmpty,
        reason: 'Call with maxTokens=512 should succeed after recreation');
    print('[Recreation] Response 2 (512): "${response2.text}"');
  }, timeout: const Timeout(kInferenceTimeout));
}
