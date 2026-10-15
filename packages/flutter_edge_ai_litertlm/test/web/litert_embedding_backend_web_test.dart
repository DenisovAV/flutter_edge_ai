// The web `LiteRtEmbeddingBackend`: what it claims and what describe() hands
// core. Web routing is on the spec's file name (the path core resolves is a
// URL): a two-file spec gets the LiteRT.js pass, a `.litertlm` bundle
// (EmbeddingGemma 2, since 1.13.1) the `@litert-lm/core` EmbeddingEngine pass.
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
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_backend_web.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_js_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_web_embeddings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'eg2_header_fixtures.dart';

final _tflite = EmbeddingModelSpec(
  name: 'embeddinggemma',
  modelSource: ModelSource.network('https://example.com/gemma.tflite'),
  tokenizerSource: ModelSource.network('https://example.com/t.model'),
);

final _eg2 = EmbeddingModelSpec(
  name: 'eg2',
  modelSource: ModelSource.network('https://example.com/eg2.litertlm'),
);

RuntimeConfig _bundleConfig({
  bool supportImage = false,
  bool supportAudio = false,
  PreferredBackend? preferredBackend,
  String modelPath = 'opfs://eg2.litertlm',
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: modelPath,
  supportImage: supportImage,
  supportAudio: supportAudio,
  preferredBackend: preferredBackend,
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

  test('claims a two-file spec and a .litertlm bundle (1.13.1), as the '
      'native arm does', () {
    expect(backend.canHandle(_tflite), isTrue);
    expect(backend.canHandle(_eg2), isTrue);
  });

  test('describe() hands core the EmbeddingGemma 2 pass for a .litertlm '
      'bundle: the raw path, the file name, the real runtime, resolver and '
      'revoker, GPU', () async {
    final descriptor = await backend.describe(_eg2, _bundleConfig());
    final config = descriptor.config as LiteRtLmWebEmbeddingConfig;

    expect(descriptor.engineTag, 'LiteRT-LM');
    expect(descriptor.activeBackend, PreferredBackend.gpu);
    expect(config.modelPath, 'opfs://eg2.litertlm');
    expect(config.fileName, 'eg2.litertlm');
    expect(config.runtime, isA<WindowLiteRtLmWebRuntime>());
    expect(config.resolveUrl == resolveWebModelUrl, isTrue);
    expect(config.revokeUrl == revokeObjectUrl, isTrue);
    expect(config.backend, LiteRtLmWebBackend.gpu);
    expect(config.declaredMedia, isEmpty);
    expect(config.visionTokensPerImage, 140);
    expect(descriptor.build(), isA<LiteRtLmWebEmbeddingPass>());
  });

  test('describe() on a bundle: images are declared to the pass, and a '
      'vision budget other than 140/70 is refused', () async {
    final images =
        (await backend.describe(_eg2, _bundleConfig(supportImage: true))).config
            as LiteRtLmWebEmbeddingConfig;
    expect(images.declaredMedia, {EmbeddingModality.image});

    final seventy =
        (await const LiteRtEmbeddingBackend(
              visionTokensPerImage: 70,
            ).describe(_eg2, _bundleConfig(supportImage: true))).config
            as LiteRtLmWebEmbeddingConfig;
    expect(seventy.visionTokensPerImage, 70);
    await expectLater(
      const LiteRtEmbeddingBackend(
        visionTokensPerImage: 280,
      ).describe(_eg2, _bundleConfig(supportImage: true)),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.engine,
          'engine',
          'LiteRT-LM',
        ),
      ),
    );
  });

  test('requireWeightCache is accepted, as natively, and changes nothing: the '
      'web keeps no weight cache', () async {
    const strict = LiteRtEmbeddingBackend(requireWeightCache: true);
    final descriptor = await strict.describe(
      _eg2,
      _bundleConfig(supportImage: true),
    );
    final config = descriptor.config as LiteRtLmWebEmbeddingConfig;
    expect(descriptor.activeBackend, PreferredBackend.gpu);
    expect(config.declaredMedia, {EmbeddingModality.image});
    expect(config.visionTokensPerImage, 140);
    expect(descriptor.build(), isA<LiteRtLmWebEmbeddingPass>());
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

  test('describe() on a bundle refuses npu: the NPU runs EmbeddingGemma 2 '
      'only through the native Qualcomm dispatch', () async {
    await expectLater(
      backend.describe(
        _eg2,
        _bundleConfig(preferredBackend: PreferredBackend.npu),
      ),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having((e) => e.message, 'message', contains('not on the web')),
      ),
    );
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

  test('describe() with audio reads the bundle\'s container header through '
      'the page (1.13.2): the 740m declares audio to the pass; the 270m is '
      'refused naming the 740m; a path the page cannot open is a load error '
      'naming the file', () async {
    String blobUrl(Uint8List bytes) {
      globalContext['__bytes'] = bytes.toJS;
      return (globalContext.callMethod<JSString>(
        'eval'.toJS,
        'URL.createObjectURL(new Blob([window.__bytes]))'.toJS,
      )).toDart;
    }

    final audio =
        (await backend.describe(
              _eg2,
              _bundleConfig(
                supportImage: true,
                supportAudio: true,
                modelPath: blobUrl(eg2Header740m),
              ),
            )).config
            as LiteRtLmWebEmbeddingConfig;
    expect(audio.declaredMedia, {
      EmbeddingModality.image,
      EmbeddingModality.audio,
    });
    expect(audio.audioBackend, LiteRtLmWebBackend.gpu);

    await expectLater(
      backend.describe(
        _eg2,
        _bundleConfig(supportAudio: true, modelPath: blobUrl(eg2Header270m)),
      ),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having(
              (e) => e.message,
              'message',
              'eg2.litertlm has no audio encoder; install '
                  'embeddinggemma-2-740m',
            ),
      ),
    );

    // A header whose root offset points past its end — under dart2js the
    // DataView's own RangeError, which must still read as a corrupt header.
    final corrupt = Uint8List.fromList(eg2Header740m)
      ..setAll(32, [0xF0, 0xFF, 0x00, 0x00]);
    await expectLater(
      backend.describe(
        _eg2,
        _bundleConfig(supportAudio: true, modelPath: blobUrl(corrupt)),
      ),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              'could not read the container of eg2.litertlm to find its '
              'audio encoder',
            ),
            contains('header flatbuffer is truncated'),
          ),
        ),
      ),
    );

    // opfs:// without streaming storage set up: the resolver refuses.
    await expectLater(
      backend.describe(_eg2, _bundleConfig(supportAudio: true)),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          contains(
            "could not open eg2.litertlm from the page's model storage "
            '(opfs://eg2.litertlm)',
          ),
        ),
      ),
    );
  });
}
