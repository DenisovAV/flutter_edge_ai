import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

/// Runnable illustration of [defineHybridRouter].
///
/// In a real app the on-device model comes from a plugin such as
/// genkit_flutter_edge_ai and the cloud one from genkit_google_genai. Here
/// both are in-memory stand-ins so the example runs as-is.
Future<void> main() async {
  // No default model: a call that skips the router has nowhere to go.
  final ai = Genkit(isDevEnv: false, promptDir: null);
  ai.defineModel(name: 'on-device', fn: _reply('answered on the device'));

  final router = defineHybridRouter(
    ai,
    targets: {
      kOnDevice: HybridTarget.onDevice(modelRef('on-device')),
      kCloud: HybridTarget.cloud(modelRef('echo-cloud/big')),
    },
    // The cloud plugin goes to the router only.
    cloudPlugins: [_EchoCloud()],
    policies: {
      'short-here': RoutePolicy(
        rules: [
          RouteRule.inputSize(maxChars: 40, small: kOnDevice, large: kCloud),
        ],
        fallback: const [kOnDevice],
      ),
    },
    defaultPolicy: 'short-here',
  );

  final short = await router.generate(prompt: 'Hello!');
  print('${short.text} (${short.route!.target})');

  final long = await router.generate(
    prompt: 'Summarise the history of the printing press in Europe.',
  );
  print('${long.text} (${long.route!.target})');
}

/// A cloud plugin stand-in: resolves `echo-cloud/<name>`.
class _EchoCloud extends GenkitPlugin {
  @override
  String get name => 'echo-cloud';

  @override
  Action? resolve(ActionType actionType, String name) =>
      actionType == ActionType.model
      ? Model(name: 'echo-cloud/$name', fn: _reply('answered in the cloud'))
      : null;
}

ActionFn<ModelRequest, ModelResponse, ModelResponseChunk, void> _reply(
  String text,
) =>
    (request, context) async => ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [TextPart(text: text)],
      ),
    );
