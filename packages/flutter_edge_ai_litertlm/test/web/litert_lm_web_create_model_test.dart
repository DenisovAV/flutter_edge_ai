// What LiteRtLmEngine.createModel on the web hands the engine it builds from
// core's RuntimeConfig: the context, the encoders and the images a
// conversation reserves, each from its own field.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_create_model_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/web/web_llm_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_web.dart' show webConversationMembers;

/// Resolves the active model to a blob URL; nothing is read from it.
class _Resolver implements WebModelSourceResolver {
  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async =>
      (model: const BlobUrlModelSource('blob:fake'), loraPath: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A `window.Engine` that records its settings and resolves the encoders it
/// was asked for, with conversations that have every member called.
List<Map<String, Object?>> _installEngine() {
  final settings = <Map<String, Object?>>[];
  JSObject conversation() {
    final c = JSObject();
    for (final member in webConversationMembers) {
      c[member] = (() {}).toJS;
    }
    return c;
  }

  final constructor =
      globalContext.callMethod<JSObject>(
          'eval'.toJS,
          '''(() => {
            function Engine() {}
            Engine.prototype.createConversation = function () {};
            Engine.prototype.delete = function () {};
            return Engine;
          })()'''
              .toJS,
        )
        ..['create'] = ((JSAny? options) {
          final asked = (options.dartify()! as Map).cast<String, Object?>();
          settings.add(asked);
          return Future<JSObject>.value(
            JSObject()
              ..['settings'] = {
                'backend': 2,
                'visionBackend': ?asked['visionBackend'],
                'audioBackend': ?asked['audioBackend'],
                'mainExecutorSettings': {'maxNumTokens': 2048},
              }.jsify()
              ..['createConversation'] = ((JSAny? _) => Future<JSObject>.value(
                conversation(),
              ).toJS).toJS
              ..['delete'] = (() => Future<void>.value().toJS).toJS,
          ).toJS;
        }).toJS;
  globalContext['litertLmReady'] = Future<void>.value().toJS;
  // The page's Backend enum, as @litert-lm/core 0.19.0 numbers it.
  globalContext['LiteRtLmBackend'] = {
    'GPU_ARTISAN': 2,
    'CPU': 3,
    'GPU': 4,
  }.jsify();
  globalContext['Engine'] = constructor;
  return settings;
}

final _spec = InferenceModelSpec(
  name: 'gemma-4-E2B-it-gpu.litertlm',
  modelSource: ModelSource.network('https://example.com/gemma.litertlm'),
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
);

/// The settings the engine was created with, once a session needs it.
Future<Map<String, Object?>> _created(RuntimeConfig config) async {
  final settings = _installEngine();
  final model = await const LiteRtLmEngine().createModel(_spec, config);
  final session = await model.createSession();
  await session.close();
  await model.close();
  return settings.single;
}

Map<String, Object?> _executor(Map<String, Object?> settings) =>
    (settings['mainExecutorSettings']! as Map).cast<String, Object?>();

void main() {
  setUp(() => activeWebModelSource = _Resolver.new);
  tearDown(() => activeWebModelSource = WebModelSourceResolver.forActiveModel);

  test('supportImage alone loads the vision encoder with the images it '
      'reserves, and no audio encoder', () async {
    final settings = await _created(
      const RuntimeConfig(
        maxTokens: 2048,
        modelPath: '',
        supportImage: true,
        maxNumImages: 3,
      ),
    );

    expect(settings['visionBackend'], 4);
    expect(settings.containsKey('audioBackend'), isFalse);
    expect(_executor(settings)['maxNumImages'], 3);
    expect(_executor(settings)['maxNumTokens'], 2048);
  });

  test('supportAudio alone loads the audio encoder, no vision encoder and '
      'no image reservation', () async {
    final settings = await _created(
      const RuntimeConfig(
        maxTokens: 4096,
        modelPath: '',
        supportAudio: true,
        maxNumImages: 3,
      ),
    );

    expect(settings['audioBackend'], 3);
    expect(settings.containsKey('visionBackend'), isFalse);
    expect(_executor(settings).containsKey('maxNumImages'), isFalse);
    expect(_executor(settings)['maxNumTokens'], 4096);
  });
}
