// The EmbeddingGemma 2 web pass over the REAL interop — `WindowLiteRtLmWebRuntime`
// and the page's `window.litertLmReady` / `window.EmbeddingEngine` — with a
// stub engine of `@litert-lm/core` 0.18.0's shape defined in plain JS (`eval`),
// through the path an app takes: the web backend's describe(), the pass, and
// core's inline host. What the VM suite cannot see: the JS objects themselves.
// - the loader states: no loader, a loader without `EmbeddingEngine` (an
//   index.html written for the LLM only), a loader still importing, a loader
//   that failed;
// - the WebGPU question, on a stubbed `navigator.gpu` (the test browser may
//   have no GPU): an adapter, no adapter, no `navigator.gpu` — asked with the
//   runtime's own `powerPreference: 'high-performance'` — and a page without
//   WebGPU refused before `EmbeddingEngine.create` is called;
// - the settings object `EmbeddingEngine.create` receives: `backend: 4` (GPU),
//   `maxInputLength: 1024`, and NO `visionBackend` key unless images are
//   declared (the runtime tests `!== undefined`; a null would ask for a tower
//   without a backend), then `visionBackend: 4`;
// - each request: a text part is the prefixed string, an image part is
//   `{type: 'image', data: ArrayBuffer}` of exactly the file's bytes, options
//   `{normalize: true, insertSpecialTokens: true, inputOverflowStrategy: 1}`;
// - `truncatedLength` absent vs present, and JS rejections as typed errors;
// - audio (1.13.2): describe() reads the bundle's container header through
//   the page's own `fetch()` (`readPrefix`, over a `blob:` URL as the Cache
//   API and OPFS copies are) and refuses a bundle without an audio encoder
//   before anything is created; `audioBackend: 4` only when audio is
//   declared; an audio part is `{type: 'audio', data: ArrayBuffer}` of exactly
//   the clip, and a combined input one JS array of its parts in order.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run on the GCE VM:
//   flutter test --platform chrome test/web/litert_lm_web_embedding_runtime_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — drives a pass through core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
// ignore: implementation_imports — drives a pass through core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart'
    as inline;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_backend_web.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'eg2_header_fixtures.dart';

void _js(String source) => globalContext.callMethod('eval'.toJS, source.toJS);

T _eval<T extends JSAny?>(String source) =>
    globalContext.callMethod<T>('eval'.toJS, source.toJS);

/// Removes everything a test may have put on the page, the `navigator.gpu`
/// stub included (the browser's own getter is on the prototype).
void _clearPage() => _js('''
  delete window.EmbeddingEngine;
  delete window.litertLmReady;
  delete window.__eg2;
  delete navigator.gpu;
  delete window.__gpuRequests;
''');

/// Shadows `navigator.gpu` with a stub: [present] false is a browser without
/// WebGPU; otherwise `requestAdapter` resolves to an adapter, or to null when
/// [adapter] is false, and records the options it was asked with.
void _stubGpu({bool present = true, bool adapter = true}) => _js('''
  window.__gpuRequests = [];
  Object.defineProperty(navigator, 'gpu', {
    configurable: true,
    value: ${present ? '''{
      requestAdapter: async function (options) {
        window.__gpuRequests.push(options);
        return ${adapter ? '{ features: new Set(), limits: {} }' : 'null'};
      },
    }''' : 'undefined'},
  });
''');

int get _gpuRequests => (globalContext['__gpuRequests']! as JSArray).length;

/// A stub `EmbeddingEngine` of 0.18.0's shape that records what it is given.
/// A text "token" is a space-separated word, plus BOS and EOS; an image is
/// 140 tokens, an audio clip one per byte; an array of parts is the sum.
/// Inputs over `__eg2.maxSeq` under TRUNCATE come back with
/// `truncatedLength`, as the runtime's do.
void _installEngine() => _js('''
  window.__eg2 = { settings: [], inputs: [], options: [], deletes: 0,
                   maxSeq: 1024, createError: null, computeError: null };
  window.EmbeddingEngine = function () {};
  window.EmbeddingEngine.create = async function (settings) {
    const s = window.__eg2;
    s.settings.push(settings);
    if (s.createError) throw new Error(s.createError);
    return {
      computeEmbedding: async function (input, options) {
        s.inputs.push(input);
        s.options.push(options);
        if (s.computeError) throw new Error(s.computeError);
        const count = (part) => typeof part === 'string'
            ? part.split(' ').length
            : part.type === 'audio' ? part.data.byteLength : 140;
        const tokens = (Array.isArray(input)
            ? input.reduce((sum, part) => sum + count(part), 0)
            : count(input)) + 2;
        const response = { embedding: [0.5, 0.5, 0.5, 0.5],
                           inputLength: tokens, numChunks: 1 };
        if (tokens > s.maxSeq && options.inputOverflowStrategy === 1) {
          response.truncatedLength = s.maxSeq;
        }
        return response;
      },
      delete: async function () { s.deletes++; },
    };
  };
''');

