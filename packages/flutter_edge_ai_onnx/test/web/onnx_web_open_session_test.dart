// ONNX web `openSession` (#703): further `OnnxWebSession`s on the one
// Transformers.js pipeline, each with its own history, capped by
// `maxConcurrentSessions`, all closed with the model; a stop reaches only its
// own session's turn, and `startTurn` reports a stop and a close.
//
// Runs over a JS fake of `window.transformers` (a pipeline whose calls the
// test answers chunk by chunk), so no model and no WebGPU are needed. Run:
//   flutter test --platform chrome test/web/onnx_web_open_session_test.dart
// Remaining deprecated calls verify that open sessions leave the legacy lane intact.
// ignore_for_file: deprecated_member_use

@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/web/onnx_engine_web.dart';
import 'package:flutter_edge_ai_onnx/src/web/onnx_web_inference_model.dart';
import 'package:flutter_edge_ai_onnx/src/web/transformers_web_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// `window.transformers` as the model uses it. Every pipeline call is pushed
/// to `__tf.calls` with its `resolve`; an interrupt resolves it, as the real
/// pipeline settles once decoding stops. `pipeline()` waits for `__tf.gate`,
/// then fails while `__tf.failures` is above zero (one per call). With
/// `__tf.rejectOnInterrupt` an interrupt fails the call instead; with
/// `__tf.holdOnInterrupt` it only marks the call, which then settles when the
/// test resolves it, as a real generation does a moment after the interrupt.
const _fakeTransformers = r'''
(() => {
  const tf = { calls: [], gate: Promise.resolve(), pipelines: 0, failures: 0, disposes: 0 };
  class TextStreamer {
    constructor(tokenizer, options) { this.cb = options.callback_function; }
  }
  class InterruptableStoppingCriteria {
    constructor() { this.interrupted = false; this.onInterrupt = null; }
    interrupt() {
      this.interrupted = true;
      if (this.onInterrupt) this.onInterrupt();
    }
    reset() { this.interrupted = false; }
  }
  const makePipe = () => {
    const pipe = function (messages, options) {
      return new Promise((resolve, reject) => {
        options.stopping_criteria.onInterrupt = () => tf.holdOnInterrupt
          ? undefined
          : tf.rejectOnInterrupt
          ? tf.calls.at(-1).reject(new Error('generate failed after the stop'))
          : tf.calls.at(-1).resolve();
        const call = { messages, options, settled: false };
        call.resolve = (v) => { call.settled = true; resolve(v); };
        call.reject = (e) => { call.settled = true; reject(e); };
        tf.calls.push(call);
      });
    };
    pipe.tokenizer = { encode: (text) => Array.from(text) };
    pipe.dispose = async () => {
      tf.disposes++;
      tf.disposedWithPendingCalls = tf.calls.some((c) => !c.settled);
      if (tf.failDispose) throw new Error('dispose failed');
    };
    return pipe;
  };
  window.transformers = {
    TextStreamer,
    InterruptableStoppingCriteria,
    env: {},
    pipeline: async () => {
      tf.pipelines++;
      await tf.gate;
      if (tf.failures > 0) {
        tf.failures--;
        throw new Error('pipeline failed');
      }
      return makePipe();
    },
  };
  window.transformersReady = Promise.resolve();
  window.__tf = tf;
})();
''';

