// engine_web.dart's two helpers for engine web arms: resolveWebModelUrl and
// WebModelSourceResolver.activeInferenceSpec.
//
// Both live in libraries that import dart:js_interop, which the VM cannot load,
// so this runs in a browser and `tool/test_all.sh` (VM only) does not pick it
// up. Browser runs belong on the GCE VM (never a local browser):
//   flutter test test/web/engine_web_helpers_test.dart --platform chrome
//
// resolveWebModelUrl's `opfs://` path runs against a real OPFS file written by
// the test: the URL it returns must be of the OPFS `File` itself — never a
// copy. It used to stream the file into a new Blob per load
// (`Response(stream).blob()`), and those copies filled the browser's blob
// storage until a load failed with a bare "TypeError: Failed to fetch" (the
// streaming EmbeddingGemma 2 case of
// example/integration_test/web_embeddings_streaming_test.dart, which also
// checks the end-to-end limit). Not covered here: the `opfs == null` refusal,
// which needs a page without OPFS.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

T _eval<T extends JSAny?>(String source) =>
    globalContext.callMethod<T>('eval'.toJS, source.toJS);

Future<void> _evalAsync(String source) =>
    _eval<JSPromise<JSAny?>>(source).toDart;

/// The OPFS file the streaming cases resolve.
const _opfsName = 'engine_web_helpers_test.bin';

/// 300 KB of a byte pattern, written to OPFS as [_opfsName].
final _opfsBytes = Uint8List.fromList([
  for (var i = 0; i < 300 * 1024; i++) (i * 31 + 7) & 0xff,
]);

Future<void> _writeOpfsFile() async {
  globalContext['__opfsBytes'] = _opfsBytes.toJS;
  await _evalAsync('''
    (async () => {
      const root = await navigator.storage.getDirectory();
      const handle = await root.getFileHandle('$_opfsName', {create: true});
      const writable = await handle.createWritable();
      await writable.write(window.__opfsBytes);
      await writable.close();
      delete window.__opfsBytes;
    })()
  ''');
}

Future<void> _removeOpfsFile() => _evalAsync('''
  (async () => {
    const root = await navigator.storage.getDirectory();
    try { await root.removeEntry('$_opfsName'); } catch (e) {}
  })()
''');

/// Records what each `URL.createObjectURL` call is given: `File <name>` for
/// a File, `Blob <size>` for any other Blob.
void _spyObjectUrls() => _eval<JSAny?>('''
  (() => {
    window.__madeFrom = [];
    window.__createObjectURL = URL.createObjectURL;
    URL.createObjectURL = function (o) {
      window.__madeFrom.push(o instanceof File
          ? 'File ' + o.name : 'Blob ' + o.size);
      return window.__createObjectURL.call(URL, o);
    };
  })()
''');

void _restoreObjectUrls() => _eval<JSAny?>('''
  (() => {
    if (window.__createObjectURL) URL.createObjectURL = window.__createObjectURL;
    delete window.__createObjectURL;
  })()
''');

List<String> get _madeFrom => [
  for (final item in (globalContext['__madeFrom']! as JSArray<JSString>).toDart)
    item.toDart,
];

Future<Uint8List> _fetchBytes(String url) async {
  final buffer = await _eval<JSPromise<JSArrayBuffer>>(
    "(async () => (await fetch('$url')).arrayBuffer())()",
  ).toDart;
  return buffer.toDart.asUint8List();
}

