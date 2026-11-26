// The public web EmbeddingEngine in a browser, over a stub module
// `window.litertLm` (its `EmbeddingEngine` and `Backend`, nothing else on the
// page) and a `fetch` that serves the
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
  const p = window.__eg = {settings: [], inputs: [], options: [], deletes: 0,
                           pinnable: true};
  const EmbeddingEngine = function EmbeddingEngine() {};
  EmbeddingEngine.prototype.computeEmbedding = function () {};
  EmbeddingEngine.prototype.delete = function () {};
  EmbeddingEngine.create = async (settings) => {
    p.settings.push(settings);
    return {
      computeEmbedding: async (input, options) => {
        p.inputs.push(input);
        p.options.push(options);
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
        const vector = [0.5, 0.5, 0.5, 0.5];
        return {embedding: options && options.outputSize ?
                    vector.slice(0, options.outputSize) : vector,
                inputLength: tokens, numChunks: chunks};
      },
      delete: async () => { p.deletes++; },
    };
  };
  window.litertLm = {EmbeddingEngine};
  window.litertLmReady = Promise.resolve(window.litertLm);
  // A WebGPU adapter, whatever the test browser has.
  Object.defineProperty(navigator, 'gpu', {configurable: true,
    value: {requestAdapter: async () => ({})}});
})();
''';

JSObject get _eg => globalContext['__eg']! as JSObject;
JSObject get _module => globalContext['litertLm']! as JSObject;
List<Object?> _list(String key) =>
    (_eg[key]! as JSArray<JSAny?>).toDart.map((v) => v.dartify()).toList();

/// `Backend` of `@litert-lm/core` 0.19.0 and 0.20.0, which renumbered it.
const _backends019 = {'GPU_ARTISAN': 2, 'CPU': 3, 'GPU': 4, 'NPU': 6};
const _backends020 = {'GPU_ARTISAN': 1, 'CPU': 2, 'GPU': 3, 'NPU': 5};

void _install(Uint8List header, {Object? backends = _backends020}) {
  globalContext.callMethod('eval'.toJS, _stub.toJS);
  if (backends != null) _module['Backend'] = backends.jsify();
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
  '''delete window.litertLm; delete window.litertLmReady;
     delete window.EmbeddingEngine; delete window.Engine;
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
  ActivationDataType? activation,
}) => EmbeddingEngineConfig(
  modelPath: 'blob:https://example.com/0f9a/embeddinggemma-2-740m.litertlm',
  backend: backend,
  visionBackend: vision,
  audioBackend: audio,
  cacheDir: cacheDir,
  requireWeightCache: requireWeightCache,
  visionTokensPerImage: budget,
  activationDataType: activation,
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

  group('refuses before anything is created', () {
    for (final (what, config, message) in [
      ('a cacheDir', _config(cacheDir: '/tmp'), 'keeps no weight cache'),
      (
        'requireWeightCache',
        _config(requireWeightCache: true),
        'keeps no weight cache',
      ),
      (
        'the CPU text tower, with the measured reason',
        _config(backend: const Backend.cpu()),
        'loads the bundles but is too slow to use',
      ),
      ('the NPU', _config(backend: const Backend.npu()), 'only natively'),
      (
        'a CPU thread count',
        _config(audio: const Backend.cpu(threadCount: 2)),
        'no CPU thread count',
      ),
      (
        'a vision tower on another backend',
        _config(vision: const Backend.cpu()),
        "the text tower's backend",
      ),
      (
        'an activation type, which its EmbeddingEngine takes none of',
        _config(activation: ActivationDataType.float32),
        'takes no activation type',
      ),
    ]) {
      test(what, () async {
        await expectLater(
          EmbeddingEngine.create(config),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
        expect(_list('settings'), isEmpty);
      });
    }

    test('a vision budget other than 140 or 70', () async {
      await expectLater(
        EmbeddingEngine.create(_config(budget: 100)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('must be one of'),
          ),
        ),
      );
      expect(_list('settings'), isEmpty);
    });

    test('a maxInputLength above the longest text signature, 8192, as '
        'natively', () async {
      await expectLater(
        EmbeddingEngine.create(
          EmbeddingEngineConfig(
            modelPath: 'blob:https://example.com/eg2',
            backend: const Backend.gpu(),
            maxInputLength: 8193,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('128, 256, 512, 1024, 2048, 8192'),
          ),
        ),
      );
      expect(_list('settings'), isEmpty);
    });
  });

  test('loads with both towers on WebGPU and reports the pinned limit; '
      'Contents map to parts in the native order; close deletes, and a later '
      'compute is a StateError', () async {
    final engine = await EmbeddingEngine.create(
      _config(vision: const Backend.gpu(), audio: const Backend.gpu()),
    );
    final settings = (_list('settings').single! as Map).cast<String, Object?>();
    expect(settings['backend'], _backends020['GPU']);
    expect(settings['visionBackend'], _backends020['GPU']);
    expect(settings['audioBackend'], _backends020['GPU']);
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
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'The embedding engine is closed.',
        ),
      ),
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

  test("Kotlin's and Swift's EmbeddingOptions reach the runtime's "
      'computeEmbedding, and outputSize is the vector length; maxInputLength '
      'reaches create', () async {
    final engine = await EmbeddingEngine.create(
      EmbeddingEngineConfig(
        modelPath:
            'blob:https://example.com/0f9a/embeddinggemma-2-740m.litertlm',
        backend: const Backend.gpu(),
        maxInputLength: 1024,
      ),
    );
    expect(((_list('settings').single! as Map)['maxInputLength']), 1024);
    final cut = await engine.computeEmbedding(
      [Content.text('task: search result | query: cats')],
      options: const EmbeddingOptions(
        outputSize: 2,
        normalize: false,
        insertSpecialTokens: false,
      ),
    );
    expect(cut, hasLength(2));
    final sent = (_list('options').last! as Map).cast<String, Object?>();
    expect(sent['outputSize'], 2);
    expect(sent['normalize'], false);
    expect(sent['insertSpecialTokens'], false);
    expect(sent.containsKey('visionTokensPerImage'), isFalse);
    await engine.computeEmbedding([
      Content.text('task: search result | query: cats'),
    ]);
    final plain = (_list('options').last! as Map).cast<String, Object?>();
    expect(plain.containsKey('outputSize'), isFalse);
    expect(plain['normalize'], true);
    await expectLater(
      engine.computeEmbedding([
        Content.text('cats'),
      ], options: const EmbeddingOptions(outputSize: 5)),
      throwsArgumentError,
    );
    await engine.close();
  });

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

  group('an EmbeddingEngine lacking a member the release calls is refused '
      'naming it and the pinned version', () {
    for (final member in ['computeEmbedding', 'delete']) {
      test(member, () async {
        ((_module['EmbeddingEngine']! as JSObject)['prototype']! as JSObject)
            .delete(member.toJS);

        await expectLater(
          EmbeddingEngine.create(_config()),
          throwsA(
            isA<EmbedderLoadException>().having(
              (e) => e.message,
              'message',
              allOf(contains(member), contains(web.liteRtLmWebRuntimeVersion)),
            ),
          ),
        );
        expect(_list('settings'), isEmpty);
      });
    }

    test('create', () async {
      (_module['EmbeddingEngine']! as JSObject).delete('create'.toJS);

      await expectLater(
        EmbeddingEngine.create(_config()),
        throwsA(
          isA<EmbedderLoadException>().having(
            (e) => e.message,
            'message',
            contains('create'),
          ),
        ),
      );
    });
  });

  group('what the page hands over is refused by name, before anything is '
      'created', () {
    Matcher refused(List<String> parts) => throwsA(
      isA<EmbedderLoadException>().having(
        (e) => e.message,
        'message',
        allOf([for (final part in parts) contains(part)]),
      ),
    );

    test('no window.litertLm: the module script to add', () async {
      globalContext.delete('litertLm'.toJS);
      await expectLater(
        EmbeddingEngine.create(_config()),
        refused([
          'window.litertLm is not set',
          web.liteRtLmWebModuleShimLine,
          web.liteRtLmWebModuleUrl,
        ]),
      );
      expect(_list('settings'), isEmpty);
    });

    test(
      'no loader and no window.litertLm: the module script to add',
      () async {
        globalContext.delete('litertLm'.toJS);
        globalContext.delete('litertLmReady'.toJS);
        await expectLater(
          EmbeddingEngine.create(_config()),
          refused([web.liteRtLmWebModuleShimLine, web.liteRtLmWebModuleUrl]),
        );
      },
    );

    for (final loader in [true, false]) {
      test('the old shim (window.EmbeddingEngine, no window.litertLm, '
          '${loader ? 'with' : 'without'} the loader): the lines to '
          'replace', () async {
        globalContext['EmbeddingEngine'] = _module['EmbeddingEngine'];
        globalContext.delete('litertLm'.toJS);
        if (!loader) globalContext.delete('litertLmReady'.toJS);
        await expectLater(
          EmbeddingEngine.create(_config()),
          refused([
            'window.Engine = m.Engine;',
            'window.EmbeddingEngine = m.EmbeddingEngine;',
            web.liteRtLmWebModuleShimLine,
          ]),
        );
        expect(_list('settings'), isEmpty);
      });
    }

    test('a module without EmbeddingEngine, whatever else it has', () async {
      _module['Engine'] = _module['EmbeddingEngine'];
      _module.delete('EmbeddingEngine'.toJS);
      await expectLater(
        EmbeddingEngine.create(_config()),
        refused([
          'window.litertLm has no EmbeddingEngine (a value of type undefined)',
          web.liteRtLmWebModuleUrl,
        ]),
      );
    });

    test('an EmbeddingEngine that is not a class', () async {
      _module['EmbeddingEngine'] = 'engine'.toJS;
      await expectLater(
        EmbeddingEngine.create(_config()),
        refused([
          'window.litertLm has no EmbeddingEngine (a value of type string)',
        ]),
      );
    });
  });

  group('the Backend ids sent are the module\'s own', () {
    for (final (version, backends, gpu, cpu) in [
      ('0.19.0', _backends019, 4, 3),
      ('0.20.0', _backends020, 3, 2),
    ]) {
      test('$version: GPU is $gpu, CPU is $cpu', () async {
        _remove();
        _install(_header740m, backends: backends);
        final engine = await EmbeddingEngine.create(
          _config(vision: const Backend.gpu(), audio: const Backend.gpu()),
        );
        final settings = (_list('settings').single! as Map)
            .cast<String, Object?>();
        expect(settings['backend'], gpu);
        expect(settings['visionBackend'], gpu);
        expect(settings['audioBackend'], gpu);
        await engine.close();

        // The CPU, as the drive suite's record asks for it.
        final embedder = web.LiteRtLmWebEmbedder(
          web.LiteRtLmWebEmbedderConfig(
            modelPath: 'blob:eg2',
            fileName: 'embeddinggemma-2-740m.litertlm',
            runtime: const web.WindowLiteRtLmWebRuntime(),
            resolveUrl: (path) async => path,
            revokeUrl: (_) {},
            backend: web.LiteRtLmWebBackend.cpu,
          ),
        );
        await embedder.load();
        expect((_list('settings').last! as Map)['backend'], cpu);
        await embedder.close();
      });
    }
  });

  group('a module whose Backend enum cannot be read is refused naming the '
      'runtime to import, before anything is created', () {
    for (final (what, backends, reason) in [
      (
        'missing',
        null,
        'window.litertLm has no Backend (a value of type undefined)',
      ),
      ('not an object', 3, 'window.litertLm.Backend is a value of type number'),
      ('without GPU', {'CPU': 2, 'GPU_ARTISAN': 1}, 'it has no GPU'),
      (
        'with a CPU that is not an integer',
        {'CPU': 'cpu', 'GPU': 3, 'GPU_ARTISAN': 1},
        'its CPU is a value of type string, not an integer',
      ),
      (
        'with CPU and GPU equal',
        {'CPU': 3, 'GPU': 3, 'GPU_ARTISAN': 1},
        'are not three ids',
      ),
    ]) {
      test(what, () async {
        _remove();
        _install(_header740m, backends: backends);
        await expectLater(
          EmbeddingEngine.create(_config()),
          throwsA(
            isA<EmbedderLoadException>().having(
              (e) => e.message,
              'message',
              allOf(contains(reason), contains(web.liteRtLmWebModuleUrl)),
            ),
          ),
        );
        expect(_list('settings'), isEmpty);
      });
    }
  });
}