class _Resolver implements TransformersWebResolver {
  @override
  Future<String> resolveActiveRepoId() async => 'owner/repo';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

JSObject get _tf => globalContext['__tf']! as JSObject;

List<JSObject> get _calls => (_tf['calls']! as JSArray<JSObject>).toDart;

/// The [n]th pipeline call (1-based), once the model has made it.
Future<JSObject> _call(int n) async {
  for (var i = 0; i < 1000 && _calls.length < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(_calls.length, greaterThanOrEqualTo(n), reason: 'pipeline call $n');
  return _calls[n - 1];
}

JSObject _options(JSObject call) => call['options']! as JSObject;

void _emit(JSObject call, String text) =>
    (_options(call)['streamer']! as JSObject).callMethod('cb'.toJS, text.toJS);

void _finish(JSObject call) => call.callMethod('resolve'.toJS);

void _fail(JSObject call) => call.callMethod('reject'.toJS, 'boom'.toJS);

bool _interrupted(JSObject call) =>
    ((_options(call)['stopping_criteria']! as JSObject)['interrupted']!
            as JSBoolean)
        .toDart;

List<String> _contents(JSObject call) => [
  for (final m in (call['messages'].dartify()! as List<Object?>).cast<Map>())
    '${m['role']}:${m['content']}',
];

OnnxWebInferenceModel _model({
  int? cap,
  ModelType modelType = ModelType.general,
  void Function()? onClose,
}) => OnnxWebInferenceModel(
  resolver: _Resolver(),
  maxTokens: 1024,
  modelType: modelType,
  maxConcurrentSessions: cap,
  onClose: onClose ?? () {},
);

// ignore: invalid_use_of_protected_member
EngineTurn _turn(InferenceModelSession session) => session.startTurn();

/// Starts a turn of [session] on [text] and collects what it streams.
Future<({EngineTurn turn, List<String> text, Future<void> done})> _ask(
  InferenceModelSession session,
  String text,
) async {
  await session.addQueryChunk(Message(text: text, isUser: true));
  final turn = _turn(session);
  final chunks = <String>[];
  final done = turn.text.forEach(chunks.add);
  return (turn: turn, text: chunks, done: done);
}

void main() {
  setUp(() {
    globalContext.callMethod('eval'.toJS, _fakeTransformers.toJS);
  });

  test('open sessions keep their own history on one pipeline', () async {
    final model = _model();
    final legacy = await model.createSession(systemInstruction: 'L');
    final a = await model.openSession(systemInstruction: 'A');
    final b = await model.openSession(systemInstruction: 'B');
    expect(model.sessions, [legacy, a, b]);
    expect((_tf['pipelines']! as JSNumber).toDartInt, 1);

    final a1 = await _ask(a, 'a1');
    final call1 = await _call(1);
    _emit(call1, 'ra1');
    _finish(call1);
    await a1.done;
    expect(a1.text, ['ra1']);
    expect(await a1.turn.end, TurnEnd.endOfSequence);

    final b1 = await _ask(b, 'b1');
    final call2 = await _call(2);
    expect(_contents(call2), ['system:B', 'user:b1']);
    _emit(call2, 'rb1');
    _finish(call2);
    await b1.done;

    final a2 = await _ask(a, 'a2');
    final call3 = await _call(3);
    expect(_contents(call3), [
      'system:A',
      'user:a1',
      'assistant:ra1',
      'user:a2',
    ]);
    _finish(call3);
    await a2.done;
    await model.close();
  });

  test('maxConcurrentSessions caps open sessions, also two that overlap '
      'while the pipeline loads; createSession is not counted', () async {
    final gate = Completer<void>();
    _tf['gate'] = gate.future.toJS;
    final model = _model(cap: 1);
    final first = model.openSession();
    await expectLater(model.openSession(), throwsStateError);
    gate.complete();
    final opened = await first;
    await expectLater(model.openSession(), throwsStateError);
    await model.createSession();
    expect(model.sessions, hasLength(2));

    await opened.close();
    expect(model.sessions, hasLength(1));
    await model.openSession();
    expect(model.sessions, hasLength(2));
    await model.close();
  });

  test('a stop on a turn waiting behind another session ends it at once, '
      'and never cuts the running turn', () async {
    final model = _model();
    final a = await model.openSession();
    final b = await model.openSession();

    final b1 = await _ask(b, 'b1');
    final running = await _call(1);
    final a1 = await _ask(a, 'a1');
    await pumpEventQueue();
    await a.stopGeneration();
    // A ends while B is still generating.
    await a1.done.timeout(const Duration(seconds: 5));
    expect(a1.text, isEmpty);
    expect(await a1.turn.end, TurnEnd.stopped);
    expect(_interrupted(running), isFalse);
    _emit(running, 'rb1');
    _finish(running);
    await b1.done;
    expect(b1.text, ['rb1']);
    expect(await b1.turn.end, TurnEnd.endOfSequence);
    await pumpEventQueue();
    expect(_calls, hasLength(1), reason: "a's stopped turn never generated");

    // And a stop of the running turn interrupts it alone.
    final a2 = await _ask(a, 'a2');
    final aRunning = await _call(2);
    final b2 = await _ask(b, 'b2');
    _emit(aRunning, 'part');
    await pumpEventQueue();
    await a.stopGeneration();
    expect(_interrupted(aRunning), isTrue);
    await a2.done;
    expect(a2.text, ['part']);
    expect(await a2.turn.end, TurnEnd.stopped);
    final bRunning = await _call(3);
    expect(_interrupted(bRunning), isFalse);
    _finish(bRunning);
    await b2.done;
    expect(await b2.turn.end, TurnEnd.endOfSequence);
    await model.close();
  });

  test('a turn stopped before it produced anything leaves no trace in the '
      'history, so it keeps alternating', () async {
    final model = _model();
    final a = await model.openSession(systemInstruction: 'A');
    final b = await model.openSession();

    // Stopped while waiting behind B, with a message added while it waited.
    final b1 = await _ask(b, 'b1');
    final bRunning = await _call(1);
    final a1 = await _ask(a, 'a1');
    await pumpEventQueue();
    await a.addQueryChunk(const Message(text: 'a1b', isUser: true));
    await a.stopGeneration();
    await a1.done;
    _finish(bRunning);
    await b1.done;

    // Stopped while generating, before its first chunk.
    final a2 = await _ask(a, 'a2');
    final aRunning = await _call(2);
    expect(_contents(aRunning), ['system:A', 'user:a2']);
    await a.stopGeneration();
    await a2.done;
    expect(await a2.turn.end, TurnEnd.stopped);

    final a3 = await _ask(a, 'a3');
    final next = await _call(3);
    expect(_contents(next), ['system:A', 'user:a3']);
    _emit(next, 'ra3');
    _finish(next);
    await a3.done;

    // A stop after a chunk keeps the exchange.
    final a4 = await _ask(a, 'a4');
    final partial = await _call(4);
    _emit(partial, 'part');
    await pumpEventQueue();
    await a.stopGeneration();
    await a4.done;
    final a5 = await _ask(a, 'a5');
    final last = await _call(5);
    expect(_contents(last), [
      'system:A',
      'user:a3',
      'assistant:ra3',
      'user:a4',
      'assistant:part',
      'user:a5',
    ]);
    _finish(last);
    await a5.done;
    await model.close();
  });

  test('a stop belongs to the turn it stopped: a later turn, or one listened '
      'to after the stop, ends as itself', () async {
    final model = _model();
    final a = await model.openSession();

    final a1 = await _ask(a, 'a1');
    final first = await _call(1);
    _emit(first, 'part');
    await pumpEventQueue();
    await a.stopGeneration();
    await a1.done;
    expect(await a1.turn.end, TurnEnd.stopped);

    // A stop before the turn is listened to does not stop it.
    await a.addQueryChunk(const Message(text: 'a2', isUser: true));
    final a2 = _turn(a);
    await a.stopGeneration();
    final text = <String>[];
    final done = a2.text.forEach(text.add);
    final second = await _call(2);
    _emit(second, 'ra2');
    _finish(second);
    await done;
    expect(text, ['ra2']);
    expect(await a2.end, TurnEnd.endOfSequence);
    await model.close();
  });

  test('a second turn of the same session while one is under way is a '
      'StateError; the session takes the next turn once it ends', () async {
    final model = _model();
    final a = await model.openSession();
    final a1 = await _ask(a, 'a1');
    final running = await _call(1);
    expect(() => _turn(a), throwsStateError);
    expect(() => a.getResponseAsync(), throwsStateError);
    expect(_interrupted(running), isFalse);
    _emit(running, 'ra1');
    _finish(running);
    await a1.done;
    expect(await a1.turn.end, TurnEnd.endOfSequence);

    // Two streams made before either is listened to: the second is refused
    // when it is.
    await a.addQueryChunk(const Message(text: 'a2', isUser: true));
    final first = a.getResponseAsync();
    final second = a.getResponseAsync();
    final firstText = <String>[];
    final firstDone = first.forEach(firstText.add);
    await expectLater(second.toList(), throwsStateError);
    final call = await _call(2);
    expect(_contents(call), ['user:a1', 'assistant:ra1', 'user:a2']);
    _emit(call, 'ra2');
    _finish(call);
    await firstDone;
    expect(firstText, ['ra2']);

    // Right after a turn ends, from its done, the next one starts.
    await a.addQueryChunk(const Message(text: 'a3', isUser: true));
    final next = Completer<String>();
    a.getResponseAsync().listen(
      (_) {},
      onDone: () => next.complete(a.getResponse()),
    );
    final third = await _call(3);
    _finish(third);
    final fourth = await _call(4);
    _emit(fourth, 'r');
    _finish(fourth);
    expect(await next.future, 'r');

    // A stop of a waiting turn frees the session at once.
    final b = await model.openSession();
    final b1 = await _ask(b, 'b1');
    final bRunning = await _call(5);
    final a4 = await _ask(a, 'a4');
    await pumpEventQueue();
    await a.stopGeneration();
    await a4.done;
    final a5 = await _ask(a, 'a5');
    _finish(bRunning);
    await b1.done;
    final aNext = await _call(6);
    expect(_contents(aNext).last, 'user:a5');
    _finish(aNext);
    await a5.done;
    await model.close();
  });

  test('after a stop or a cancel the next turn starts at once and waits for '
      'the stopped generation to settle', () async {
    _tf['holdOnInterrupt'] = true.toJS;
    final model = _model();
    final a = await model.openSession(systemInstruction: 'A');

    // A cancelled subscription, after a chunk.
    await a.addQueryChunk(const Message(text: 'a1', isUser: true));
    final t1 = _turn(a);
    final sub = t1.text.listen((_) {});
    final c1 = await _call(1);
    _emit(c1, 'part');
    await pumpEventQueue();
    await sub.cancel();
    expect(await t1.end, TurnEnd.stopped);
    expect(_interrupted(c1), isTrue);
    // Not refused, though the generation has not settled yet.
    final a2 = await _ask(a, 'a2');
    await pumpEventQueue();
    expect(_calls, hasLength(1), reason: 'a2 waits for a1 to settle');
    _finish(c1);
    final c2 = await _call(2);
    expect(_contents(c2), ['system:A', 'user:a1', 'assistant:part', 'user:a2']);
    _emit(c2, 'ra2');
    _finish(c2);
    await a2.done;

    // stopGeneration before the first chunk: the stopped turn leaves no
    // trace, and the next turn's message, added while it settled, stays.
    final a3 = await _ask(a, 'a3');
    final c3 = await _call(3);
    await a.stopGeneration();
    // The stopped turn's text ends when its generation settles; the next turn
    // does not wait for that to start.
    final a4 = await _ask(a, 'a4');
    await pumpEventQueue();
    expect(_calls, hasLength(3));
    _finish(c3);
    await a3.done;
    expect(await a3.turn.end, TurnEnd.stopped);
    final c4 = await _call(4);
    expect(_contents(c4), [
      'system:A',
      'user:a1',
      'assistant:part',
      'user:a2',
      'assistant:ra2',
      'user:a4',
    ]);
    _emit(c4, 'ra4');
    _finish(c4);
    await a4.done;

    // A stopped turn with a partial reply, then the next one stopped empty
    // while the first settles: each keeps to its own message.
    final a5 = await _ask(a, 'a5');
    final c5 = await _call(5);
    _emit(c5, 'p5');
    await pumpEventQueue();
    await a.stopGeneration();
    final a6 = await _ask(a, 'a6');
    await pumpEventQueue();
    _finish(c5);
    await a5.done;
    final c6 = await _call(6);
    await a.stopGeneration();
    _finish(c6);
    await a6.done;
    expect(await a6.turn.end, TurnEnd.stopped);

    // A turn that completes naturally with nothing keeps its input, as core
    // does, but records no empty assistant message.
    final a7 = await _ask(a, 'a7');
    _finish(await _call(7));
    await a7.done;

    final a8 = await _ask(a, 'a8');
    final c8 = await _call(8);
    expect(_contents(c8).sublist(7), [
      'user:a5',
      'assistant:p5',
      'user:a7',
      'user:a8',
    ]);
    _finish(c8);
    await a8.done;
    await model.close();
  });

  test(
    'tokens emitted after a stop or cancel do not enter session history',
    () async {
      _tf['holdOnInterrupt'] = true.toJS;
      final model = _model();
      final session = await model.openSession(systemInstruction: 'A');

      final first = await _ask(session, 'a1');
      final firstCall = await _call(1);
      _emit(firstCall, 'visible');
      await pumpEventQueue();
      await session.stopGeneration();
      _emit(firstCall, 'hidden');
      _finish(firstCall);
      await first.done;
      expect(first.text, ['visible']);

      final second = await _ask(session, 'a2');
      final secondCall = await _call(2);
      expect(_contents(secondCall), [
        'system:A',
        'user:a1',
        'assistant:visible',
        'user:a2',
      ]);
      _emit(secondCall, 'r2');
      _finish(secondCall);
      await second.done;

      await session.addQueryChunk(const Message(text: 'a3', isUser: true));
      final third = _turn(session);
      final thirdSub = third.text.listen((_) {});
      final thirdCall = await _call(3);
      await thirdSub.cancel();
      expect(await third.end, TurnEnd.stopped);
      _emit(thirdCall, 'hidden-before-first-visible-token');
      _finish(thirdCall);

      final fourth = await _ask(session, 'a4');
      final fourthCall = await _call(4);
      expect(_contents(fourthCall), [
        'system:A',
        'user:a1',
        'assistant:visible',
        'user:a2',
        'assistant:r2',
        'user:a4',
      ]);
      _finish(fourthCall);
      await fourth.done;
      await model.close();
    },
  );

  test(
    'a cancelled queued token is not committed to session history',
    () async {
      _tf['holdOnInterrupt'] = true.toJS;
      final model = _model();
      final session = await model.openSession(systemInstruction: 'A');

      await session.addQueryChunk(const Message(text: 'a1', isUser: true));
      final first = _turn(session);
      final delivered = <String>[];
      final firstDelivered = Completer<void>();
      late final StreamSubscription<String> subscription;
      late Future<void> cancellation;
      late final JSObject firstCall;
      subscription = first.text.listen((text) {
        delivered.add(text);
        if (text == 'visible') {
          subscription.pause();
          _emit(firstCall, 'queued-but-cancelled');
          cancellation = subscription.cancel();
          firstDelivered.complete();
        }
      });
      firstCall = await _call(1);
      _emit(firstCall, 'visible');
      await firstDelivered.future;
      await cancellation;
      expect(delivered, ['visible']);
      expect(await first.end, TurnEnd.stopped);
      _finish(firstCall);

      final second = await _ask(session, 'a2');
      final secondCall = await _call(2);
      expect(_contents(secondCall), [
        'system:A',
        'user:a1',
        'assistant:visible',
        'user:a2',
      ]);
      _finish(secondCall);
      await second.done;
      await model.close();
    },
  );

  test(
    'a paused stop drops queued text and frees the next turn before resume',
    () async {
      _tf['holdOnInterrupt'] = true.toJS;
      final model = _model();
      final session = await model.openSession(systemInstruction: 'A');

      await session.addQueryChunk(const Message(text: 'a1', isUser: true));
      final first = _turn(session);
      final delivered = <String>[];
      final visible = Completer<void>();
      final firstDone = Completer<void>();
      late final StreamSubscription<String> subscription;
      subscription = first.text.listen((text) {
        delivered.add(text);
        if (text == 'visible') visible.complete();
      }, onDone: firstDone.complete);
      final firstCall = await _call(1);
      _emit(firstCall, 'visible');
      await visible.future;
      subscription.pause();
      _emit(firstCall, 'queued-before-stop');
      await pumpEventQueue();

      await session.stopGeneration();
      expect(_interrupted(firstCall), isTrue);
      _finish(firstCall);

      final second = await _ask(session, 'a2');
      final secondCall = await _call(2);
      expect(_contents(secondCall), [
        'system:A',
        'user:a1',
        'assistant:visible',
        'user:a2',
      ]);
      _finish(secondCall);
      await second.done;

      subscription.resume();
      await firstDone.future;
      expect(delivered, ['visible']);
      expect(await first.end, TurnEnd.stopped);
      await model.close();
    },
  );

  test('model close does not wait for a paused turn to resume', () async {
    _tf['holdOnInterrupt'] = true.toJS;
    final model = _model();
    final session = await model.openSession();
    await session.addQueryChunk(const Message(text: 'a1', isUser: true));
    final turn = _turn(session);
    final delivered = <String>[];
    final visible = Completer<void>();
    final turnDone = Completer<void>();
    late final StreamSubscription<String> subscription;
    subscription = turn.text.listen((text) {
      delivered.add(text);
      if (text == 'visible') visible.complete();
    }, onDone: turnDone.complete);
    final call = await _call(1);
    _emit(call, 'visible');
    await visible.future;
    subscription.pause();
    _emit(call, 'queued-before-close');
    await pumpEventQueue();

    final closing = model.close();
    expect(_interrupted(call), isTrue);
    _finish(call);
    await closing.timeout(const Duration(seconds: 5));

    subscription.resume();
    await turnDone.future;
    expect(delivered, ['visible']);
    expect(await turn.end, TurnEnd.closed);
  });

  test('a close during a streaming turn releases the pipeline once, after its '
      'Promise settles', () async {
    final model = _model();
    final session = await model.openSession();
    _tf['holdOnInterrupt'] = true.toJS;
    final turn = await _ask(session, 'hi');
    final call = await _call(1);
    _emit(call, 'streaming');
    await pumpEventQueue();
    expect(turn.text, ['streaming']);

    // The close arrives mid-stream: the generation is interrupted but its
    // Promise has not settled yet, so the pipeline must not be released.
    final closing = model.close();
    await pumpEventQueue();
    expect(_interrupted(call), isTrue);
    expect((_tf['disposes']! as JSNumber).toDartInt, 0);

    _finish(call);
    await closing.timeout(const Duration(seconds: 5));
    await turn.done;

    expect((_tf['disposes']! as JSNumber).toDartInt, 1);
    expect((_tf['disposedWithPendingCalls']! as JSBoolean).toDart, isFalse);
    await model.close();
    expect((_tf['disposes']! as JSNumber).toDartInt, 1);
  });

  test('a pipeline that fails to release does not fail close', () async {
    _tf['failDispose'] = true.toJS;
    final model = _model();
    await model.openSession();
    await model.close().timeout(const Duration(seconds: 5));
    expect((_tf['disposes']! as JSNumber).toDartInt, 1);
  });

  test('a model that never loaded a pipeline releases nothing', () async {
    final model = _model();
    await model.close();
    expect((_tf['disposes']! as JSNumber).toDartInt, 0);
  });

  test('an unlistened turn does not hold model close', () async {
    final model = _model();
    final session = await model.openSession();
    await session.addQueryChunk(const Message(text: 'unused', isUser: true));
    session.getResponseAsync();

    await model.close().timeout(const Duration(seconds: 5));
    expect(_calls, isEmpty);
  });

  test('openChat keeps input after a natural empty completion', () async {
    _tf['holdOnInterrupt'] = true.toJS;
    final model = _model();
    final blocker = await model.openSession();
    final chat = await model.openChat();

    final blocked = await _ask(blocker, 'block');
    final blockingCall = await _call(1);
    await blocker.stopGeneration();

    await chat.addQuery(const Message(text: 'empty', isUser: true));
    final empty = chat.generateChatResponse();
    await pumpEventQueue();
    expect(_calls, hasLength(1), reason: 'chat waits for the stop to settle');
    _finish(blockingCall);
    await blocked.done;

    final emptyCall = await _call(2);
    _finish(emptyCall);
    expect(((await empty) as TextResponse).token, isEmpty);
    expect(chat.fullHistory.map((message) => message.text), ['empty']);

    await chat.addQuery(const Message(text: 'next', isUser: true));
    final next = chat.generateChatResponse();
    final nextCall = await _call(3);
    expect(_contents(nextCall), ['user:empty', 'user:next']);
    _emit(nextCall, 'answer');
    _finish(nextCall);
    expect(((await next) as TextResponse).token, 'answer');
    await chat.close();
    await model.close();
  });

  test('a turn stopped empty drops every user message of its input, also '
      'those added while it waited', () async {
    final model = _model();
    final a = await model.openSession(systemInstruction: 'A');
    final b = await model.openSession();
    final b1 = await _ask(b, 'b1');
    final bRunning = await _call(1);

    await a.addQueryChunk(const Message(text: 'a1', isUser: true));
    final a2 = await _ask(a, 'a2');
    await pumpEventQueue();
    // Added while the turn waits: it is in the turn's snapshot.
    await a.addQueryChunk(const Message(text: 'a3', isUser: true));
    _finish(bRunning);
    await b1.done;
    final aRunning = await _call(2);
    expect(_contents(aRunning), ['system:A', 'user:a1', 'user:a2', 'user:a3']);
    await a.stopGeneration();
    await a2.done;
    expect(await a2.turn.end, TurnEnd.stopped);

    final a4 = await _ask(a, 'a4');
    final next = await _call(3);
    expect(_contents(next), ['system:A', 'user:a4']);
    _finish(next);
    await a4.done;
    await model.close();
  });

  test(
    'a failed turn leaves no trace in the history, even after a chunk',
    () async {
      final model = _model();
      final a = await model.openSession(systemInstruction: 'A');
      final a1 = await _ask(a, 'a1');
      final call = await _call(1);
      _emit(call, 'part');
      await pumpEventQueue();
      _fail(call);
      await expectLater(a1.done, throwsA(anything));

      final a2 = await _ask(a, 'a2');
      final next = await _call(2);
      expect(_contents(next), ['system:A', 'user:a2']);
      _finish(next);
      await a2.done;
      await model.close();
    },
  );

  test(
    'an error while paused drops queued text before the session moves on',
    () async {
      final model = _model();
      final session = await model.openSession(systemInstruction: 'A');
      await session.addQueryChunk(const Message(text: 'a1', isUser: true));
      final first = _turn(session);
      final delivered = <String>[];
      final errors = <Object>[];
      final visible = Completer<void>();
      final firstDone = Completer<void>();
      late final StreamSubscription<String> subscription;
      subscription = first.text.listen(
        (text) {
          delivered.add(text);
          if (text == 'visible') visible.complete();
        },
        onError: (Object error) => errors.add(error),
        onDone: firstDone.complete,
      );
      final firstCall = await _call(1);
      _emit(firstCall, 'visible');
      await visible.future;
      subscription.pause();
      _emit(firstCall, 'queued-before-error');
      await pumpEventQueue();
      _fail(firstCall);
      await pumpEventQueue();

      final second = await _ask(session, 'a2');
      final secondCall = await _call(2);
      expect(_contents(secondCall), ['system:A', 'user:a2']);
      _finish(secondCall);
      await second.done;

      subscription.resume();
      await firstDone.future;
      expect(delivered, ['visible']);
      expect(errors, hasLength(1));
      await model.close();
    },
  );

  test('a generation that fails after a stop is printed, not only reported '
      'as the stop', () async {
    final printed = <String>[];
    await runZoned(
      () async {
        _tf['rejectOnInterrupt'] = true.toJS;
        final model = _model();
        final a = await model.openSession();
        final a1 = await _ask(a, 'a1');
        final call = await _call(1);
        _emit(call, 'part');
        await pumpEventQueue();
        await a.stopGeneration();
        await a1.done;
        expect(await a1.turn.end, TurnEnd.stopped);
        await model.close();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    expect(printed, contains(contains('stopped web generation then failed')));
  });

  test('a failed pipeline load or rejected sampling values free the cap '
      'slot', () async {
    final model = _model(cap: 1);
    await expectLater(
      model.openSession(temperature: -1),
      throwsA(isA<ArgumentError>()),
    );
    // webgpu, then the wasm retry.
    _tf['failures'] = 2.toJS;
    await expectLater(model.openSession(), throwsA(anything));
    await model.openSession();
    expect(model.sessions, hasLength(1));
    await model.close();
  });

  test("openChat takes the model's own type (D8): a Qwen3 repo gets "
      "/no_think and its thinking is not the answer", () async {
    final model = _model(modelType: ModelType.qwen3);
    final chat = await model.openChat();
    expect(chat.modelType, ModelType.qwen3);
    expect(chat.supportImage, isFalse);
    await chat.addQuery(const Message(text: 'hi', isUser: true));
    final responses = <ModelResponse>[];
    final done = chat.generateChatResponseAsync().forEach(responses.add);
    final call = await _call(1);
    expect(_contents(call).last, 'user:hi /no_think');
    _emit(call, '<think>');
    _emit(call, 'hmm');
    _emit(call, '</think>');
    _emit(call, 'Hello');
    _finish(call);
    await done;
    final answer = responses.whereType<TextResponse>().map((r) => r.token);
    expect(answer.join(), isNot(contains('think')));
    expect(answer.join(), contains('Hello'));
    await chat.close();
    await model.close();
  });

  test('closing the model closes every open session; a turn it cuts is '
      'reported closed, with its partial text', () async {
    final model = _model();
    final a = await model.openSession();
    final b = await model.openSession();
    final a1 = await _ask(a, 'a1');
    final running = await _call(1);
    _emit(running, 'part');
    await pumpEventQueue();

    await model.close();
    expect(_interrupted(running), isTrue);
    await a1.done;
    expect(a1.text, ['part']);
    expect(await a1.turn.end, TurnEnd.closed);
    expect(model.sessions, isEmpty);
    for (final s in [a, b]) {
      await expectLater(
        s.addQueryChunk(const Message(text: 'x', isUser: true)),
        throwsStateError,
      );
    }
    await expectLater(model.openSession(), throwsStateError);
  });

  test('model close waits for the active generation to settle and fails a '
      'queued chat immediately', () async {
    _tf['holdOnInterrupt'] = true.toJS;
    var ownerCloseCalls = 0;
    var listenerCalls = 0;
    final model = _model(onClose: () => ownerCloseCalls++);
    model.addCloseListener(() => listenerCalls++);
    final active = await model.openSession();
    final queued = await model.openChat();

    final activeTurn = await _ask(active, 'active');
    final activeCall = await _call(1);
    await queued.addQuery(const Message(text: 'queued', isUser: true));
    final queuedReply = queued.generateChatResponse();
    final queuedClosed = expectLater(queuedReply, throwsStateError);
    await pumpEventQueue();
    expect(_calls, hasLength(1));

    var closeCompleted = false;
    final closing = model.close().then((_) => closeCompleted = true);
    await pumpEventQueue();
    expect(_interrupted(activeCall), isTrue);
    await queuedClosed.timeout(const Duration(seconds: 5));
    expect(_calls, hasLength(1), reason: 'the queued turn never generates');
    expect(closeCompleted, isFalse);
    expect(ownerCloseCalls, 0);
    expect(listenerCalls, 0);

    _finish(activeCall);
    await activeTurn.done;
    expect(await activeTurn.turn.end, TurnEnd.closed);
    await closing;
    expect(closeCompleted, isTrue);
    expect(ownerCloseCalls, 1);
    expect(listenerCalls, 1);
  });

  test('a model closed while openSession waits for the pipeline fails the '
      'open', () async {
    final gate = Completer<void>();
    _tf['gate'] = gate.future.toJS;
    final model = _model();
    final open = model.openSession();
    // Listened to at once: the open fails as soon as the load ends.
    final openFails = expectLater(open, throwsStateError);
    await pumpEventQueue();
    var closeCompleted = false;
    final closing = model.close().whenComplete(() => closeCompleted = true);
    await pumpEventQueue();
    // close() waits for the load instead of returning with it still running.
    expect(closeCompleted, isFalse);
    expect((_tf['disposes']! as JSNumber).toDartInt, 0);
    gate.complete();
    await closing;
    // By the time close() returns, the pipeline that finished loading after
    // it started is released, not kept.
    expect((_tf['pipelines']! as JSNumber).toDartInt, 1);
    expect((_tf['disposes']! as JSNumber).toDartInt, 1);
    await openFails;
    expect(model.sessions, isEmpty);
  });

  test('a model closed while its pipeline load fails still closes, '
      'releasing nothing', () async {
    final gate = Completer<void>();
    _tf['gate'] = gate.future.toJS;
    _tf['failures'] = 2.toJS; // webgpu, then the wasm retry
    final model = _model();
    final openFails = expectLater(model.openSession(), throwsA(anything));
    await pumpEventQueue();
    final closing = model.close();
    gate.complete();
    await closing;
    await openFails;
    expect((_tf['pipelines']! as JSNumber).toDartInt, 2);
    expect((_tf['disposes']! as JSNumber).toDartInt, 0);
  });

  test('a response format is refused on the web, saying why, before any '
      'session opens', () async {
    final model = _model();
    expect(model.structuredOutputSupport.isSupported, isFalse);
    expect(model.structuredOutputSupport.reason, contains('Transformers.js'));
    final format = ResponseFormat.jsonObject();
    for (final open in [
      () => model.openSession(responseFormat: format),
      () => model.openChat(responseFormat: format),
    ]) {
      await expectLater(
        open(),
        throwsA(
          isA<ResponseFormatUnsupportedException>().having(
            (e) => e.toString(),
            'message',
            contains('Transformers.js'),
          ),
        ),
      );
    }
    expect(model.sessions, isEmpty);
    expect((_tf['pipelines']! as JSNumber).toDartInt, 0);
    await model.close();
  });

  test(
    'the engine hands RuntimeConfig.maxConcurrentSessions to the model',
    () async {
      final model = await const OnnxEngine().createModel(
        InferenceModelSpec(
          name: 'repo',
          modelSource: NetworkSource('https://huggingface.co/owner/repo'),
          modelType: ModelType.general,
          fileType: ModelFileType.onnx,
        ),
        const RuntimeConfig(
          modelPath: '',
          maxTokens: 1024,
          maxConcurrentSessions: 3,
        ),
      );
      expect((model as OnnxWebInferenceModel).maxConcurrentSessions, 3);
      await model.close();
    },
  );
}
