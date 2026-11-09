import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart' show ModelType;
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _createSessionForId =
    'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.createSessionForId';

/// Answers `createSessionForId` once [gate] completes, counting the calls.
void _mockCreateSessionForId(List<int> calls, {Future<void>? gate}) {
  const codec = PlatformService.pigeonChannelCodec;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler(_createSessionForId, (message) async {
    calls.add(1);
    await gate;
    return codec.encodeMessage(<Object?>[null]);
  });
  addTearDown(() => messenger.setMockMessageHandler(_createSessionForId, null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two openSession calls that overlap cannot both pass '
      'maxConcurrentSessions', () async {
    final calls = <int>[];
    final gate = Completer<void>();
    _mockCreateSessionForId(calls, gate: gate.future);
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
      maxConcurrentSessions: 1,
    );
    final first = model.openSession();
    // The first is still waiting on the platform when the second checks.
    await expectLater(model.openSession(), throwsStateError);
    gate.complete();
    await first;
    expect(calls, hasLength(1));
    expect(model.sessions, hasLength(1));
  });

  test('a failed open frees its slot', () async {
    const codec = PlatformService.pigeonChannelCodec;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var fail = true;
    messenger.setMockMessageHandler(_createSessionForId, (message) async {
      if (fail) {
        fail = false;
        throw PlatformException(code: 'boom');
      }
      return codec.encodeMessage(<Object?>[null]);
    });
    addTearDown(
      () => messenger.setMockMessageHandler(_createSessionForId, null),
    );
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
      maxConcurrentSessions: 1,
    );
    await expectLater(model.openSession(), throwsA(anything));
    await model.openSession();
    expect(model.sessions, hasLength(1));
  });

  test('a model closed while openSession waits on the platform closes the '
      'new native session and fails the open', () async {
    final gate = Completer<void>();
    _mockCreateSessionForId([], gate: gate.future);
    const codec = PlatformService.pigeonChannelCodec;
    final closedIds = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final method in ['closeSessionId', 'closeModel']) {
      final channel =
          'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.$method';
      messenger.setMockMessageHandler(channel, (message) async {
        if (method == 'closeSessionId') {
          closedIds.add((codec.decodeMessage(message) as List<Object?>).first);
        }
        return codec.encodeMessage(<Object?>[null]);
      });
      addTearDown(() => messenger.setMockMessageHandler(channel, null));
    }
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
    );
    final open = model.openSession();
    await pumpEventQueue();
    await model.close();
    gate.complete();
    await expectLater(open, throwsStateError);
    expect(closedIds, hasLength(1));
    expect(model.sessions, isEmpty);
  });

  test(
    'openChat takes the model\'s own type, as createChat does (D8)',
    () async {
      _mockCreateSessionForId([]);
      final model = MobileInferenceModel(
        maxTokens: 1024,
        onClose: () {},
        modelType: ModelType.qwen3,
        supportAudio: true,
      );
      final chat = await model.openChat();
      expect(chat.modelType, ModelType.qwen3);
      expect(chat.supportAudio, isTrue);
      expect(chat.supportImage, isFalse);
    },
  );
}