void main() {
  // The web test entrypoint registers no plugins: bind the test binding and
  // mock SharedPreferences before anything touches them.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
  });

  tearDown(ServiceRegistry.reset);

  group('resolveWebModelUrl', () {
    test('returns blob:, https: and relative paths unchanged', () async {
      // Anything that is not `opfs://` returns before the registry is read.
      for (final path in [
        'blob:https://example.com/0a1b2c',
        'https://huggingface.co/org/repo/resolve/main/model.onnx',
        'assets/models/tokenizer.json',
      ]) {
        expect(await resolveWebModelUrl(path), path);
      }
    });

    test('refuses an opfs:// path when streaming storage is off', () async {
      await ServiceRegistry.initialize(webStorageMode: WebStorageMode.cacheApi);
      await expectLater(
        resolveWebModelUrl('opfs://model.onnx'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('streaming storage is not enabled'),
          ),
        ),
      );
    });

    group('under streaming storage, against a real OPFS file', () {
      setUp(() async {
        // The page's opfs_helper.js, as far as a resolver could use it: its
        // getReadableStream, word for word. resolveWebModelUrl reads OPFS
        // itself today; the version before it streamed this into a copy.
        _eval<JSAny?>('''
          window.flutterGemmaOPFS = {
            async getReadableStream(filename) {
              const opfs = await navigator.storage.getDirectory();
              const handle = await opfs.getFileHandle(filename);
              const file = await handle.getFile();
              return file.stream();
            },
          };
        ''');
        await ServiceRegistry.initialize(
          webStorageMode: WebStorageMode.streaming,
        );
        await _writeOpfsFile();
        _spyObjectUrls();
      });

      tearDown(() async {
        _restoreObjectUrls();
        await _removeOpfsFile();
        _eval<JSAny?>('delete window.flutterGemmaOPFS');
      });

      test('an opfs:// path becomes a blob: URL of the OPFS File itself — no '
          'copy — that serves exactly its bytes', () async {
        final url = await resolveWebModelUrl('opfs://$_opfsName');
        try {
          expect(url, startsWith('blob:'));
          expect(
            _madeFrom,
            ['File $_opfsName'],
            reason:
                'a copy of the file (a Blob) takes the browser\'s blob '
                'storage on every load until it is garbage-collected',
          );
          expect(await _fetchBytes(url), _opfsBytes);
        } finally {
          _eval<JSAny?>("URL.revokeObjectURL('$url')");
        }
      });

      test('each resolve is a new URL the caller owns', () async {
        final first = await resolveWebModelUrl('opfs://$_opfsName');
        final second = await resolveWebModelUrl('opfs://$_opfsName');
        expect(first, isNot(second));
        _eval<JSAny?>("URL.revokeObjectURL('$first')");
        expect(
          await _fetchBytes(second),
          _opfsBytes,
          reason: 'revoking one URL leaves the other readable',
        );
        _eval<JSAny?>("URL.revokeObjectURL('$second')");
      });

      test('a file OPFS does not have: an Exception naming it, and no URL '
          'made', () async {
        await expectLater(
          resolveWebModelUrl('opfs://missing.bin'),
          throwsA(
            isA<Exception>().having(
              (e) => '$e',
              'message',
              contains('Model not found in OPFS: missing.bin'),
            ),
          ),
        );
        expect(_madeFrom, isEmpty);
      });
    });
  });

  group('WebModelSourceResolver.activeInferenceSpec', () {
    test('throws StateError when no inference model is active', () async {
      await ServiceRegistry.initialize();
      await expectLater(
        WebModelSourceResolver.forActiveModel().activeInferenceSpec(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No active inference model set'),
          ),
        ),
      );
    });

    test(
      'returns the restored active spec after awaiting the restore',
      () async {
        // The case onnx's TransformersWebResolver depends on: an ONNX web
        // inference identity is fileless (Transformers.js resolves the repo
        // itself), so it restores from prefs without an installed file.
        const repoUrl =
            'https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct';
        SharedPreferences.setMockInitialValues({
          'active_inference_model_type': 'qwen',
          'active_inference_file_type': 'onnx',
          'active_inference_filename': 'Qwen2.5-0.5B-Instruct',
          'active_inference_source': 'network|$repoUrl',
        });
        await ServiceRegistry.initialize();

        final spec = await WebModelSourceResolver.forActiveModel()
            .activeInferenceSpec();

        expect(spec.name, 'Qwen2.5-0.5B-Instruct');
        expect(spec.fileType, ModelFileType.onnx);
        expect(spec.modelType, ModelType.qwen);
        expect(spec.modelSource, NetworkSource(repoUrl));
      },
    );
  });
}
