// Rule A on MediaPipe mobile: a turn that fails, or is stopped before any
// text, is not kept by the chat, so the native session must not keep it
// either. MediaPipe cannot take queued input back, so the session builds the
// native session again and replays what it held before the turn.
// The deprecated calls verify replacement/rebuild ordering in the legacy lane.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_model.dart';
import 'package:flutter_edge_ai_mediapipe/src/mobile/mobile_inference_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

const _prefix = 'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.';

final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Every pigeon call's name and arguments, in order.
final _calls = <(String, List<Object?>)>[];

/// Answers each of [methods], recording the call; [replies] gives a
/// method's return value (null otherwise).
void _record(List<String> methods, {Map<String, Object?> replies = const {}}) {
  const codec = PlatformService.pigeonChannelCodec;
  for (final method in methods) {
    _messenger.setMockMessageHandler('$_prefix$method', (message) async {
      _calls.add((
        method,
        (codec.decodeMessage(message) as List<Object?>?) ?? const [],
      ));
      return codec.encodeMessage(<Object?>[replies[method]]);
    });
    addTearDown(
      () => _messenger.setMockMessageHandler('$_prefix$method', null),
    );
  }
}

/// The event channel's sinks, one per listen: [next] is the sink of the
/// next listen (or of the current one, when a session already listens).
final class _Events {
  _Events() {
    _messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          _current = events;
          final waiting = _waiting;
          _waiting = null;
          waiting?.complete(events);
        },
      ),
    );
    addTearDown(() => _messenger.setMockStreamHandler(eventChannel, null));
  }

  MockStreamHandlerEventSink? _current;
  Completer<MockStreamHandlerEventSink>? _waiting;

  /// The sink of the listen to come.
  Future<MockStreamHandlerEventSink> next() =>
      (_waiting = Completer<MockStreamHandlerEventSink>()).future;

  /// The sink of the listen in progress.
  MockStreamHandlerEventSink get current => _current!;
}

/// The prompt chunks sent by [method] since index [from] of [_calls].
List<String> _chunks(String method, {int from = 0}) => [
  for (final (name, args) in _calls.skip(from))
    if (name == method) args.last as String,
];

