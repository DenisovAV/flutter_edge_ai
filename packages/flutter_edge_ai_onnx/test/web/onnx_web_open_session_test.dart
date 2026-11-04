// ONNX web `openSession` (#703): further `OnnxWebSession`s on the one
// Transformers.js pipeline, each with its own history, capped by
// `maxConcurrentSessions`, all closed with the model; a stop reaches only its
// own session's turn, and `startTurn` reports a stop and a close.
//
// Runs over a JS fake of `window.transformers` (a pipeline whose calls the
// test answers chunk by chunk), so no model and no WebGPU are needed. Run:
//   flutter test --platform chrome test/web/onnx_web_open_session_test.dart
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
/// then fails while `__tf.failures` is above zero (one per call).
const _fakeTransformers = r'''
(() => {
  const tf = { calls: [], gate: Promise.resolve(), pipelines: 0, failures: 0 };
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
      return new Promise((resolve) => {
        options.stopping_criteria.onInterrupt = resolve;
        tf.calls.push({ messages, options, resolve });
      });
    };
    pipe.tokenizer = { encode: (text) => Array.from(text) };
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
}) => OnnxWebInferenceModel(
  resolver: _Resolver(),
  maxTokens: 1024,
  modelType: modelType,
  maxConcurrentSessions: cap,
  onClose: () {},
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

    // Stopped while waiting behind B.
    final b1 = await _ask(b, 'b1');
    final bRunning = await _call(1);
    final a1 = await _ask(a, 'a1');
    await pumpEventQueue();
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

  test('cancelling a waiting turn never interrupts the running turn of the '
      'same session', () async {
    final model = _model();
    final a = await model.openSession();
    final a1 = await _ask(a, 'a1');
    final running = await _call(1);
    await a.addQueryChunk(const Message(text: 'a2', isUser: true));
    final waiting = _turn(a).text.listen((_) {});
    await pumpEventQueue();
    await waiting.cancel();
    expect(_interrupted(running), isFalse);
    _emit(running, 'ra1');
    _finish(running);
    await a1.done;
    expect(a1.text, ['ra1']);
    expect(await a1.turn.end, TurnEnd.endOfSequence);
    await model.close();
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

  test('a model closed while openSession waits for the pipeline fails the '
      'open', () async {
    final gate = Completer<void>();
    _tf['gate'] = gate.future.toJS;
    final model = _model();
    final open = model.openSession();
    await pumpEventQueue();
    await model.close();
    gate.complete();
    await expectLater(open, throwsStateError);
    expect(model.sessions, isEmpty);
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
