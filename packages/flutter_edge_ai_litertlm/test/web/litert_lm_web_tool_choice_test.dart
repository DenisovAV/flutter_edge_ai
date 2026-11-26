// Core's ToolChoice.none on a web `.litertlm` session: the runtime's
// conversation is created without the tools, so the model never sees them,
// as natively. auto keeps them.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_tool_choice_test.dart
@TestOn('browser')
library;

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

const _tools = [
  Tool(
    name: 'get_weather',
    description: 'The weather',
    parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
    },
  ),
];

void main() {
  for (final (choice, expectTools) in [
    (ToolChoice.auto, true),
    (ToolChoice.required, true),
    (ToolChoice.none, false),
  ]) {
    test('$choice: the runtime conversation is created '
        '${expectTools ? 'with' : 'without'} the tools', () async {
      final options = <Object?>[];
      final engine = _runtimeEngine((o) {
        options.add(o.dartify());
        return Future<JSObject>.value(_conversation()).toJS;
      });
      globalContext['litertLmReady'] = Future<void>.value().toJS;
      globalContext['litertLm'] = JSObject()
        ..['Engine'] = _engineConstructor(engine)
        ..['Backend'] = {'GPU_ARTISAN': 1, 'CPU': 2, 'GPU': 3}.jsify();
      final model = LiteRtLmWebInferenceModel(
        createEngine: () =>
            createLiteRtLmWebEngine(_Resolver(), maxTokens: 1024),
        maxTokens: 1024,
        modelType: ModelType.gemma4,
        onClose: () {},
      );
      addTearDown(model.close);
      final session = await model.openEngineSession(
        SessionRequest(tools: _tools, toolChoice: choice),
      );
      addTearDown(session.close);
      final preface = (options.single! as Map)['preface'] as Map;
      expect(preface.containsKey('tools'), expectTools);
    });
  }
}
