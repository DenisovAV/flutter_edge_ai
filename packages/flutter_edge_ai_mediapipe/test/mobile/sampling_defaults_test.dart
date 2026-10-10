import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _createSession =
    'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.createSession';

/// The `(temperature, randomSeed, topK, topP)` the native side receives.
Future<List<Object?>> _sentSampler(
  Future<void> Function(MobileInferenceModel model) create, {
  ModelType modelType = ModelType.gemmaIt,
}) async {
  List<Object?>? args;
  const codec = PlatformService.pigeonChannelCodec;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(_createSession, (message) async {
        args = codec.decodeMessage(message) as List<Object?>;
        return codec.encodeMessage(<Object?>[null]);
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(_createSession, null),
  );
  await create(
    MobileInferenceModel(maxTokens: 1024, onClose: () {}, modelType: modelType),
  );
  return args!.sublist(0, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unset sampling sends the family defaults, not greedy', () async {
    // Gemma's top-k of 64 is held to MediaPipe's ceiling of 40.
    expect(await _sentSampler((m) => m.createSession()), [1.0, 1, 40, 0.95]);
  });

  test('a top-k the caller sets is not held to the ceiling', () async {
    expect(await _sentSampler((m) => m.createSession(topK: 64)), [
      1.0,
      1,
      64,
      0.95,
    ]);
  });

  test('values the caller sets reach the platform unchanged', () async {
    expect(
      await _sentSampler(
        (m) => m.createSession(temperature: 0.2, topK: 1, randomSeed: 9),
      ),
      [0.2, 9, 1, 0.95],
    );
  });

  test('a model with no family values gets the fallback', () async {
    expect(
      await _sentSampler(
        (m) => m.createSession(),
        modelType: ModelType.general,
      ),
      [0.8, 1, 40, 0.95],
    );
  });
}
