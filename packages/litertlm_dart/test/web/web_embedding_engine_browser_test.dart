// The public web EmbeddingEngine in a browser, over a stub
// `window.EmbeddingEngine` defined on the page and a `fetch` that serves the
// 740m's container header: the refusals before anything is created, the
// settings handed over, the input limit it must pin, the Content mapping and
// its close.
//
// Run: dart test -p chrome test/web/web_embedding_engine_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_embedding_engine_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

const _stub = r'''
(() => {
  const p = window.__eg = {settings: [], inputs: [], deletes: 0, pinnable: true};
  window.EmbeddingEngine = function EmbeddingEngine() {};
  window.EmbeddingEngine.createExclusive = function () {};
  window.EmbeddingEngine.create = async (settings) => {
    p.settings.push(settings);
    return {
      computeEmbedding: async (input, options) => {
        p.inputs.push(input);
        const parts = Array.isArray(input) ? input : [input];
        let tokens = 2;
        for (const part of parts) {
          if (typeof part === 'string') {
            tokens += /^the( the)*$/.test(part) ? part.split(' ').length : part.length;
          } else {
            tokens += 140;
          }
        }
        const chunks = p.pinnable ? Math.ceil(tokens / 1024) : 1;
        return {embedding: [0.5, 0.5, 0.5, 0.5], inputLength: tokens, numChunks: chunks};
      },
      delete: async () => { p.deletes++; },
    };
  };
  window.litertLmReady = Promise.resolve(null);
  // A WebGPU adapter, whatever the test browser has.
  Object.defineProperty(navigator, 'gpu', {configurable: true,
    value: {requestAdapter: async () => ({})}});
})();
''';

JSObject get _eg => globalContext['__eg']! as JSObject;
List<Object?> _list(String key) =>
    (_eg[key]! as JSArray<JSAny?>).toDart.map((v) => v.dartify()).toList();

void _install(Uint8List header) {
  globalContext.callMethod('eval'.toJS, _stub.toJS);
  globalContext['__header'] = header.toJS;
  globalContext.callMethod(
    'eval'.toJS,
    '''window.__realFetch = window.__realFetch || window.fetch;
       window.fetch = async () => new Response(window.__header);'''
        .toJS,
  );
}

void _remove() => globalContext.callMethod(
  'eval'.toJS,
  '''delete window.EmbeddingEngine; delete window.litertLmReady;
     delete window.__eg; if (window.__realFetch) window.fetch = window.__realFetch;'''
      .toJS,
);

EmbeddingEngineConfig _config({
  Backend backend = const Backend.gpu(),
  Backend? vision,
  Backend? audio,
  String? cacheDir,
  bool requireWeightCache = false,
  int? budget,
}) => EmbeddingEngineConfig(
  modelPath: 'blob:https://example.com/0f9a/embeddinggemma-2-740m.litertlm',
  backend: backend,
  visionBackend: vision,
  audioBackend: audio,
  cacheDir: cacheDir,
  requireWeightCache: requireWeightCache,
  visionTokensPerImage: budget,
);

/// The 740m's container header (vision and audio towers), from the fixture
/// the VM suites read, served over HTTP by the test runner.
late Uint8List _header740m;

void main() {
  setUpAll(() async {
    final fetched = await globalContext
        .callMethod<JSPromise<JSObject>>(
          'fetch'.toJS,
          '../ffi/fixtures/embeddinggemma2_740m_header.litertlm'.toJS,
        )
        .toDart;
    final buffer = await fetched
        .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
        .toDart;
    _header740m = buffer.toDart.asUint8List();
  });
  setUp(() => _install(_header740m));
  tearDown(_remove);

  test('refuses before anything is created: a cacheDir, requireWeightCache, '
      'the CPU text tower (with the measured reason), the NPU, a thread '
      'count, a vision tower on another backend, a budget other than '
      '140/70', () async {
    for (final config in [
      _config(cacheDir: '/tmp'),
      _config(requireWeightCache: true),
      _config(backend: const Backend.cpu()),
      _config(backend: const Backend.npu()),
      _config(audio: const Backend.cpu(threadCount: 2)),
      _config(vision: const Backend.cpu()),
    ]) {
      await expectLater(EmbeddingEngine.create(config), throwsUnsupportedError);
    }
    await expectLater(
      EmbeddingEngine.create(_config(backend: const Backend.cpu())),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('Failed to get external weight'),
        ),
      ),
    );
    await expectLater(
      EmbeddingEngine.create(_config(budget: 100)),
      throwsArgumentError,
    );
    expect(_list('settings'), isEmpty);
  });

  test('loads with both towers on WebGPU and reports the pinned limit; '
      'Contents map to parts in the native order; close deletes, and a later '
      'compute is a StateError', () async {
    final engine = await EmbeddingEngine.create(
      _config(vision: const Backend.gpu(), audio: const Backend.gpu()),
    );
    final settings = (_list('settings').single! as Map).cast<String, Object?>();
    expect(settings['backend'], 4);
    expect(settings['visionBackend'], 4);
    expect(settings['audioBackend'], 4);
    expect(settings['maxInputLength'], 1024);
    expect(engine.info.maxInputTokens, 1024);
    expect(engine.info.dimension, 4);
    expect(engine.info.activeBackend, BackendKind.gpu);
    expect(engine.cacheDir, isNull);

    final vector = await engine.computeEmbedding([
      Content.text('task: search result | query: cats'),
      Content.imageBytes(Uint8List.fromList([1, 2, 3])),
    ]);
    expect(vector, hasLength(4));
    final parts = _list('inputs').last! as List;
    expect(parts.first, 'task: search result | query: cats');
    expect((parts[1]! as Map)['type'], 'image');

    await engine.close();
    expect((_eg['deletes']! as JSNumber).toDartInt, 1);
    await expectLater(
      engine.computeEmbedding([Content.text('x')]),
      throwsStateError,
    );
  });

  test(
    'an over-long input is EmbedderInputTooLongException with the count',
    () async {
      final engine = await EmbeddingEngine.create(_config());
      await expectLater(
        engine.computeEmbedding([Content.text('w' * 2000)]),
        throwsA(
          isA<EmbedderInputTooLongException>()
              .having((e) => e.maxInputTokens, 'max', 1024)
              .having((e) => e.actualTokens, 'actual', 2002),
        ),
      );
      await engine.close();
    },
  );

  test('a limit the engine does not let pin is a load failure naming the '
      'file, and the engine is deleted', () async {
    _eg['pinnable'] = false.toJS;
    await expectLater(
      EmbeddingEngine.create(_config()),
      throwsA(
        isA<EmbedderLoadException>().having(
          (e) => e.message,
          'message',
          contains('embeddinggemma-2-740m.litertlm'),
        ),
      ),
    );
    expect((_eg['deletes']! as JSNumber).toDartInt, 1);
  });

  test(
    'another @litert-lm/core on the page is refused naming the pinned one',
    () async {
      (globalContext['EmbeddingEngine']! as JSObject).delete(
        'createExclusive'.toJS,
      );
      await expectLater(
        EmbeddingEngine.create(_config()),
        throwsA(
          isA<EmbedderLoadException>().having(
            (e) => e.message,
            'message',
            contains(web.liteRtLmWebRuntimeVersion),
          ),
        ),
      );
    },
  );
}
