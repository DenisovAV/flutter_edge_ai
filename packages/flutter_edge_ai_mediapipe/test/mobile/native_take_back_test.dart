// Rule A on MediaPipe mobile: a turn that fails, or is stopped before any
// text, is not kept by the chat, so the native session must not keep it
// either. MediaPipe cannot take queued input back, so the session builds the
// native session again and replays what it held before the turn.
import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';
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
    MobileInferenceModelSession session() => MobileInferenceModelSession(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
      onClose: () {},
      systemInstruction: 'Be brief',
      recreateNative: () async => recreated++,
    );

    setUp(() {
      recreated = 0;
      _record(
        [
          'addQueryChunk',
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
  });

  group('openSession session', () {
    late int recreated;
    MultiSessionMobileInferenceModelSession session() =>
        MultiSessionMobileInferenceModelSession(
          sessionId: 3,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.task,
          supportImage: false,
          supportAudio: false,
          generationMutex: Mutex(),
          onClose: () {},
          recreateNative: () async => recreated++,
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
  });
}
