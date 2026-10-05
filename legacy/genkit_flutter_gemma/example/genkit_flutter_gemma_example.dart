// ignore_for_file: avoid_print

/// Example showing how to use genkit_flutter_gemma plugin.
///
/// **Prerequisites**: The host Flutter app must:
/// 1. Call `FlutterGemma.initialize()` at startup
/// 2. Install a model via `FlutterGemma.installModel()`
/// 3. Only then create the Genkit instance with this plugin
library;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

Future<void> main() async {
  // 1. Initialize flutter_gemma (done once in the app).
  await FlutterGemma.initialize();

  // 2. Install a model (if not already installed).
  final isInstalled = await FlutterGemma.isModelInstalled('gemma-3-nano');
  if (!isInstalled) {
    await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
        .fromAsset('assets/gemma-3-1b-it-int4.task')
        .install();
  }

  // 3. Create Genkit with flutter_gemma plugin.
  final ai = Genkit(plugins: [
    GenkitFlutterGemmaPlugin(models: [
      FlutterGemmaModelConfig(
        name: 'gemma-3-nano',
        modelType: ModelType.gemmaIt,
      ),
    ]),
  ]);

  // 4. Generate a response.
  final response = await ai.generate(
    model: flutterGemma.model('gemma-3-nano'),
    prompt: 'Tell me a short joke about programming.',
  );
  print('Response: ${response.text}');

  // 5. Streaming example.
  final stream = ai.generateStream(
    model: flutterGemma.model('gemma-3-nano'),
    prompt: 'Write a haiku about Dart programming.',
  );

  await for (final chunk in stream) {
    print(chunk.text);
  }

  // 6. With custom options.
  final creativeResponse = await ai.generate(
    model: flutterGemma.model('gemma-3-nano'),
    prompt: 'Invent a new programming language.',
    config: FlutterGemmaModelOptions(
      maxTokens: 2048,
      temperature: 1.2,
      topK: 40,
    ),
  );
  print('Creative: ${creativeResponse.text}');
}
