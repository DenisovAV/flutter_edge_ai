// The deprecated genkit_hybrid models are exercised on purpose: apps still
// call them until genkit_hybrid 0.5.0 removes them.
// ignore_for_file: deprecated_member_use

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_model.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

import 'src/fake_runtime.dart';

/// A structured reply that failed on the device must never be retried in
/// the cloud by a status: not by the router, and not by the deprecated
/// fallback and cascade models. The control shows each path does move a
/// status the hybrid policy moves on.
void main() {
  const enforcesAll = gemma.StructuredOutputSupport(
    keywords: gemma.ResponseFormat.dialect,
  );

  /// Each failure a structured turn can end in, as the engine produces it.
  final failures = <(String, void Function(FakeInferenceModel))>[
    for (final (tokens, end) in [
      (['{"preferredBackend": '], gemma.TurnEnd.outputLimit),
      (['{"preferredBackend": '], gemma.TurnEnd.contextLimit),
      (['{"preferredBackend": "gpu"}'], gemma.TurnEnd.closed),
      (['{"preferredBackend": '], gemma.TurnEnd.stopped),
      // Not one of the enum's values: the engine did not enforce it.
      (['{"preferredBackend": "tpu"}'], gemma.TurnEnd.endOfSequence),
    ])
      (
        '${end.name}: ${tokens.single}',
        (model) => model
          ..structuredSupport = enforcesAll
          ..newSession = () => FakeStructuredSession(tokens: tokens, end: end),
      ),
    (
      'a structured input too long for the context window',
      (model) => model
        ..structuredSupport = enforcesAll
        ..newSession = () =>
            FakeStructuredSession(end: gemma.TurnEnd.contextLimit)
              ..errorBeforeText = const gemma.ContextLimitException(
                'The input needs 1500 tokens; 900 are left.',
              ),
    ),
    (
      'a prompt-only input too long for the context window',
      (model) => model.chatToReturn = FakeInferenceChat()
        ..generationError = const gemma.ContextLimitException(
          'The input needs 1500 tokens; 900 are left.',
        ),
    ),
    (
      'an engine that claims a keyword outside the dialect',
      (model) => model.structuredSupport = const gemma.StructuredOutputSupport(
        keywords: {'type', 'pattern'},
      ),
    ),
  ];

  late FakeRuntime runtime;
  late int cloudCalls;

  setUp(() {
    runtime = FakeRuntime(
      model: FakeInferenceModel()..chatToReturn = FakeInferenceChat(),
    );
    cloudCalls = 0;
  });

  ModelResponse cloudReply() => ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: [TextPart(text: '{"preferredBackend": "cpu"}')],
    ),
  );

  Model cloud() => Model(
    name: 'cloud',
    fn: (request, context) async {
      cloudCalls++;
      return cloudReply();
    },
  );

  Model device() => createFlutterEdgeAiModel(
    name: 'flutter-edge-ai/m',
    modelType: gemma.ModelType.gemmaIt,
    fileType: gemma.ModelFileType.task,
    runtime: runtime,
  );

  ModelRequest request() => ModelRequest(
    messages: [
      Message(
        role: Role.user,
        content: [TextPart(text: 'Pick a backend.')],
      ),
    ],
    output: OutputConfig(
      format: 'json',
      constrained: true,
      schema: FlutterEdgeAiEmbedConfig.$schema.jsonSchema(),
    ),
  );

  Future<GenerateResult<FlutterEdgeAiEmbedConfig>> routed() {
    final ai = Genkit(
      isDevEnv: false,
      promptDir: null,
      plugins: [
        GenkitFlutterEdgeAiPlugin(
          models: [
            FlutterEdgeAiModelConfig(
              name: 'm',
              modelType: gemma.ModelType.gemmaIt,
            ),
          ],
          runtime: runtime,
        ),
      ],
    );
    final router = defineHybridRouter(
      ai,
      name: 'router',
      targets: {
        kOnDevice: HybridTarget.onDevice(flutterEdgeAi.model('m')),
        kCloud: HybridTarget.cloud(modelRef('fakecloud/big')),
      },
      cloudPlugins: [_CloudPlugin(() => cloudCalls++, cloudReply)],
      policies: {
        'p': RoutePolicy(
          rules: [
            RouteRule.custom(
              'device first',
              (_) => const RouteDecision.prefer(kOnDevice),
            ),
          ],
          fallback: const [kCloud],
        ),
      },
      defaultPolicy: 'p',
    );
    return router.generate(
      prompt: 'Pick a backend.',
      outputSchema: FlutterEdgeAiEmbedConfig.$schema,
    );
  }

  test(
    'control: an UNAVAILABLE device reaches the cloud on every path',
    () async {
      // No model installed: a status the hybrid policy moves on.
      runtime.loadError = gemma.NoActiveModelError('No model installed.');

      await hybridModelOnDeviceCloud(
        onDevice: device(),
        cloud: cloud(),
        strategy: FallbackStrategy(const [kOnDevice, kCloud]),
      )(request());
      expect(cloudCalls, 1);
      await cascadeModel(
        branches: {kOnDevice: device(), kCloud: cloud()},
        order: const [kOnDevice, kCloud],
        accept: (_) => true,
      )(request());
      expect(cloudCalls, 2);
      final result = await routed();
      expect(result.route!.attempts, [kOnDevice, kCloud]);
      expect(cloudCalls, 3);
    },
  );

  for (final (what, arrange) in failures) {
    group(what, () {
      setUp(() => arrange(runtime.modelToReturn));

      test('the router does not move it to the cloud', () async {
        final result = await routed();

        expect(result.finishReason, FinishReason.failed);
        expect(result.route!.attempts, [kOnDevice]);
        expect(cloudCalls, 0);
      });

      for (final streaming in [false, true]) {
        test('hybridModelOnDeviceCloud${streaming ? ', streamed,' : ''} '
            'does not fall back to the cloud', () async {
          final hybrid = hybridModelOnDeviceCloud(
            onDevice: device(),
            cloud: cloud(),
            strategy: FallbackStrategy(const [kOnDevice, kCloud]),
          );

          await expectLater(
            hybrid(request(), onChunk: streaming ? (_) {} : null),
            throwsA(isA<GenkitException>()),
          );
          expect(cloudCalls, 0);
        });
      }

      test('cascadeModel does not escalate to the cloud', () async {
        final cascade = cascadeModel(
          branches: {kOnDevice: device(), kCloud: cloud()},
          order: const [kOnDevice, kCloud],
          accept: (_) => true,
        );

        await expectLater(cascade(request()), throwsA(isA<GenkitException>()));
        expect(cloudCalls, 0);
      });
    });
  }
}

/// Resolves `fakecloud/<any>` to a model that counts its calls.
final class _CloudPlugin extends GenkitPlugin {
  _CloudPlugin(this.onCall, this.reply);

  final void Function() onCall;
  final ModelResponse Function() reply;

  @override
  String get name => 'fakecloud';

  @override
  Future<List<Action>> init() async => const [];

  @override
  Action? resolve(ActionType actionType, String name) {
    if (actionType != ActionType.model) return null;
    return Model(
      name: 'fakecloud/$name',
      fn: (request, context) async {
        onCall();
        return reply();
      },
    );
  }
}