const _q1 = Message(text: 'Q1', isUser: true);
const _q2 = Message(text: 'Q2', isUser: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_calls.clear);

  group('createSession session', () {
    late int recreated;
    MobileInferenceModelSession session({
      Future<void> Function()? recreate,
      bool supportImage = false,
    }) => MobileInferenceModelSession(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
      onClose: () {},
      systemInstruction: 'Be brief',
      supportImage: supportImage,
      recreateNative: recreate ?? () async => recreated++,
    );

    setUp(() {
      recreated = 0;
      _record(
        [
          'addQueryChunk',
          'addImage',
          'generateResponse',
          'generateResponseAsync',
          'stopGeneration',
          'closeSession',
        ],
        replies: {'generateResponse': 'A1'},
      );
    });

    /// Runs one turn the native side answers with 'A1' (blocking call).
    Future<void> completedTurn(MobileInferenceModelSession s) async {
      expect(await s.getResponse(), 'A1');
    }

    test('a turn stopped before any text is taken out of the native session: '
        'rebuilt, with only the turn before it replayed', () async {
      final events = _Events();
      final s = session();
      await s.addQueryChunk(_q1);
      await completedTurn(s);
      final before = _calls.length;

      await s.addQueryChunk(_q2);
      // ignore: invalid_use_of_protected_member
      final turn = s.startTurn();
      final text = turn.text.toList();
      await pumpEventQueue();
      await s.stopGeneration();
      // iOS: the cancel arrives as an error, with nothing generated.
      events.current.error(code: 'cancelled');
      expect(await text.timeout(const Duration(seconds: 5)), isEmpty);
      expect(await turn.end, TurnEnd.stopped);

      expect(recreated, 1);
      final replayed = _chunks('addQueryChunk', from: before);
      // Q2 went out, then the rebuild replayed Q1 and A1 only.
      expect(replayed.where((c) => c.contains('Q2')), hasLength(1));
      expect(replayed.last, contains('A1'));
      expect(replayed[replayed.length - 2], contains('Q1'));
      expect(replayed[replayed.length - 2], contains('[System: Be brief]'));
    });

    test(
      'a failed turn is taken out the same way, and the next message '
      'carries the system instruction again when the failed one did',
      () async {
        final events = _Events();
        final s = session();
        await s.addQueryChunk(_q1);
        final text = s.getResponseAsync().toList();
        await pumpEventQueue();
        events.current.error(code: 'ERROR', message: 'decode failed');
        await expectLater(text, throwsA(anything));
        expect(recreated, 1);
        final before = _calls.length;
        await s.addQueryChunk(_q2);
        expect(
          _chunks('addQueryChunk', from: before).single,
          contains('[System: Be brief]'),
        );
      },
    );

    test('a completed turn, and a stop after some text, keep the native '
        'session as it is', () async {
      final events = _Events();
      final s = session();
      await s.addQueryChunk(_q1);
      await completedTurn(s);

      await s.addQueryChunk(_q2);
      // ignore: invalid_use_of_protected_member
      final turn = s.startTurn();
      final text = turn.text.toList();
      await pumpEventQueue();
      final sink = events.current;
      await pumpEventQueue();
      sink.success({'partialResult': 'Par'});
      await pumpEventQueue();
      await s.stopGeneration();
      sink.error(code: 'cancelled');
      expect(await text, ['Par']);
      expect(recreated, 0);
    });

    test('a rebuild that fails leaves the turn the engine\'s own error, and '
        'the session refuses every call after', () async {
      final events = _Events();
      final s = session(recreate: () async => throw StateError('rebuild'));
      await s.addQueryChunk(_q1);
      final text = s.getResponseAsync().toList();
      await pumpEventQueue();
      events.current.error(code: 'ERROR', message: 'decode failed');
      await expectLater(
        text.timeout(const Duration(seconds: 5)),
        throwsA(isA<PlatformException>()),
      );
      expect(() => s.addQueryChunk(_q2), throwsStateError);
      await expectLater(s.getResponse(), throwsStateError);
    });

    test('a session closed while its native session is rebuilt gets nothing '
        'replayed, and what was built is closed again', () async {
      final events = _Events();
      late MobileInferenceModelSession s;
      s = session(recreate: () async => s.close());
      await s.addQueryChunk(_q1);
      await completedTurn(s);
      await s.addQueryChunk(_q2);
      final text = s.getResponseAsync().toList();
      await pumpEventQueue();
      final before = _calls.length;
      events.current.error(code: 'ERROR', message: 'decode failed');
      await expectLater(text, throwsA(anything));
      await pumpEventQueue();
      final after = [for (final (name, _) in _calls.skip(before)) name];
      expect(after, isNot(contains('addQueryChunk')));
      expect(after.where((name) => name == 'closeSession'), hasLength(2));
    });

    test(
      'images of a kept turn are replayed after a later take-back',
      () async {
        final events = _Events();
        final s = session(supportImage: true);
        await s.addQueryChunk(
          Message(
            text: 'look',
            isUser: true,
            imageBytes: Uint8List.fromList([1]),
          ),
        );
        await completedTurn(s);
        await s.addQueryChunk(_q2);
        final text = s.getResponseAsync().toList();
        await pumpEventQueue();
        final before = _calls.length;
        events.current.error(code: 'ERROR', message: 'decode failed');
        await expectLater(text, throwsA(anything));
        final after = [for (final (name, _) in _calls.skip(before)) name];
        expect(recreated, 1);
        expect(after.where((name) => name == 'addImage'), hasLength(1));
        expect(_chunks('addQueryChunk', from: before).first, contains('look'));
      },
    );

    test('a close that lands during the replay stops it', () async {
      final events = _Events();
      final s = session();
      await s.addQueryChunk(_q1);
      await completedTurn(s);
      await s.addQueryChunk(_q2);
      // From here on, the first chunk the replay sends closes the session.
      var replayed = 0;
      var replaying = false;
      const codec = PlatformService.pigeonChannelCodec;
      _messenger.setMockMessageHandler('${_prefix}addQueryChunk', (
        message,
      ) async {
        if (replaying && replayed++ == 0) unawaited(s.close());
        return codec.encodeMessage(<Object?>[null]);
      });
      final text = s.getResponseAsync().toList();
      await pumpEventQueue();
      replaying = true;
      events.current.error(code: 'ERROR', message: 'decode failed');
      await expectLater(text, throwsA(anything));
      await pumpEventQueue();
      expect(recreated, 1);
      // Q1 and A1 were held: the close after the first stops the second.
      expect(replayed, 1);
    });
  });

  group('openSession session', () {
    late int recreated;
    MultiSessionMobileInferenceModelSession session({
      Future<void> Function()? recreate,
      String? systemInstruction,
    }) => MultiSessionMobileInferenceModelSession(
      sessionId: 3,
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
      supportImage: false,
      supportAudio: false,
      generationMutex: Mutex(),
      onClose: () {},
      systemInstruction: systemInstruction,
      recreateNative: recreate ?? () async => recreated++,
    );

    setUp(() {
      recreated = 0;
      _record([
        'addQueryChunkToSession',
        'generateResponseAsyncForSession',
        'stopGenerationForSession',
        'closeSessionId',
      ]);
    });

    test(
      'a turn stopped before any text is taken out of the native session',
      () async {
        final events = _Events();
        final s = session();
        await s.addQueryChunk(_q1);
        final first = s.getResponseAsync().toList();
        await pumpEventQueue();
        final sink = events.current;
        await pumpEventQueue();
        sink.success({'sessionId': 3, 'partialResult': 'A1', 'done': true});
        await first;
        final before = _calls.length;

        await s.addQueryChunk(_q2);
        // ignore: invalid_use_of_protected_member
        final turn = s.startTurn();
        final text = turn.text.toList();
        await pumpEventQueue();
        await s.stopGeneration();
        sink.success({'sessionId': 3, 'partialResult': '', 'done': true});
        expect(await text.timeout(const Duration(seconds: 5)), isEmpty);
        expect(recreated, 1);
        final replayed = _chunks('addQueryChunkToSession', from: before);
        expect(replayed.last, contains('A1'));
        expect(replayed.where((c) => c.contains('Q2')), hasLength(1));
      },
    );

    test('a subscription cancelled before any text is a stop: the turn is '
        'taken out', () async {
      _Events();
      final s = session();
      await s.addQueryChunk(_q1);
      final sub = s.getResponseAsync().listen(null);
      await pumpEventQueue();
      await sub.cancel();
      expect(recreated, 1);
    });

    test(
      'a failed turn is taken out, and the generation lock is free after',
      () async {
        final events = _Events();
        final mutex = Mutex();
        final s = MultiSessionMobileInferenceModelSession(
          sessionId: 4,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.task,
          supportImage: false,
          supportAudio: false,
          generationMutex: mutex,
          onClose: () {},
          recreateNative: () async => recreated++,
        );
        await s.addQueryChunk(_q1);
        final text = s.getResponseAsync().toList();
        await pumpEventQueue();
        final sink = events.current;
        await pumpEventQueue();
        sink.success({'sessionId': 4, 'code': 'ERROR', 'message': 'failed'});
        await expectLater(text, throwsA(anything));
        expect(recreated, 1);
        expect(mutex.isLocked, isFalse);
      },
    );

    test('a rebuild that fails still ends the turn, with the engine\'s own '
        'error, and the session refuses every call after', () async {
      final events = _Events();
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final s = session(recreate: () async => throw StateError('rebuild'));
        await s.addQueryChunk(_q1);
        final text = s.getResponseAsync().toList();
        await pumpEventQueue();
        events.current.success({
          'sessionId': 3,
          'code': 'ERROR',
          'message': 'decode failed',
        });
        await expectLater(
          text.timeout(const Duration(seconds: 5)),
          throwsA(predicate((e) => '$e'.contains('decode failed'))),
        );
        expect(() => s.addQueryChunk(_q2), throwsStateError);
      }, (error, _) => zoneErrors.add(error));
      expect(zoneErrors, isEmpty);
    });

    test(
      'a zero-text stop whose rebuild fails ends the turn cleanly',
      () async {
        final events = _Events();
        final s = session(recreate: () async => throw StateError('rebuild'));
        await s.addQueryChunk(_q1);
        // ignore: invalid_use_of_protected_member
        final turn = s.startTurn();
        final text = turn.text.toList();
        await pumpEventQueue();
        await s.stopGeneration();
        events.current.success({
          'sessionId': 3,
          'partialResult': '',
          'done': true,
        });
        expect(await text.timeout(const Duration(seconds: 5)), isEmpty);
        expect(() => s.addQueryChunk(_q2), throwsStateError);
      },
    );

    test('a failed turn that carried the system instruction: the next message '
        'carries it again', () async {
      final events = _Events();
      final s = session(systemInstruction: 'Be brief');
      await s.addQueryChunk(_q1);
      final text = s.getResponseAsync().toList();
      await pumpEventQueue();
      events.current.success({
        'sessionId': 3,
        'code': 'ERROR',
        'message': 'decode failed',
      });
      await expectLater(text, throwsA(anything));
      final before = _calls.length;
      await s.addQueryChunk(_q2);
      expect(
        _chunks('addQueryChunkToSession', from: before).single,
        contains('[System: Be brief]'),
      );
    });
  });

  test(
    'a take-back rebuilds the createSession session in the model\'s '
    'createSession lane, and a createSession started meanwhile waits for it',
    () async {
      final events = _Events();
      const codec = PlatformService.pigeonChannelCodec;
      var created = 0;
      final gate = Completer<void>();
      _messenger.setMockMessageHandler('${_prefix}createSession', (
        message,
      ) async {
        created++;
        // The rebuild (the second call) waits until the test lets it go.
        if (created == 2) await gate.future;
        return codec.encodeMessage(<Object?>[null]);
      });
      addTearDown(
        () => _messenger.setMockMessageHandler('${_prefix}createSession', null),
      );
      _record([
        'addQueryChunk',
        'generateResponseAsync',
        'stopGeneration',
        'closeSession',
      ]);
      final model = MobileInferenceModel(
        maxTokens: 1024,
        onClose: () {},
        modelType: ModelType.gemmaIt,
      );
      final s = await model.createSession();
      await s.addQueryChunk(_q1);
      final text = s.getResponseAsync().toList();
      await pumpEventQueue();
      events.current.error(code: 'ERROR', message: 'decode failed');
      await pumpEventQueue();
      expect(created, 2, reason: 'the rebuild went through createSession');

      final next = model.createSession();
      await pumpEventQueue();
      expect(created, 2, reason: 'it waits for the rebuild in flight');
      gate.complete();
      await expectLater(text, throwsA(anything));
      await next;
      expect(created, 3);
    },
  );

  test('a rebuild for a session that a createSession replaced meanwhile, or of '
      'a closed model, builds nothing', () async {
    const codec = PlatformService.pigeonChannelCodec;
    var created = 0;
    final gate = Completer<void>();
    _messenger.setMockMessageHandler('${_prefix}createSession', (
      message,
    ) async {
      created++;
      // The replacing createSession waits until the test lets it go.
      if (created == 2) await gate.future;
      return codec.encodeMessage(<Object?>[null]);
    });
    addTearDown(
      () => _messenger.setMockMessageHandler('${_prefix}createSession', null),
    );
    _record(['stopGeneration', 'closeSession', 'closeModel']);
    final model = MobileInferenceModel(
      maxTokens: 1024,
      onClose: () {},
      modelType: ModelType.gemmaIt,
    );
    final first = await model.createSession() as MobileInferenceModelSession;
    final next = model.createSession();
    await pumpEventQueue();
    final rebuild = expectLater(first.recreateNative!(), throwsStateError);
    await pumpEventQueue();
    expect(created, 2, reason: 'the rebuild waits for the createSession');
    gate.complete();
    final second = await next as MobileInferenceModelSession;
    await rebuild;
    expect(created, 2, reason: 'the replaced session is not rebuilt');

    await model.close();
    await expectLater(second.recreateNative!(), throwsStateError);
    expect(created, 2);
  });
}
