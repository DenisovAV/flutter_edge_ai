// The LiteRT.js embedding state is one per PAGE (`tfliteModel`, `tokenizer`
// and `isInitialized` in litert_embeddings.js), while a `LiteRtJsEmbeddingPass`
// is one per loaded embedder. These tests stand in for the JS with stubs on
// `window` that share one flag, the way the real bundle does, and pin the
// order of loads and disposes across passes, plus what the pass sends and
// reads through the REAL interop on bundle API v2: `taskType.prefix + text`
// for every task type, the dimension and input length the load reports, and a
// `too_long` answer as the typed overflow. The same rules over a fake bundle
// run on the VM (test/litert_js_embedding_pass_test.dart).
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_js_embedding_pass_page_lane_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_js_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_web_embeddings.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page-global state the real bundle keeps, reduced to the one flag the
/// stubs consult.
bool _pageLoaded = false;
int _loads = 0;
int _disposes = 0;

/// Every string that reached `embedLiteRtText`.
final _prompts = <String>[];

/// The input length the stub "model" reports; one id per character plus BOS
/// and EOS.
const _maxInputTokens = 64;

JSObject _object(Map<String, JSAny?> fields) {
  final object = JSObject();
  for (final MapEntry(:key, :value) in fields.entries) {
    object[key] = value;
  }
  return object;
}

/// [loadDelays] is per call, in order; the last one repeats.
void _installStubs({required List<Duration> loadDelays}) {
  _pageLoaded = false;
  _loads = 0;
  _disposes = 0;
  _prompts.clear();

  globalContext['liteRtEmbeddingsApiVersion'] = 2.toJS;
  globalContext['loadLiteRtEmbeddings'] =
      ((JSAny? model, JSAny? tokenizer, JSAny? wasm) {
        return () async {
          _loads++;
          await Future<void>.delayed(
            loadDelays[(_loads - 1).clamp(0, loadDelays.length - 1)],
          );
          _pageLoaded = true;
          return _object({
            'dimension': 4.toJS,
            'maxInputTokens': _maxInputTokens.toJS,
          });
        }().toJS;
      }).toJS;
  globalContext['cleanupLiteRtEmbeddings'] = (() {
    return () async {
      _disposes++;
      _pageLoaded = false;
    }().toJS;
  }).toJS;
  globalContext['embedLiteRtText'] = ((JSString text) {
    return () async {
      if (!_pageLoaded) throw StateError('page state was disposed');
      final prefixed = text.toDart;
      _prompts.add(prefixed);
      final ids = prefixed.length + 2;
      if (ids > _maxInputTokens) {
        return _object({
          'status': 'too_long'.toJS,
          'actualTokens': ids.toJS,
          'maxInputTokens': _maxInputTokens.toJS,
        });
      }
      return _object({
        'status': 'ok'.toJS,
        'values': Float32List.fromList([0.5, 0.5, 0.5, 0.5]).toJS,
      });
    }().toJS;
  }).toJS;
}

LiteRtJsEmbeddingPass _pass() => LiteRtJsEmbeddingPass(
  LiteRtJsEmbeddingConfig(
    modelPath: 'm',
    tokenizerPath: 't',
    bundle: const WindowLiteRtJsBundle(),
    resolveUrl: _unchanged,
    revokeUrl: _neverCalled,
  ),
);

/// These stubs need no resolving; the resolution is the backend suite's.
Future<String> _unchanged(String path) async => path;

/// Nothing here is resolved from `opfs://`, so nothing may be revoked.
void _neverCalled(String url) =>
    fail('revoked $url, which the pass did not create');

void main() {
  test('a pass closing while its replacement loads leaves the replacement '
      'its page state', () async {
    // The old pass's load is the SLOW one and its close is queued behind it;
    // the replacement's load is fast. Without the page lane the replacement
    // loaded first and the old pass's dispose then deleted its state.
    _installStubs(
      loadDelays: const [
        Duration(milliseconds: 200),
        Duration(milliseconds: 20),
      ],
    );

    final a = _pass();
    final aLoad = a.load();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final aClose = a.close(); // deliberately not awaited before b loads

    final b = _pass();
    final bLoad = b.load();

    await aLoad;
    await aClose;
    final info = await bLoad;

    expect(info.dimension, 4);
    expect(
      await b.embed(EmbeddingInput.text('z'), TaskType.retrievalQuery),
      hasLength(4),
      reason: 'the replacement lost its page state to the old close',
    );
    expect(_disposes, 1);
    await b.close();
  });

  test('a failed load does not block the lane, and what it left is '
      'disposed before the next pass loads', () async {
    _installStubs(loadDelays: const [Duration.zero]);
    var failNext = true;
    final realLoad = globalContext['loadLiteRtEmbeddings'] as JSFunction;
    globalContext['loadLiteRtEmbeddings'] =
        ((JSAny? model, JSAny? tokenizer, JSAny? wasm) {
          if (failNext) {
            failNext = false;
            return Future<JSAny?>.error(StateError('fetch failed')).toJS;
          }
          return realLoad.callAsFunction(null, model, tokenizer, wasm)
              as JSPromise;
        }).toJS;

    final failed = _pass();
    await expectLater(failed.load(), throwsA(anything));
    await failed.close();
    // The bundle may have loaded the tokenizer before the model failed; the
    // close frees it rather than let the next load overwrite it.
    expect(_disposes, 1, reason: 'a failed load is cleaned up');

    final next = _pass();
    await next.load();
    expect(_loads, 1, reason: 'only the second pass reached the real load');
    await next.close();
    expect(_disposes, 2);
  });

  test('bundle API v2 through the real interop: the load reports the '
      'model\'s limit, every task type arrives as prefix + text, and '
      'too_long is the typed overflow', () async {
    _installStubs(loadDelays: const [Duration.zero]);
    final pass = _pass();
    final info = await pass.load();
    expect(info.dimension, 4);
    expect(info.maxInputTokens, _maxInputTokens);

    for (final type in TaskType.values) {
      expect(await pass.embed(EmbeddingInput.text('q'), type), [
        0.5,
        0.5,
        0.5,
        0.5,
      ]);
    }
    expect(_prompts, [for (final t in TaskType.values) '${t.prefix}q']);

    // TaskType.none: 70 characters + BOS + EOS = 72 ids > 64.
    await expectLater(
      pass.embed(EmbeddingInput.text('x' * 70), TaskType.none),
      throwsA(
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'maxInputTokens', _maxInputTokens)
            .having((e) => e.actualTokens, 'actualTokens', 72),
      ),
    );
    // Empty text is embedded, as on native.
    expect(
      await pass.embed(EmbeddingInput.text(''), TaskType.none),
      hasLength(4),
    );
    await pass.close();
  });
}
