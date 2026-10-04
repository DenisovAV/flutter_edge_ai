import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

/// Runnable illustration of [hybridModelOnDeviceCloud].
///
/// In a real app, `onDevice` and `cloud` come from provider plugins
/// (e.g. genkit_flutter_edge_ai for on-device, genkit_google_genai for cloud).
/// Here they're trivial in-memory [Model]s so the example runs as-is.
Future<void> main() async {
  final ai = Genkit();

  final onDeviceModel = _echoModel('on-device', 'answered on-device');
  final cloudModel = _echoModel('cloud', 'answered in the cloud');

  // Prefer on-device, fall back to cloud on a transient failure / offline.
  final smart = hybridModelOnDeviceCloud(
    onDevice: onDeviceModel,
    cloud: cloudModel,
    strategy: FallbackStrategy([kOnDevice, kCloud]),
  );

  // A hybrid model is an ordinary Genkit Model — register it, then generate.
  ai.registry.register(smart);

  final res = await ai.generate(model: smart, prompt: 'Hello!');
  print(res.text);
}

/// A minimal [Model] that returns a fixed string — stands in for a real provider.
Model _echoModel(String name, String text) => Model(
  name: name,
  fn: (request, context) async => ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: [TextPart(text: text)],
    ),
  ),
);
