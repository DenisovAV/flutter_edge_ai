// ignore_for_file: avoid_print

// Integration test: generation scenarios through Genkit API.
// Run: flutter test integration_test/generation_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  late Genkit ai;

  testWidgets('Generation: setUpAll — install model', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();
    ai = createTestGenkit();
  }, timeout: const Timeout(kInstallTimeout));

  testWidgets('Generation: blocking response', (tester) async {
    final response = await ai.generate(
      model: testModelRef,
      prompt: 'What is 2+2? Answer briefly.',
      config: FlutterGemmaModelOptions(maxTokens: 256),
    );

    final text = response.text;
    print('[Blocking] Response: "${text.length > 200 ? text.substring(0, 200) : text}"');
    expect(text, isNotEmpty, reason: 'Blocking response should be non-empty');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Generation: streaming response', (tester) async {
    final chunks = <String>[];

    final stream = ai.generateStream(
      model: testModelRef,
      prompt: 'Say hello in a few words.',
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );

    await for (final chunk in stream) {
      final text = chunk.text;
      if (text.isNotEmpty) {
        chunks.add(text);
        if (chunks.length <= 5) {
          print('[Stream] Chunk ${chunks.length}: "$text"');
        }
      }
    }

    final result = stream.result;
    final fullText = result.text;
    print(
        '[Stream] Full (${chunks.length} chunks): "${fullText.length > 200 ? fullText.substring(0, 200) : fullText}"');
    expect(chunks, isNotEmpty, reason: 'Should receive at least 1 chunk');
    expect(fullText, isNotEmpty, reason: 'Assembled streaming text should be non-empty');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Generation: multi-turn conversation', (tester) async {
    final response = await ai.generate(
      model: testModelRef,
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: 'My name is Alice.')],
        ),
        Message(
          role: Role.model,
          content: [TextPart(text: 'Hello Alice! How can I help you?')],
        ),
        Message(
          role: Role.user,
          content: [TextPart(text: 'What is my name?')],
        ),
      ],
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );

    final text = response.text;
    print('[Multi-turn] Response: "$text"');
    expect(text, isNotEmpty, reason: 'Multi-turn response should be non-empty');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Generation: system role message', (tester) async {
    final response = await ai.generate(
      model: testModelRef,
      messages: [
        Message(
          role: Role.system,
          content: [TextPart(text: 'You are a helpful assistant. Be brief.')],
        ),
        Message(
          role: Role.user,
          content: [TextPart(text: 'What color is the sky?')],
        ),
      ],
      config: FlutterGemmaModelOptions(maxTokens: 128),
    );

    final text = response.text;
    print('[System] Response: "$text"');
    expect(text, isNotEmpty,
        reason: 'Response with system message should be non-empty');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Generation: custom config (short output)', (tester) async {
    final response = await ai.generate(
      model: testModelRef,
      prompt: 'Write a long story about a dragon.',
      config: FlutterGemmaModelOptions(
        maxTokens: 50,
        temperature: 0.1,
      ),
    );

    final text = response.text;
    print('[CustomConfig] Response (${text.length} chars): "$text"');
    expect(text, isNotEmpty, reason: 'Custom config response should be non-empty');
    // With maxTokens=50, response should be relatively short
    // (not asserting exact length — model behavior varies).
  }, timeout: const Timeout(kInferenceTimeout));
}
