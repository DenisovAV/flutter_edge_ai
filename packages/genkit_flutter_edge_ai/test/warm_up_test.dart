import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' hide Message, ModelResponse;
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

import 'src/fake_runtime.dart';

ModelRef<FlutterEdgeAiModelOptions> _ref(FlutterEdgeAiModelOptions? config) =>
    modelRef<FlutterEdgeAiModelOptions>(
      flutterEdgeAi.model('gemma').name,
      customOptions: FlutterEdgeAiModelOptions.$schema,
      config: config,
    );

void main() {
  group('flutterEdgeAi.warmUp', () {
    test('loads the active model with the target\'s config', () async {
      final runtime = FakeRuntime();
      await flutterEdgeAi.warmUp(
        _ref(
          FlutterEdgeAiModelOptions(maxTokens: 4096, preferredBackend: 'gpu'),
        ),
        runtime: runtime,
      );
      expect(runtime.getActiveModelCallCount, 1);
      expect(runtime.modelToReturn.maxTokens, 4096);
      expect(runtime.lastPreferredBackend, gemma.PreferredBackend.gpu);
    });

    test('loads with the parameters a request with that config uses', () async {
      final config = FlutterEdgeAiModelOptions(
        maxTokens: 2048,
        preferredBackend: 'cpu',
        enableSpeculativeDecoding: true,
      );
      final warm = FakeRuntime();
      await flutterEdgeAi.warmUp(_ref(config), runtime: warm);

      final served = FakeRuntime();
      final ai = Genkit(
        isDevEnv: false,
        promptDir: null,
        plugins: [
          GenkitFlutterEdgeAiPlugin(
            models: [
              FlutterEdgeAiModelConfig(
                name: 'gemma',
                modelType: gemma.ModelType.gemmaIt,
              ),
            ],
            runtime: served,
          ),
        ],
      );
      addTearDown(ai.shutdown);
      await ai.generate(model: _ref(config), prompt: 'hi');

      expect(warm.modelToReturn.maxTokens, served.modelToReturn.maxTokens);
      expect(warm.lastPreferredBackend, served.lastPreferredBackend);
      expect(
        warm.lastEnableSpeculativeDecoding,
        served.lastEnableSpeculativeDecoding,
      );
    });

    test('without a config it loads with the request defaults', () async {
      final runtime = FakeRuntime();
      await flutterEdgeAi.warmUp(_ref(null), runtime: runtime);
      expect(runtime.modelToReturn.maxTokens, 1024);
      expect(runtime.lastPreferredBackend, isNull);
    });

    test('an invalid config fails the warm-up as INVALID_ARGUMENT', () {
      expect(
        flutterEdgeAi.warmUp(
          _ref(FlutterEdgeAiModelOptions(maxTokens: 0)),
          runtime: FakeRuntime(),
        ),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCode.invalidArgument,
          ),
        ),
      );
    });

    test('a failed load fails the warm-up', () {
      final runtime = FakeRuntime()..loadError = StateError('no model');
      expect(
        flutterEdgeAi.warmUp(_ref(null), runtime: runtime),
        throwsA(isA<GenkitException>()),
      );
    });
  });
}
