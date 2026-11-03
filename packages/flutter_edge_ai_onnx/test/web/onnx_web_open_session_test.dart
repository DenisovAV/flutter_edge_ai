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
/// pipeline settles once decoding stops. `pipeline()` waits for `__tf.gate`.
const _fakeTransformers = r'''
(() => {
  const tf = { calls: [], gate: Promise.resolve(), pipelines: 0 };
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

OnnxWebInferenceModel _model({int? cap}) => OnnxWebInferenceModel(
  resolver: _Resolver(),
  maxTokens: 1024,
  modelType: ModelType.general,
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

  test('a stop in one session never cuts another session\'s turn, and '
      'drops its own turn still waiting for the pipeline', () async {
    final model = _model();
    final a = await model.openSession();
    final b = await model.openSession();

    final b1 = await _ask(b, 'b1');
    final running = await _call(1);
    final a1 = await _ask(a, 'a1');
    await pumpEventQueue();
    await a.stopGeneration();
    expect(_interrupted(running), isFalse);
    _emit(running, 'rb1');
    _finish(running);
    await b1.done;
    expect(b1.text, ['rb1']);
    expect(await b1.turn.end, TurnEnd.endOfSequence);
    await a1.done;
    expect(a1.text, isEmpty);
    expect(await a1.turn.end, TurnEnd.stopped);
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
