// Two web `.litertlm` openSession calls that overlap must not both pass
// maxConcurrentSessions: the check runs before the engine and the
// conversation are created, both of which await.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_open_session_cap_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/web_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/web/web_llm_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolves the active model to a blob URL; nothing is read from it.
class _Resolver implements WebModelSourceResolver {
  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async =>
      (model: const BlobUrlModelSource('blob:fake'), loraPath: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A stand-in for `window.Engine`: a function (as the page's is) with the
/// 0.19.0 `createExclusive` the version check looks for, whose `create`
/// returns [engine].
JSObject _engineConstructor(JSObject engine) =>
    (globalContext.callMethod<JSObject>(
        'eval'.toJS,
        '(function Engine() {})'.toJS,
      ))
      ..['createExclusive'] = (() {}).toJS
      ..['create'] = ((JSAny? options) => Future<JSObject>.value(
        engine,
      ).toJS).toJS;

void main() {
  test('two openSession calls that overlap cannot both pass '
      'maxConcurrentSessions, and a failed one frees its slot', () async {
    var conversations = 0;
    var gate = Completer<void>();
    var failNext = false;
    final engine = JSObject()
      ..['createConversation'] = ((JSAny? options) {
        conversations++;
        final fail = failNext;
        failNext = false;
        return gate.future.then<JSObject>((_) {
          if (fail) throw StateError('createConversation failed');
          return JSObject()
            ..['cancel'] = (() {}).toJS
            ..['delete'] = (() => Future<void>.value().toJS).toJS;
        }).toJS;
      }).toJS
      ..['delete'] = (() => Future<void>.value().toJS).toJS;
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    globalContext['Engine'] = _engineConstructor(engine);

    final model = LiteRtLmWebInferenceModel(
      createEngine: () => createLiteRtLmWebEngine(_Resolver(), maxTokens: 1024),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      maxConcurrentSessions: 1,
      onClose: () {},
    );
    final first = model.openSession();
    // The first is still creating its conversation when the second checks.
    await expectLater(model.openSession(), throwsStateError);
    gate.complete();
    await first;
    expect(model.sessions, hasLength(1));
    expect(conversations, 1);

    await model.sessions.single.close();
    gate = Completer<void>()..complete();
    failNext = true;
    await expectLater(model.openSession(), throwsA(anything));
    await model.openSession();
    expect(model.sessions, hasLength(1));
  });

  test('a model closed while openSession builds its conversation deletes '
      'that conversation and fails the open', () async {
    final gate = Completer<void>();
    var deleted = 0;
    final engine = JSObject()
      ..['createConversation'] =
          ((JSAny? options) => gate.future
                  .then<JSObject>(
                    (_) => JSObject()
                      ..['cancel'] = (() {}).toJS
                      ..['delete'] = (() {
                        deleted++;
                        return Future<void>.value().toJS;
                      }).toJS,
                  )
                  .toJS)
              .toJS
      ..['delete'] = (() => Future<void>.value().toJS).toJS;
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    globalContext['Engine'] = _engineConstructor(engine);

    final model = LiteRtLmWebInferenceModel(
      createEngine: () => createLiteRtLmWebEngine(_Resolver(), maxTokens: 1024),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      onClose: () {},
    );
    final open = model.openSession();
    await pumpEventQueue();
    // close() waits for the conversation being created: it finishes once the
    // runtime answers, and is deleted rather than handed out.
    final opened = expectLater(open, throwsStateError);
    final closing = model.close();
    gate.complete();
    await closing;
    await opened;
    expect(deleted, 1);
    expect(model.sessions, isEmpty);
  });
}
