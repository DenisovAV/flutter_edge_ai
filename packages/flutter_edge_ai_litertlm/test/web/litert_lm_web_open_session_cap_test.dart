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

/// A stand-in for the module's `Engine`: a function (as the page's is) with the
/// prototype members the runtime check looks for, whose `create` returns
/// [engine].
JSObject _engineConstructor(JSObject engine) =>
    (globalContext.callMethod<JSObject>(
        'eval'.toJS,
        '''(() => {
          function Engine() {}
          Engine.prototype.createConversation = function () {};
          Engine.prototype.createSession = function () {};
          Engine.prototype.delete = function () {};
          return Engine;
        })()'''
            .toJS,
      ))
      ..['create'] = ((JSAny? options) => Future<JSObject>.value(
        engine,
      ).toJS).toJS;

/// A runtime conversation with the members litertlm_dart calls on 0.20.0;
/// [onDelete] counts its deletes.
JSObject _conversation({void Function()? onDelete}) => JSObject()
  ..['sendMessageStreaming'] = ((JSAny? message) => JSObject()).toJS
  ..['cancel'] = (() {}).toJS
  ..['getHistory'] = (() => Future.value(JSArray<JSObject>()).toJS).toJS
  ..['getTokenCount'] = (() => Future.value(0.toJS).toJS).toJS
  ..['clone'] = (() => Future.value(JSObject()).toJS).toJS
  ..['delete'] = (() {
    onDelete?.call();
    return Future<void>.value().toJS;
  }).toJS;

/// A runtime engine as 0.19.0 resolves Gemma 4's GPU export (`GPU_ARTISAN`, the
/// bundle's 4096 tokens), whose conversations come from [createConversation].
JSObject _runtimeEngine(JSAny? Function(JSAny? options) createConversation) =>
    JSObject()
      ..['settings'] = {
        'backend': 2,
        'mainExecutorSettings': {'maxNumTokens': 4096},
      }.jsify()
      ..['createConversation'] = createConversation.toJS
      ..['delete'] = (() => Future<void>.value().toJS).toJS;

void main() {
  test('two openSession calls that overlap cannot both pass '
      'maxConcurrentSessions, and a failed one frees its slot', () async {
    var conversations = 0;
    var gate = Completer<void>();
    var failNext = false;
    final engine = _runtimeEngine((options) {
      conversations++;
      final fail = failNext;
      failNext = false;
      return gate.future.then<JSObject>((_) {
        if (fail) throw StateError('createConversation failed');
        return _conversation();
      }).toJS;
    });
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    // The module's Backend enum, as @litert-lm/core 0.20.0 numbers it.
    globalContext['litertLm'] = JSObject()
      ..['Engine'] = _engineConstructor(engine)
      ..['Backend'] = {'GPU_ARTISAN': 1, 'CPU': 2, 'GPU': 3}.jsify();

    final model = LiteRtLmWebInferenceModel(
      createEngine: () => createLiteRtLmWebEngine(_Resolver(), maxTokens: 1024),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      maxConcurrentSessions: 1,
      onClose: () {},
    );
    final first = model.openSession();
    // The first is still creating its conversation when the second checks.
    await expectLater(
      model.openSession(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Max concurrent sessions (1) reached'),
        ),
      ),
    );
    gate.complete();
    await first;
    expect(model.sessions, hasLength(1));
    expect(conversations, 1);

    await model.sessions.single.close();
    gate = Completer<void>()..complete();
    failNext = true;
    await expectLater(
      model.openSession(),
      throwsA(
        predicate<Object>(
          (e) => '$e'.contains('createConversation failed'),
          'the runtime\'s refusal',
        ),
      ),
    );
    await model.openSession();
    expect(model.sessions, hasLength(1));
  });

  test('a model closed while openSession builds its conversation deletes '
      'that conversation and fails the open', () async {
    final gate = Completer<void>();
    var deleted = 0;
    final engine = _runtimeEngine(
      (options) => gate.future
          .then<JSObject>((_) => _conversation(onDelete: () => deleted++))
          .toJS,
    );
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    // The module's Backend enum, as @litert-lm/core 0.20.0 numbers it.
    globalContext['litertLm'] = JSObject()
      ..['Engine'] = _engineConstructor(engine)
      ..['Backend'] = {'GPU_ARTISAN': 1, 'CPU': 2, 'GPU': 3}.jsify();

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
    final opened = expectLater(
      open,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
    final closing = model.close();
    gate.complete();
    await closing;
    await opened;
    expect(deleted, 1);
    expect(model.sessions, isEmpty);
  });
}
