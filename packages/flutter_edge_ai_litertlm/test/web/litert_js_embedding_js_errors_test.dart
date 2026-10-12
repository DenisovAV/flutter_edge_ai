// Real JavaScript errors — a synchronous `throw` and a rejected promise — from
// the bundle's window API, through the REAL path an app takes: the web
// backend's describe(), the LiteRT.js pass over the window bundle, and core's
// inline host. A load failure must reach the caller as an
// `EmbeddingLoadException`, an embed failure as an `EmbeddingEngineException`,
// both tagged 'LiteRT.js' and carrying the JS message. A page without the
// bundle at all fails the load by naming the missing file, a page with a
// stale (API v1) copy fails it with R5 §7's message, and the close behind
// either failure has nothing to dispose. The stubs are defined with `eval`,
// so they are plain JS functions, not Dart closures.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_js_embedding_js_errors_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — drives a pass through core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
// ignore: implementation_imports — drives a pass through core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart'
    as inline;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_backend_web.dart';
import 'package:flutter_test/flutter_test.dart';

void _js(String source) => globalContext.callMethod('eval'.toJS, source.toJS);

/// A bundle whose every call succeeds; each test then breaks one function.
void _installWorkingBundle() => _js('''
  window.liteRtEmbeddingsApiVersion = 2;
  window.cleanups = 0;
  window.loadLiteRtEmbeddings = async function (model, tokenizer, wasm) {
    return { dimension: 4, maxInputTokens: 64 };
  };
  window.embedLiteRtText = async function (text) {
    return { status: 'ok', values: new Float32Array([0.5, 0.5, 0.5, 0.5]) };
  };
  window.cleanupLiteRtEmbeddings = async function () { window.cleanups++; };
''');

/// What a page without `<script src="litert_embeddings.js">` has: none of
/// the bundle's window functions.
void _removeBundle() => _js('''
  delete window.liteRtEmbeddingsApiVersion;
  delete window.loadLiteRtEmbeddings;
  delete window.embedLiteRtText;
  delete window.cleanupLiteRtEmbeddings;
''');

/// What a page with a copy from flutter_edge_ai_litertlm <= 1.12.x has: the
/// v1 functions and no `liteRtEmbeddingsApiVersion`.
void _installV1Bundle() => _js('''
  delete window.liteRtEmbeddingsApiVersion;
  delete window.embedLiteRtText;
  window.cleanups = 0;
  window.loadLiteRtEmbeddings = async function (model, tokenizer, wasm) {};
  window.generateEmbedding = async function (text) {
    return new Float32Array([0.5, 0.5, 0.5, 0.5]);
  };
  window.generateDocumentEmbedding = window.generateEmbedding;
  window.getLiteRtEmbeddingDimension = function () { return 768; };
  window.cleanupLiteRtEmbeddings = async function () { window.cleanups++; };
''');

Future<EmbeddingHost> _start({
  void Function(Future<void> cleanup)? onFailedLoadCleanup,
}) async {
  final descriptor = await const LiteRtEmbeddingBackend().describe(
    EmbeddingModelSpec(
      name: 'embeddinggemma',
      modelSource: ModelSource.network('https://example.com/gemma.tflite'),
      tokenizerSource: ModelSource.network('https://example.com/t.model'),
    ),
    const RuntimeConfig(
      maxTokens: 0,
      modelPath: 'blob:model',
      tokenizerPath: 'blob:tokenizer',
    ),
  );
  return inline.startEmbeddingHost(
    descriptor,
    declaredMedia: const {},
    label: 'gemma.tflite',
    onFailedLoadCleanup: onFailedLoadCleanup,
  );
}

void main() {
  group('a load that fails in JS is an EmbeddingLoadException', () {
    for (final (how, stub) in [
      (
        'a synchronous throw',
        "window.loadLiteRtEmbeddings = function () { throw new Error('sync load boom'); };",
      ),
      (
        'a rejected promise',
        "window.loadLiteRtEmbeddings = async function () { throw new Error('async load boom'); };",
      ),
    ]) {
      test(how, () async {
        _installWorkingBundle();
        _js(stub);
        await expectLater(
          _start(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT.js')
                .having((e) => e.message, 'message', contains('load boom')),
          ),
        );
      });
    }
  });

  test('a page without litert_embeddings.js: the load names the file, and '
      'the close behind it warns about nothing', () async {
    _removeBundle();
    final printed = <String>[];
    Future<void>? cleanup;
    await runZoned(
      () => expectLater(
        _start(onFailedLoadCleanup: (c) => cleanup = c),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT.js')
              .having(
                (e) => e.message,
                'message',
                contains('litert_embeddings.js'),
              ),
        ),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    await cleanup;
    expect(
      printed.where((l) => l.contains('failed to close')),
      isEmpty,
      reason: 'there was no page state, so nothing failed to close',
    );
  });

  test(
    'a page with a stale (API v1) litert_embeddings.js: the load fails '
    'with R5 §7\'s message, and the close behind it disposes nothing',
    () async {
      _installV1Bundle();
      Future<void>? cleanup;
      await expectLater(
        _start(onFailedLoadCleanup: (c) => cleanup = c),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT.js')
              .having(
                (e) => e.message,
                'message',
                'web/litert_embeddings.js is older than '
                    'flutter_edge_ai_litertlm 1.13.0; copy '
                    'packages/flutter_edge_ai_litertlm/web/litert_embeddings.js '
                    'into your web/',
              ),
        ),
      );
      await cleanup;
      expect(
        (globalContext['cleanups'] as JSNumber).toDartInt,
        0,
        reason: 'the stale bundle was never loaded, so nothing is disposed',
      );
    },
  );

  group('an embed that fails in JS is an EmbeddingEngineException', () {
    for (final (how, stub) in [
      (
        'a synchronous throw',
        "window.embedLiteRtText = function () { throw new Error('sync embed boom'); };",
      ),
      (
        'a rejected promise',
        "window.embedLiteRtText = async function () { throw new Error('async embed boom'); };",
      ),
      (
        'an answer with an unknown status',
        "window.embedLiteRtText = async function () { return { status: 'embed boom' }; };",
      ),
    ]) {
      test(how, () async {
        _installWorkingBundle();
        final host = await _start();
        _js(stub);
        try {
          await expectLater(
            host.embed(EmbeddingInput.text('q'), TaskType.retrievalQuery),
            throwsA(
              isA<EmbeddingEngineException>()
                  .having((e) => e.engine, 'engine', 'LiteRT.js')
                  .having((e) => e.message, 'message', contains('embed boom')),
            ),
          );
          // The host keeps serving after a failed request.
          _installWorkingBundle();
          expect(
            await host.embed(EmbeddingInput.text('q'), TaskType.retrievalQuery),
            hasLength(4),
          );
        } finally {
          await host.close();
        }
      });
    }
  });
}
