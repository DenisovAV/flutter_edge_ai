import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _closeModel =
    'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.closeModel';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isClosed is true from the moment close() starts', () async {
    // Core's getActiveModel cache checks this: its close listener fires only
    // once the teardown has ended.
    const codec = PlatformService.pigeonChannelCodec;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          _closeModel,
          (message) async => codec.encodeMessage(<Object?>[null]),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_closeModel, null),
    );
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
    );
    expect(model.isClosed, isFalse);

    final closing = model.close();
    expect(model.isClosed, isTrue);
    await closing;
  });
}
