// Two web `.litertlm` openSession calls that overlap must not both pass
// maxConcurrentSessions: the check runs before the engine and the
// conversation are created, both of which await.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_lm_web_open_session_cap_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web_inference.dart';
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
          return JSObject()..['cancel'] = (() {}).toJS;
        }).toJS;
      }).toJS
      ..['delete'] = (() {}).toJS;
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    globalContext['Engine'] = JSObject()
      ..['create'] = ((JSAny? options) => Future<JSObject>.value(
        engine,
      ).toJS).toJS;

    final model = LiteRtLmWebInferenceModel(
      sourceResolver: _Resolver(),
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
      ..['delete'] = (() {}).toJS;
    globalContext['litertLmReady'] = Future<void>.value().toJS;
    globalContext['Engine'] = JSObject()
      ..['create'] = ((JSAny? options) => Future<JSObject>.value(
        engine,
      ).toJS).toJS;

    final model = LiteRtLmWebInferenceModel(
      sourceResolver: _Resolver(),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      onClose: () {},
    );
    final open = model.openSession();
    await pumpEventQueue();
    await model.close();
    gate.complete();
    await expectLater(open, throwsStateError);
    expect(deleted, 1);
    expect(model.sessions, isEmpty);
  });
}
