import 'dart:async';

import 'package:flutter_edge_ai/engine.dart' show ModelType;
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

  test('the native model is released before the close listeners fire, and a '
      'second close() waits for it', () async {
    // Core builds the next model once the listeners fire, and the native side
    // holds one model: a closeModel landing after that build would take the
    // new model down with it.
    const codec = PlatformService.pigeonChannelCodec;
    final nativeClose = Completer<void>();
    var nativeCloseCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(_closeModel, (message) async {
          nativeCloseCalls++;
          await nativeClose.future;
          return codec.encodeMessage(<Object?>[null]);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_closeModel, null),
    );
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
    );
    var listenerFired = false;
    model.addCloseListener(() => listenerFired = true);

    final first = model.close();
    var secondDone = false;
    final second = model.close().then((_) => secondDone = true);
    await pumpEventQueue();
    expect(nativeCloseCalls, 1);
    expect(listenerFired, isFalse, reason: 'the native model is not gone yet');
    expect(secondDone, isFalse, reason: 'a second close() joins the first');

    nativeClose.complete();
    await Future.wait([first, second]);
    expect(listenerFired, isTrue);
    expect(nativeCloseCalls, 1);
  });
}