final _bundle440m = EmbeddingModelSpec(
  name: 'eg2-440m',
  modelSource: ModelSource.network(
    'https://example.com/embeddinggemma-2-text-vision-440m.litertlm',
  ),
);

RuntimeConfig _config({
  bool supportImage = false,
  bool supportAudio = false,
  String modelPath = 'blob:https://example.com/eg2',
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: modelPath,
  supportImage: supportImage,
  supportAudio: supportAudio,
);

/// A `blob:` URL of [bytes], as the Cache API and OPFS copies are served.
String _blobUrl(Uint8List bytes) {
  globalContext['__bytes'] = bytes.toJS;
  return _eval<JSString>(
    'URL.createObjectURL(new Blob([window.__bytes]))',
  ).toDart;
}

/// The model an app gets: describe() → the pass → core's inline host. With
/// [audio], [modelPath] must be a URL the page can read (a bundle header).
Future<EmbeddingModel> _start({
  bool images = false,
  bool audio = false,
  String modelPath = 'blob:https://example.com/eg2',
}) async {
  final descriptor = await const LiteRtEmbeddingBackend().describe(
    _bundle440m,
    _config(supportImage: images, supportAudio: audio, modelPath: modelPath),
  );
  final media = {
    if (images) EmbeddingModality.image,
    if (audio) EmbeddingModality.audio,
  };
  final host = await inline.startEmbeddingHost(
    descriptor,
    declaredMedia: media,
    label: 'embeddinggemma-2-text-vision-440m.litertlm',
  );
  return CommonEmbeddingModel.withHost(
    host,
    engine: descriptor.engineTag,
    activeBackend: descriptor.activeBackend,
  );
}

JSObject get _state => globalContext['__eg2']! as JSObject;

JSAny _recorded(String list, int index) =>
    (_state[list]! as JSArray<JSAny>).toDart[index];

JSObject _recordedObject(String list, int index) =>
    _recorded(list, index) as JSObject;

int _count(String list) => (_state[list]! as JSArray).length;

/// A PNG header, enough for core's sniffer.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 8, 9, //
]);

