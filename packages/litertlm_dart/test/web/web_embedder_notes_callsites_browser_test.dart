// The page's EmbeddingEngine runtime (WindowLiteRtLmWebRuntime) and its
// notes: another @litert-lm/core than the pinned one, said once the shim's
// import has run and named in a failed create, and a failed delete. Its own
// file: the notes are once per page, and each browser test file is its own
// page.
//
// Run: dart test -p chrome test/web/web_embedder_notes_callsites_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_embedder_notes_callsites_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:test/test.dart';

import 'web_runtime_stub.dart' show printsOf, settle;

/// A shim whose import is still running: it defines `EmbeddingEngine`, and
/// the page has fetched @litert-lm/core 0.18.0, only once `__importDone()`
/// is called.
const _pendingShim = r'''
(() => {
  window.__eg = {createError: null, deleteError: null};
  let done;
  window.litertLmReady = new Promise((resolve) => { done = resolve; });
  window.__importDone = () => {
    Object.defineProperty(performance, 'getEntriesByType', {
      configurable: true,
      value: (type) => type !== 'resource' ? [] : [
        {name: 'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm'},
      ],
    });
    window.LiteRtLmBackend = {GPU_ARTISAN: 2, CPU: 3, GPU: 4};
    window.EmbeddingEngine = function EmbeddingEngine() {};
    window.EmbeddingEngine.prototype.computeEmbedding = function () {};
    window.EmbeddingEngine.prototype.delete = function () {};
    window.EmbeddingEngine.create = async () => {
      if (window.__eg.createError) throw new Error(window.__eg.createError);
      return {
        computeEmbedding: async () => ({embedding: [1], inputLength: 1, numChunks: 1}),
        delete: async () => {
          if (window.__eg.deleteError) throw new Error(window.__eg.deleteError);
        },
      };
    };
    done(null);
  };
})();
''';

void _set(String key, String? value) =>
    (globalContext['__eg']! as JSObject)[key] = value?.toJS;

const _settings = web.LiteRtLmWebEngineSettings(
  modelUrl: 'blob:https://example.com/eg2',
  backend: web.LiteRtLmWebBackend.gpu,
  maxInputLength: 1024,
);

void main() {
  setUpAll(() => globalContext.callMethod('eval'.toJS, _pendingShim.toJS));

  test('another @litert-lm/core the shim imported is printed once the '
      'import has run', () async {
    const runtime = web.WindowLiteRtLmWebRuntime();

    final printed = await printsOf(() async {
      final ready = runtime.ensureReady();
      await settle();
      globalContext.callMethod('__importDone'.toJS);
      await ready;
    });

    expect(
      printed.where((l) => l.contains('loaded @litert-lm/core 0.18.0')),
      hasLength(1),
    );
  });

  test('a failed create names the page\'s version and the module to '
      'import', () async {
    _set('createError', 'Unsupported backend');

    await expectLater(
      const web.WindowLiteRtLmWebRuntime().create(_settings),
      throwsA(
        predicate<Object>(
          (e) =>
              '$e'.contains('Unsupported backend') &&
              '$e'.contains('The page loaded @litert-lm/core 0.18.0') &&
              '$e'.contains(web.liteRtLmWebModuleUrl),
          'names 0.18.0 and the module to import',
        ),
      ),
    );
    _set('createError', null);
  });

  test('an embedding engine whose delete fails is printed', () async {
    final engine = await const web.WindowLiteRtLmWebRuntime().create(_settings);
    _set('deleteError', 'engine busy');

    final printed = await printsOf(
      () => engine.delete().then((_) {}, onError: (Object _) {}),
    );

    expect(
      printed.where((l) => l.contains('An embedding engine failed to free')),
      hasLength(1),
    );
  });
}
