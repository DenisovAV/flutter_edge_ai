// How a MediaPipe mobile turn ends, as core's chat reads it: a native start
// that fails is the turn's error (it used to leave the turn waiting), a stop
// keeps the partial reply even when the native cancel arrives as an error
// (iOS), and a close the consumer did not ask for is TurnEnd.closed.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

const _prefix = 'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.';

final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Answers the pigeon call [method]: [error] as a platform error, else void.
void _answer(String method, {PlatformException? error, void Function()? then}) {
  const codec = PlatformService.pigeonChannelCodec;
  _messenger.setMockMessageHandler('$_prefix$method', (message) async {
    then?.call();
    if (error != null) {
      return codec.encodeMessage(<Object?>[
        error.code,
        error.message,
        error.details,
      ]);
    }
    return codec.encodeMessage(<Object?>[null]);
  });
  addTearDown(() => _messenger.setMockMessageHandler('$_prefix$method', null));
}

/// The event channel's sink, once the session listens.
Future<MockStreamHandlerEventSink> _events() {
  final sink = Completer<MockStreamHandlerEventSink>();
  _messenger.setMockStreamHandler(
    eventChannel,
    MockStreamHandler.inline(
      onListen: (arguments, events) => sink.complete(events),
    ),
  );
  addTearDown(() => _messenger.setMockStreamHandler(eventChannel, null));
  return sink.future;
}

MobileInferenceModelSession _legacy() => MobileInferenceModelSession(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.task,
  supportImage: false,
  supportAudio: false,
  onClose: () {},
);

// ignore: invalid_use_of_protected_member
EngineTurn _turn(InferenceModelSession session) => session.startTurn();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a native start that fails is the turn\'s error, not a wait', () async {
    unawaited(_events());
    _answer(
      'generateResponseAsync',
      error: PlatformException(
        code: 'busy',
        message: 'Previous invocation still processing',
      ),
    );
    final text = _legacy().getResponseAsync().toList();
    await expectLater(
      text.timeout(const Duration(seconds: 5)),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'a stop keeps the partial reply although the native cancel arrives '
    'as an error with no end after it (iOS), and the next turn runs',
    () async {
      final events = _events();
      _answer('generateResponseAsync');
      final session = _legacy();
      _answer(
        'stopGeneration',
        then: () => events.then(
          (sink) =>
              sink.error(code: 'cancelled', message: 'MediaPipe cancelled'),
        ),
      );
      final turn = _turn(session);
      final text = turn.text.toList();
      final sink = await events;
      sink.success({'partialResult': 'Par'});
      await pumpEventQueue();
      await session.stopGeneration();
      expect(await text.timeout(const Duration(seconds: 5)), ['Par']);
      expect(await turn.end, TurnEnd.stopped);

      // The stopped turn released the session: the next one starts and ends.
      final next = _turn(session);
      final nextText = next.text.toList();
      await pumpEventQueue();
      sink
        ..success({'partialResult': 'ok'})
        ..endOfStream();
      expect(await nextText.timeout(const Duration(seconds: 5)), ['ok']);
    },
  );

  test('a failed generation ends the stream: an error, then done', () async {
    final events = _events();
    _answer('generateResponseAsync');
    final ended = Completer<List<Object>>();
    final errors = <Object>[];
    _legacy().getResponseAsync().listen(
      (_) {},
      onError: errors.add,
      onDone: () => ended.complete(errors),
    );
    (await events).error(code: 'ERROR', message: 'decode failed');
    expect(await ended.future.timeout(const Duration(seconds: 5)), [
      isA<PlatformException>(),
    ]);
  });

  test('a failed native start ends the stream after its error', () async {
    unawaited(_events());
    _answer('generateResponseAsync', error: PlatformException(code: 'busy'));
    final ended = Completer<void>();
    _legacy().getResponseAsync().listen(
      (_) {},
      onError: (_) {},
      onDone: ended.complete,
    );
    await ended.future.timeout(const Duration(seconds: 5));
  });

  test('closing an open session while its turn waits for the generation '
      'lock leaves the lock free', () async {
    unawaited(_events());
    _answer('generateResponseAsyncForSession');
    _answer('closeSessionId');
    final mutex = Mutex();
    final session = MultiSessionMobileInferenceModelSession(
      sessionId: 8,
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
      supportImage: false,
      supportAudio: false,
      generationMutex: mutex,
      onClose: () {},
    );
    // Another session holds the lock.
    await mutex.acquire();
    final turn = _turn(session);
    final text = turn.text.toList();
    await pumpEventQueue();
    await session.close();
    expect(await text.timeout(const Duration(seconds: 5)), isEmpty);
    mutex.release();
    await pumpEventQueue();
    expect(mutex.isLocked, isFalse, reason: 'the closed turn took the lock');
  });

  test('a close the consumer did not ask for is TurnEnd.closed, with the '
      'partial reply kept', () async {
    final events = _events();
    _answer('generateResponseAsync');
    _answer('stopGeneration');
    _answer('closeSession');
    final session = _legacy();
    final turn = _turn(session);
    final text = turn.text.toList();
    (await events).success({'partialResult': 'Par'});
    await pumpEventQueue();
    await session.close();
    expect(await text, ['Par']);
    expect(await turn.end, TurnEnd.closed);
  });

  test('closing an open session ends its running turn as closed instead of '
      'leaving it waiting for a done that never comes', () async {
    final events = _events();
    _answer('generateResponseAsyncForSession');
    _answer('closeSessionId');
    final session = MultiSessionMobileInferenceModelSession(
      sessionId: 7,
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
      supportImage: false,
      supportAudio: false,
      generationMutex: Mutex(),
      onClose: () {},
    );
    final turn = _turn(session);
    final text = turn.text.toList();
    (await events).success({'sessionId': 7, 'partialResult': 'Par'});
    await pumpEventQueue();
    await session.close();
    expect(await text.timeout(const Duration(seconds: 5)), ['Par']);
    expect(await turn.end, TurnEnd.closed);
  });

  test('a turn that runs to its end is endOfSequence', () async {
    final events = _events();
    _answer('generateResponseAsync');
    final turn = _turn(_legacy());
    final text = turn.text.toList();
    final sink = await events;
    sink
      ..success({'partialResult': 'ok'})
      ..endOfStream();
    expect(await text, ['ok']);
    expect(await turn.end, TurnEnd.endOfSequence);
  });
}
