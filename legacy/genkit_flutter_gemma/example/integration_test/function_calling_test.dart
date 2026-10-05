// ignore_for_file: avoid_print

// Integration test: function/tool calling through Genkit API.
// Run: flutter test integration_test/function_calling_test.dart -d <device>
//
// Note: FunctionGemma 270M IT supports function calling but results may be
// unstable with a model this small. Tests verify the pipeline doesn't crash
// and responses have valid structure.

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  late Genkit ai;
  late Tool<Map<String, dynamic>, String> weatherTool;

  testWidgets('FunctionCalling: setUpAll — install model', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();
    ai = createTestGenkit();

    weatherTool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'get_weather',
      description: 'Get current weather for a given city',
      fn: (input, _) async {
        final city = input['city'] as String? ?? 'unknown';
        return ToolResult.response('Weather in $city: 15C, cloudy');
      },
    );
  }, timeout: const Timeout(kInstallTimeout));

  testWidgets('FunctionCalling: generate with tool — no crash', (tester) async {
    // The model may or may not invoke the tool — we just verify:
    // 1. No crash
    // 2. Response is structurally valid
    // returnToolRequests: true prevents Genkit's auto tool-call loop,
    // which would exceed the small model's token limit when sending
    // tool results back.
    final response = await ai.generate(
      model: testModelRef,
      prompt: 'What is the weather in Moscow?',
      tools: [weatherTool],
      returnToolRequests: true,
      config: FlutterGemmaModelOptions(maxTokens: 512),
    );

    final text = response.text;
    print('[FunctionCalling] Response text: "$text"');

    // Lenient: model may return text OR trigger a tool call.
    // Either way, the response object should be valid.
    expect(response, isNotNull, reason: 'Response should not be null');
  }, timeout: const Timeout(kInferenceTimeout));
}
