// Integration tests: prove that hybridModel plugs into a real Genkit pipeline
// driven by ai.generate — not just direct model calls with hand-built context.
//
// How we read the API:
//   final text:   GenerateResult.text  (delegates to ModelResponse.text)
//   chunk text:   GenerateResponseChunk.text   (joins all TextPart.text values in chunk.content)
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a real [Model] that returns [text] as a non-streaming response.
/// Optionally streams [chunks] before the final response.
/// If [throwImmediately] is true, it throws a plain [Exception] on every call
/// (treated as transient by hybridModel).
Model _realModel({
  required String name,
  String text = 'ok',
  List<String> chunks = const [],
  bool throwImmediately = false,
}) {
  return Model(
    name: name,
    fn: (request, context) async {
      if (throwImmediately) throw Exception('$name is unavailable');

      if (context.streamingRequested && chunks.isNotEmpty) {
        for (final c in chunks) {
          context.sendChunk(
            ModelResponseChunk(
              role: Role.model,
              content: [TextPart(text: c)],
            ),
          );
        }
      }

      return ModelResponse(
        finishReason: FinishReason.stop,
        message: Message(
          role: Role.model,
          content: [TextPart(text: text)],
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('hybridModel — real Genkit pipeline (ai.generate)', () {
    // Test 1: pre-routing through real pipeline
    test('pre-routing: request is routed to the chosen branch', () async {
      final ai = Genkit(isDevEnv: false);

      final deviceModel = _realModel(name: 'device-pre', text: 'DEVICE');
      final cloudModel = _realModel(name: 'cloud-pre', text: 'CLOUD');

      final smart = hybridModelOnDeviceCloud(
        onDevice: deviceModel,
        cloud: cloudModel,
        strategy: PreRoutingStrategy((_) => kCloud),
      );

      // Register the hybrid model so the Genkit registry can find it by name.
      ai.registry.register(smart);

      final res = await ai.generate(model: smart, prompt: 'hi');

      expect(res.text, equals('CLOUD'));

      await ai.shutdown();
    });

    // Test 2: fallback through real pipeline
    test('fallback: primary throws -> secondary recovers', () async {
      final ai = Genkit(isDevEnv: false);

      final deviceModel = _realModel(name: 'device-fb', throwImmediately: true);
      final cloudModel = _realModel(name: 'cloud-fb', text: 'RECOVERED');

      final smart = hybridModelOnDeviceCloud(
        onDevice: deviceModel,
        cloud: cloudModel,
        strategy: FallbackStrategy([kOnDevice, kCloud]),
      );

      ai.registry.register(smart);

      final res = await ai.generate(model: smart, prompt: 'hi');

      expect(res.text, equals('RECOVERED'));

      await ai.shutdown();
    });

    test('every branch fails -> ai.generate returns a failed result', () async {
      // genkit 1.0 does not throw out of ai.generate: the error comes back in
      // the result, which is what the README tells apps to check.
      final ai = Genkit(isDevEnv: false);

      final smart = hybridModelOnDeviceCloud(
        onDevice: _realModel(name: 'device-x', throwImmediately: true),
        cloud: _realModel(name: 'cloud-x', throwImmediately: true),
        strategy: FallbackStrategy([kOnDevice, kCloud]),
      );
      ai.registry.register(smart);

      final res = await ai.generate(model: smart, prompt: 'hi');

      expect(res.finishReason, FinishReason.failed);
      expect(res.cause.toString(), contains('cloud-x is unavailable'));

      await ai.shutdown();
    });

    // Test 3: streaming through real pipeline
    test('streaming: chunks arrive and final response matches', () async {
      final ai = Genkit(isDevEnv: false);

      final cloudModel = _realModel(
        name: 'cloud-stream',
        text: 'Hello',
        chunks: ['Hel', 'lo'],
      );

      final smart = hybridModelOnDeviceCloud(
        onDevice: _realModel(name: 'device-stream', text: 'DEVICE'),
        cloud: cloudModel,
        strategy: PreRoutingStrategy((_) => kCloud),
      );

      ai.registry.register(smart);

      final received = <String>[];

      final res = await ai.generate(
        model: smart,
        prompt: 'hi',
        onChunk: (chunk) => received.add(chunk.text),
      );

      // Streamed chunks should join to 'Hello'
      expect(received.join(''), equals('Hello'));
      // Final response text should also be 'Hello'
      expect(res.text, equals('Hello'));

      await ai.shutdown();
    });
  });
}
