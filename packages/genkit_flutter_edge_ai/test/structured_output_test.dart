import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

import 'src/fake_runtime.dart';

/// Structured output on a model with no native constrained decoding: Genkit
/// asks for constrained output whenever an output schema is given, and the
/// plugin answers by writing the schema into the prompt, as genkit's
/// `simulateConstrainedGeneration()` middleware does. With the middleware the
/// schema is written once, by the middleware.
void main() {
  late FakeInferenceChat fakeChat;
  late Genkit ai;

  setUp(() {
    fakeChat = FakeInferenceChat()
      ..blockingResponse = const gemma.TextResponse(
        '{"preferredBackend": "gpu"}',
      );
    final fakeModel = FakeInferenceModel()..chatToReturn = fakeChat;
    ai = Genkit(
      plugins: [
        GenkitFlutterEdgeAiPlugin(
          models: [
            FlutterEdgeAiModelConfig(
              name: 'm',
              modelType: gemma.ModelType.gemmaIt,
            ),
          ],
          runtime: FakeRuntime(model: fakeModel),
        ),
      ],
    );
  });

  String prompt() => fakeChat.receivedMessages.map((m) => m.text).join('\n');

  test('simulateConstrainedGeneration puts the schema in the prompt', () async {
    final response = await ai.generate(
      model: flutterEdgeAi.model('m'),
      prompt: 'Pick a backend.',
      outputSchema: FlutterEdgeAiEmbedConfig.$schema,
      use: [simulateConstrainedGeneration()],
    );

    expect(prompt(), contains('conform to the following schema'));
    expect(prompt(), contains('preferredBackend'));
    expect(response.output?.preferredBackend, 'gpu');
  });

  test('without it the plugin writes the schema into the prompt', () async {
    final response = await ai.generate(
      model: flutterEdgeAi.model('m'),
      prompt: 'Pick a backend.',
      outputSchema: FlutterEdgeAiEmbedConfig.$schema,
    );

    // A failed generation leaves the prompt empty.
    expect(response.finishReason, FinishReason.stop);
    expect(prompt(), contains('Pick a backend.'));
    expect(prompt(), contains('conform to the following schema'));
    expect(response.output?.preferredBackend, 'gpu');
  });

  test('with the middleware the schema is written once', () async {
    await ai.generate(
      model: flutterEdgeAi.model('m'),
      prompt: 'Pick a backend.',
      outputSchema: FlutterEdgeAiEmbedConfig.$schema,
      use: [simulateConstrainedGeneration()],
    );

    expect(
      'conform to the following schema'.allMatches(prompt()),
      hasLength(1),
    );
  });

  test('constrained: false leaves the prompt alone', () async {
    final response = await ai.generate(
      model: flutterEdgeAi.model('m'),
      prompt: 'Pick a backend.',
      outputSchema: FlutterEdgeAiEmbedConfig.$schema,
      outputConstrained: false,
    );

    expect(response.finishReason, FinishReason.stop);
    expect(prompt(), isNot(contains('conform to the following schema')));
  });
}