void main() {
  tearDown(_clearPage);

  group('webGpuSupport', () {
    const runtime = WindowLiteRtLmWebRuntime();

    test('an adapter: available, asked with the runtime\'s own '
        'powerPreference', () async {
      _stubGpu();
      expect(await runtime.webGpuSupport(), LiteRtLmWebGpuSupport.available);
      final options =
          (globalContext['__gpuRequests']! as JSArray<JSObject>).toDart.single;
      expect(
        (options['powerPreference']! as JSString).toDart,
        'high-performance',
      );
    });

    test('requestAdapter() resolves to null: noAdapter', () async {
      _stubGpu(adapter: false);
      expect(await runtime.webGpuSupport(), LiteRtLmWebGpuSupport.noAdapter);
    });

    test('no navigator.gpu: noWebGpu', () async {
      _stubGpu(present: false);
      expect(await runtime.webGpuSupport(), LiteRtLmWebGpuSupport.noWebGpu);
    });
  });

  group('ensureReady', () {
    const runtime = WindowLiteRtLmWebRuntime();

    test('no loader and no EmbeddingEngine: loaderMissing', () async {
      expect(
        await runtime.ensureReady(),
        LiteRtLmWebRuntimeState.loaderMissing,
      );
    });

    test(
      'a loader that sets only window.Engine: embeddingEngineMissing',
      () async {
        _js('''
        window.litertLmReady = Promise.resolve().then(() => {
          window.Engine = function () {};
          return window.Engine;
        });
      ''');
        expect(
          await runtime.ensureReady(),
          LiteRtLmWebRuntimeState.embeddingEngineMissing,
        );
      },
    );

    test(
      'a loader still importing: ready once it has set EmbeddingEngine',
      () async {
        _js('''
        window.litertLmReady = new Promise((resolve) => setTimeout(() => {
          window.EmbeddingEngine = function () {};
          resolve(null);
        }, 50));
      ''');
        expect(await runtime.ensureReady(), LiteRtLmWebRuntimeState.ready);
      },
    );

    test('a loader that failed: the rejection propagates', () async {
      _js('''
        window.litertLmReady = Promise.reject(
            new Error('Failed to fetch dynamically imported module'));
        window.litertLmReady.catch(() => {});
      ''');
      await expectLater(runtime.ensureReady(), throwsA(anything));
    });
  });

  for (final (present, adapter, why) in [
    (false, false, 'this browser has no WebGPU'),
    (true, false, 'WebGPU found no GPU adapter'),
  ]) {
    test('a page where $why: the app gets the EmbeddingLoadException saying '
        'EmbeddingGemma 2 needs WebGPU, and EmbeddingEngine.create is never '
        'called', () async {
      _installEngine();
      _stubGpu(present: present, adapter: adapter);
      await expectLater(
        _start(images: true),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  startsWith('EmbeddingGemma 2 on the web needs WebGPU'),
                  contains(why),
                  contains('There is no CPU fallback'),
                ),
              ),
        ),
      );
      expect(_count('settings'), 0, reason: 'create was called');
    });
  }

  test('a page without the shim line: the app gets the named '
      'EmbeddingLoadException', () async {
    _js('''
      window.litertLmReady = Promise.resolve().then(() => {
        window.Engine = function () {};
        return window.Engine;
      });
    ''');
    await expectLater(
      _start(),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having(
              (e) => e.message,
              'message',
              contains('window.EmbeddingEngine = m.EmbeddingEngine;'),
            ),
      ),
    );
  });

  test('text only: WebGPU asked once, then create gets GPU (4), '
      'maxInputLength 1024 and no vision keys; the probe and each text are '
      'strings; the options are normalize, special tokens and TRUNCATE '
      '(1)', () async {
    _installEngine();
    _stubGpu();
    final model = await _start();
    try {
      expect(_gpuRequests, 1);
      expect(model.dimension, 4);
      expect(model.maxInputTokens, 1024);
      expect(model.activeBackend, PreferredBackend.gpu);

      final settings = _recordedObject('settings', 0);
      expect(
        (settings['model']! as JSString).toDart,
        'blob:https://example.com/eg2',
      );
      expect((settings['backend']! as JSNumber).toDartInt, 4);
      expect((settings['maxInputLength']! as JSNumber).toDartInt, 1024);
      for (final key in [
        'visionBackend',
        'audioBackend',
        'visionTokensPerImage',
        'minInputLength',
      ]) {
        expect(settings.has(key), isFalse, reason: '$key must be absent');
      }

      await model.embed(
        EmbeddingInput.text('a red stop sign'),
        taskType: TaskType.retrievalQuery,
      );
      final probe = _recorded('inputs', 0);
      expect(probe.typeofEquals('string'), isTrue);
      final text = _recorded('inputs', 1);
      expect(
        (text as JSString).toDart,
        '${TaskType.retrievalQuery.prefix}a red stop sign',
      );
      final options = _recordedObject('options', 1);
      expect((options['normalize']! as JSBoolean).toDart, isTrue);
      expect((options['insertSpecialTokens']! as JSBoolean).toDart, isTrue);
      expect((options['inputOverflowStrategy']! as JSNumber).toDartInt, 1);
    } finally {
      await model.close();
    }
    expect((_state['deletes']! as JSNumber).toDartInt, 1);
  });

  test('images: create gets visionBackend 4 (GPU) and 140 tokens; an image '
      'reaches the engine as {type: "image", data: ArrayBuffer} of exactly '
      'its bytes', () async {
    _installEngine();
    _stubGpu();
    final model = await _start(images: true);
    try {
      final settings = _recordedObject('settings', 0);
      expect((settings['backend']! as JSNumber).toDartInt, 4);
      expect((settings['visionBackend']! as JSNumber).toDartInt, 4);
      expect((settings['visionTokensPerImage']! as JSNumber).toDartInt, 140);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });

      expect(
        await model.embed(EmbeddingInput.image(_png), taskType: TaskType.none),
        [0.5, 0.5, 0.5, 0.5],
      );
      final part = _recordedObject('inputs', _count('inputs') - 1);
      expect((part['type']! as JSString).toDart, 'image');
      final data = part['data']!;
      expect(
        _eval<JSBoolean>(
          'window.__eg2.inputs[window.__eg2.inputs.length - 1].data '
          'instanceof ArrayBuffer',
        ).toDart,
        isTrue,
      );
      expect((data as JSArrayBuffer).toDart.asUint8List(), _png);
    } finally {
      await model.close();
    }
  });

  test('an over-long text: EmbeddingInputTooLongException with the engine\'s '
      'counts, then the model keeps working', () async {
    _installEngine();
    _stubGpu();
    final model = await _start();
    try {
      final words = List.filled(1500, 'w').join(' ');
      await expectLater(
        model.embed(EmbeddingInput.text(words), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 1502),
        ),
      );
      expect(
        await model.embed(EmbeddingInput.text('ok'), taskType: TaskType.none),
        hasLength(4),
      );
    } finally {
      await model.close();
    }
  });

  test('JS rejections: create → EmbeddingLoadException naming the 440m when '
      'images were declared; computeEmbedding → EmbeddingEngineException with '
      'the JS message', () async {
    _installEngine();
    _stubGpu();
    _js("window.__eg2.createError = 'NOT_FOUND: no vision encoder';");
    await expectLater(
      _start(images: true),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.message, 'message', contains('NOT_FOUND'))
            .having(
              (e) => e.message,
              'message',
              contains('install embeddinggemma-2-text-vision-440m'),
            ),
      ),
    );

    _installEngine();
    final model = await _start();
    try {
      _js("window.__eg2.computeError = 'wasm trap';");
      await expectLater(
        model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having((e) => e.message, 'message', contains('wasm trap')),
        ),
      );
    } finally {
      await model.close();
    }
  });

  group('readPrefix (the page\'s fetch)', () {
    const runtime = WindowLiteRtLmWebRuntime();

    test('reads exactly the first bytes of a large blob, and the whole of a '
        'shorter one', () async {
      final big = Uint8List(1 << 20);
      for (var i = 0; i < big.length; i++) {
        big[i] = i % 251;
      }
      final url = _blobUrl(big);
      expect(await runtime.readPrefix(url, 32), big.sublist(0, 32));
      expect(await runtime.readPrefix(url, 70000), big.sublist(0, 70000));
      final small = _blobUrl(eg2Header740m);
      expect(await runtime.readPrefix(small, 1 << 16), eg2Header740m);
    });

    test('a URL the page cannot read throws', () async {
      final url = _blobUrl(eg2Header740m);
      _js('URL.revokeObjectURL("$url")');
      await expectLater(runtime.readPrefix(url, 32), throwsA(anything));
    });
  });

  test('audio on the 740m: describe() reads its container header through '
      'the page, create gets audioBackend 4 (GPU) and no vision keys; a clip '
      'reaches the engine as {type: "audio", data: ArrayBuffer} of exactly '
      'its bytes; a combined input as one array of its parts in '
      'order', () async {
    _installEngine();
    _stubGpu();
    final model = await _start(
      images: true,
      audio: true,
      modelPath: _blobUrl(eg2Header740m),
    );
    try {
      final settings = _recordedObject('settings', 0);
      expect((settings['backend']! as JSNumber).toDartInt, 4);
      expect((settings['audioBackend']! as JSNumber).toDartInt, 4);
      expect((settings['visionBackend']! as JSNumber).toDartInt, 4);
      expect(model.modalities, EmbeddingModality.values.toSet());

      // A RIFF/WAVE header: core sniffs WAV before anything is sent.
      final clip = Uint8List.fromList([
        ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVEfmt '.codeUnits, 1, 2, 3, //
      ]);
      expect(
        await model.embed(EmbeddingInput.audio(clip), taskType: TaskType.none),
        [0.5, 0.5, 0.5, 0.5],
      );
      final part = _recordedObject('inputs', _count('inputs') - 1);
      expect((part['type']! as JSString).toDart, 'audio');
      expect(
        _eval<JSBoolean>(
          'window.__eg2.inputs[window.__eg2.inputs.length - 1].data '
          'instanceof ArrayBuffer',
        ).toDart,
        isTrue,
      );
      expect((part['data']! as JSArrayBuffer).toDart.asUint8List(), clip);

      await model.embed(
        EmbeddingInput(text: 'a trip', images: [_png], audio: clip),
        taskType: TaskType.retrievalDocument,
      );
      final parts =
          (_recorded('inputs', _count('inputs') - 1) as JSArray<JSAny>).toDart;
      expect(parts, hasLength(3));
      expect(
        (parts[0] as JSString).toDart,
        '${TaskType.retrievalDocument.prefix}a trip',
      );
      expect(((parts[1] as JSObject)['type']! as JSString).toDart, 'image');
      expect(
        ((parts[1] as JSObject)['data']! as JSArrayBuffer).toDart.asUint8List(),
        _png,
      );
      expect(((parts[2] as JSObject)['type']! as JSString).toDart, 'audio');
      expect(
        ((parts[2] as JSObject)['data']! as JSArrayBuffer).toDart.asUint8List(),
        clip,
      );
    } finally {
      await model.close();
    }
  });

  test('audio on the 270m: describe() refuses it from the container header, '
      'naming the 740m — nothing is created', () async {
    _installEngine();
    _stubGpu();
    await expectLater(
      _start(audio: true, modelPath: _blobUrl(eg2Header270m)),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having(
              (e) => e.message,
              'message',
              'embeddinggemma-2-text-vision-440m.litertlm has no audio '
                  'encoder; install embeddinggemma-2-740m',
            ),
      ),
    );
    expect(_count('settings'), 0, reason: 'create was called');
  });
}
