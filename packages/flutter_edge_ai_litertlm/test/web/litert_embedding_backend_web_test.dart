// The web `LiteRtEmbeddingBackend`: what it claims and what describe() hands
// core. Web routing is on the spec — the web arm claims only two-file specs, so
// a `.litertlm` bundle is refused by `installEmbedder()` before any download.
// The paths are `opfs://`, as under WebStorageMode.streaming: describe() must
// wire the real resolver, and the pass must hand the bundle resolved URLs
// (this suite used to feed `blob:` paths and stayed green while every
// streaming-mode LiteRT.js embedder failed to load).
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_embedding_backend_web_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_backend_web.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_js_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_web_embeddings.dart';
import 'package:flutter_test/flutter_test.dart';

final _tflite = EmbeddingModelSpec(
  name: 'embeddinggemma',
  modelSource: ModelSource.network('https://example.com/gemma.tflite'),
  tokenizerSource: ModelSource.network('https://example.com/t.model'),
);

RuntimeConfig _config({bool supportImage = false, bool supportAudio = false}) =>
    RuntimeConfig(
      maxTokens: 0,
      modelPath: 'opfs://gemma.tflite',
      tokenizerPath: 'opfs://t.model',
      supportImage: supportImage,
      supportAudio: supportAudio,
    );

void main() {
  const backend = LiteRtEmbeddingBackend();

  test('claims a two-file spec, never a .litertlm bundle', () {
    expect(backend.canHandle(_tflite), isTrue);
    expect(
      backend.canHandle(
        EmbeddingModelSpec(
          name: 'eg2',
          modelSource: ModelSource.network('https://example.com/eg2.litertlm'),
        ),
      ),
      isFalse,
    );
  });

  test('describe() hands core the LiteRT.js pass over the raw paths with the '
      'real resolver and bundle, and no backend claimed', () async {
    final descriptor = await backend.describe(_tflite, _config());
    final config = descriptor.config as LiteRtJsEmbeddingConfig;

    expect(descriptor.engineTag, 'LiteRT.js');
    expect(config.modelPath, 'opfs://gemma.tflite');
    expect(config.tokenizerPath, 'opfs://t.model');
    expect(config.resolveUrl == resolveWebModelUrl, isTrue);
    expect(config.revokeUrl == revokeObjectUrl, isTrue);
    expect(config.bundle, isA<WindowLiteRtJsBundle>());
    expect(descriptor.activeBackend, isNull, reason: 'unknown, never CPU');
    expect(descriptor.build(), isA<LiteRtJsEmbeddingPass>());
  });

  test('the bundle\'s loadLiteRtEmbeddings receives resolved URLs for both '
      'opfs:// paths', () async {
    final received = <String>[];
    final revoked = <String>[];
    globalContext['liteRtEmbeddingsApiVersion'] = 2.toJS;
    globalContext['loadLiteRtEmbeddings'] =
        ((JSString model, JSString tokenizer, JSAny? wasm) {
          received
            ..add(model.toDart)
            ..add(tokenizer.toDart);
          final info = JSObject()
            ..['dimension'] = 4.toJS
            ..['maxInputTokens'] = 64.toJS;
          return Future<JSObject>.value(info).toJS;
        }).toJS;
    globalContext['cleanupLiteRtEmbeddings'] = (() {
      return Future<void>.value().toJS;
    }).toJS;

    final described =
        (await backend.describe(_tflite, _config())).config
            as LiteRtJsEmbeddingConfig;
    // The real resolver needs streaming storage set up; this one does what it
    // does to an opfs:// path.
    final pass = LiteRtJsEmbeddingPass(
      LiteRtJsEmbeddingConfig(
        modelPath: described.modelPath,
        tokenizerPath: described.tokenizerPath,
        bundle: described.bundle,
        resolveUrl: (path) async =>
            'blob:resolved/${path.substring('opfs://'.length)}',
        revokeUrl: revoked.add,
      ),
    );

    await pass.load();
    expect(received, ['blob:resolved/gemma.tflite', 'blob:resolved/t.model']);
    expect(
      revoked,
      unorderedEquals(received),
      reason: 'the pass created both URLs, so it releases both',
    );
    await pass.close();
  });

  test('describe() refuses declared images or audio', () async {
    for (final (image, audio) in [(true, false), (false, true)]) {
      await expectLater(
        backend.describe(
          _tflite,
          _config(supportImage: image, supportAudio: audio),
        ),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            'gemma.tflite is a text-only model',
          ),
        ),
      );
    }
  });
}
