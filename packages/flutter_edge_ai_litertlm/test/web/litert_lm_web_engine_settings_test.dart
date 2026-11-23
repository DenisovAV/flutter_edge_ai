// What the adapter's web engine (lib/src/web/web_llm_engine.dart) hands
// `@litert-lm/core`'s Engine.create for core's runtime config: the GPU, the
// context, and with supportImage / supportAudio the vision encoder on the GPU
// and the audio encoder on the CPU, the images a conversation reserves.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_engine_settings_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine_web.dart';
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

/// Installs a `window.Engine` that records its settings and resolves as
/// 0.19.0 does for Gemma 4 E2B's GPU export; returns the recorded settings.
List<Map<String, Object?>> _installEngine() {
  final settings = <Map<String, Object?>>[];
  final engine = JSObject()
    ..['settings'] = {
      'backend': 2,
      'mainExecutorSettings': {'maxNumTokens': 8192},
    }.jsify()
    ..['createConversation'] = ((JSAny? _) => Future.value(
      JSObject(),
    ).toJS).toJS
    ..['delete'] = (() => Future<void>.value().toJS).toJS;
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
          settings.add((options.dartify()! as Map).cast<String, Object?>());
          return Future<JSObject>.value(engine).toJS;
        }).toJS;
  globalContext['litertLmReady'] = Future<void>.value().toJS;
  globalContext['Engine'] = constructor;
  return settings;
}

Map<String, Object?> _executor(Map<String, Object?> settings) =>
    (settings['mainExecutorSettings']! as Map).cast<String, Object?>();

void main() {
  test('a text model asks for the GPU and the context, no encoder', () async {
    final settings = _installEngine();

    final engine = await createLiteRtLmWebEngine(_Resolver(), maxTokens: 2048);

    expect(settings.single['backend'], 4);
    expect(settings.single.containsKey('visionBackend'), isFalse);
    expect(settings.single.containsKey('audioBackend'), isFalse);
    expect(_executor(settings.single)['maxNumTokens'], 2048);
    await engine.close();
  });

  test('supportImage loads the vision encoder on the GPU, reserving the '
      'images maxNumImages names', () async {
    final settings = _installEngine();

    final engine = await createLiteRtLmWebEngine(
      _Resolver(),
      maxTokens: 2048,
      supportImage: true,
      maxNumImages: 4,
    );

    expect(settings.single['visionBackend'], 4);
    expect(_executor(settings.single)['maxNumImages'], 4);
    await engine.close();
  });

  test('supportAudio loads the audio encoder on the CPU', () async {
    final settings = _installEngine();

    final engine = await createLiteRtLmWebEngine(
      _Resolver(),
      maxTokens: 2048,
      supportAudio: true,
    );

    expect(settings.single['audioBackend'], 3);
    await engine.close();
  });

  test('maxNumImages without supportImage reserves nothing', () async {
    final settings = _installEngine();

    final engine = await createLiteRtLmWebEngine(
      _Resolver(),
      maxTokens: 2048,
      maxNumImages: 4,
    );

    expect(_executor(settings.single).containsKey('maxNumImages'), isFalse);
    await engine.close();
  });
}
