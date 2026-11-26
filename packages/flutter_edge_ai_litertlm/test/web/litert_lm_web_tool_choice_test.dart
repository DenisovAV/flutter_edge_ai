// Core's ToolChoice on a web `.litertlm` session: none creates the runtime's
// conversation without the tools, so the model never sees them, as natively;
// auto and required keep them (the page's @litert-lm/core 0.20.0 takes no
// per-message tool choice); required without tools is refused. The legacy
// createChat maps it the same way.
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

/// A model over a stub runtime; [options] collects each conversation's
/// create options.
LiteRtLmWebInferenceModel _model(ModelType modelType, List<Object?> options) {
  final engine = _runtimeEngine((o) {
    options.add(o.dartify());
    return Future<JSObject>.value(_conversation()).toJS;
  });
  globalContext['litertLmReady'] = Future<void>.value().toJS;
  globalContext['litertLm'] = JSObject()
    ..['Engine'] = _engineConstructor(engine)
    ..['Backend'] = {'GPU_ARTISAN': 1, 'CPU': 2, 'GPU': 3}.jsify();
  final model = LiteRtLmWebInferenceModel(
    createEngine: () => createLiteRtLmWebEngine(_Resolver(), maxTokens: 1024),
    maxTokens: 1024,
    modelType: modelType,
    onClose: () {},
  );
  addTearDown(model.close);
  return model;
}

bool _hasTools(Object? options) =>
    ((options! as Map)['preface'] as Map).containsKey('tools');

void main() {
  for (final (choice, expectTools) in [
    (ToolChoice.auto, true),
    (ToolChoice.none, false),
  ]) {
    test('$choice: the runtime conversation is created '
        '${expectTools ? 'with' : 'without'} the tools', () async {
      final options = <Object?>[];
      final session = await _model(
        ModelType.gemma4,
        options,
      ).openEngineSession(SessionRequest(tools: _tools, toolChoice: choice));
      addTearDown(session.close);
      expect(_hasTools(options.single), expectTools);
    });
  }

  test('required on Gemma 4 opens with the tools (the runtime takes no '
      'per-message choice)', () async {
    final options = <Object?>[];
    final session = await _model(ModelType.gemma4, options).openEngineSession(
      SessionRequest(tools: _tools, toolChoice: ToolChoice.required),
    );
    addTearDown(session.close);
    expect(_hasTools(options.single), isTrue);
  });

  test('required on a model with core\'s tools prompt opens', () async {
    final options = <Object?>[];
    final session = await _model(ModelType.gemmaIt, options).openEngineSession(
      SessionRequest(tools: _tools, toolChoice: ToolChoice.required),
    );
    addTearDown(session.close);
    expect(options, hasLength(1));
  });

  test('required without tools is an ArgumentError', () async {
    await expectLater(
      _model(
        ModelType.gemmaIt,
        [],
      ).openEngineSession(SessionRequest(toolChoice: ToolChoice.required)),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('the legacy createChat maps the choice: none drops the tools, '
      'required without tools is refused', () async {
    final options = <Object?>[];
    final model = _model(ModelType.gemma4, options);
    // ignore: deprecated_member_use
    await model.createChat(
      tools: _tools,
      modelType: ModelType.gemma4,
      toolChoice: ToolChoice.none,
    );
    expect(_hasTools(options.single), isFalse);
    await expectLater(
      // ignore: deprecated_member_use
      model.createChat(
        modelType: ModelType.gemma4,
        toolChoice: ToolChoice.required,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
