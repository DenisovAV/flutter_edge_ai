// The LiteRT.js embedding state is one per PAGE (`tfliteModel`, `tokenizer`
// and `isInitialized` in litert_embeddings.js), while `WebEmbeddingModel`'s
// `_isInitialized` is one per instance. These tests stand in for the JS with
// stubs on `window` that share one flag, the way the real bundle does, and pin
// the order of loads and disposes across instances.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/web_embedding_model_page_lane_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_gemma_litertlm/src/embedding/web/web_embedding_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page-global state the real bundle keeps, reduced to the one flag the
/// Dart side consults.
bool _pageLoaded = false;
int _loads = 0;
int _disposes = 0;

/// [loadDelays] is per call, in order; the last one repeats.
void _installStubs({required List<Duration> loadDelays}) {
  _pageLoaded = false;
  _loads = 0;
  _disposes = 0;

  Future<JSFloat32Array> embed() async {
    if (!_pageLoaded) throw StateError('page state was disposed');
    return Float32List(4).toJS;
  }

  globalContext['loadLiteRtEmbeddings'] =
      ((JSAny? model, JSAny? tokenizer, JSAny? wasm) {
        return () async {
          _loads++;
          await Future<void>.delayed(
            loadDelays[(_loads - 1).clamp(0, loadDelays.length - 1)],
          );
          _pageLoaded = true;
        }().toJS;
      }).toJS;
  globalContext['cleanupLiteRtEmbeddings'] = (() {
    return () async {
      _disposes++;
      _pageLoaded = false;
    }().toJS;
  }).toJS;
  globalContext['isLiteRtEmbeddingsInitialized'] =
      (() => _pageLoaded.toJS).toJS;
  globalContext['generateEmbedding'] = ((JSString text) => embed().toJS).toJS;
  globalContext['generateDocumentEmbedding'] =
      ((JSString text) => embed().toJS).toJS;
  globalContext['getLiteRtEmbeddingDimension'] = (() => 4.toJS).toJS;
}

WebEmbeddingModel _model() =>
    WebEmbeddingModel(modelPath: 'm', tokenizerPath: 't', onClose: () {});

void main() {
  test(
    'a replacement built while the old model is still closing keeps its page '
    'state',
    () async {
      // The shape EmbedderCache produces: an app closes the embedder without
      // awaiting (as `State.dispose` must) during its first load, and the next
      // `getActiveEmbedder` builds a replacement at once, because the old one
      // already reports `isClosed`.
      // The replacement's load is the FAST one, so it finishes while the old
      // model's load is still running — before the old close reaches its
      // dispose. That order is what deleted the replacement's state.
      _installStubs(
        loadDelays: const [
          Duration(milliseconds: 200),
          Duration(milliseconds: 20),
        ],
      );

      final a = _model();
      // Subscribed at once: the error arrives when the load ends, before the
      // close does, and an unsubscribed failure is reported as uncaught.
      final firstEmbedding = expectLater(
        a.generateEmbedding('x'),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final closing = a.close(); // deliberately not awaited
      expect(a.isClosed, isTrue);

      final b = _model();
      final bFirst = b.generateEmbedding('y');

      await closing;
      await firstEmbedding;
      await bFirst;

      // The old model's dispose must not have run AFTER the replacement's load.
      expect(
        await b.generateEmbedding('z'),
        hasLength(4),
        reason: 'the replacement lost its page state to the old close',
      );
      expect(_disposes, 1);
    },
  );

  test('a caller waiting on a load that its model closed during gets the '
      'closed error, not a JS one', () async {
    _installStubs(loadDelays: const [Duration(milliseconds: 100)]);

    final model = _model();
    final pending = expectLater(
      model.generateEmbedding('x'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('EmbeddingModel is closed'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await model.close();
    await pending;
  });

  test('a load that fails can be retried on the same model', () async {
    // The lane must not swallow the failure, and must not stay blocked by it.
    _installStubs(loadDelays: const [Duration.zero]);
    var failNext = true;
    final realLoad = globalContext['loadLiteRtEmbeddings'] as JSFunction;
    globalContext['loadLiteRtEmbeddings'] =
        ((JSAny? model, JSAny? tokenizer, JSAny? wasm) {
          if (failNext) {
            failNext = false;
            return Future<void>.error(StateError('fetch failed')).toJS;
          }
          return realLoad.callAsFunction(null, model, tokenizer, wasm)
              as JSPromise;
        }).toJS;

    final model = _model();
    await expectLater(model.generateEmbedding('x'), throwsException);
    expect(await model.generateEmbedding('x'), hasLength(4));
    expect(_loads, 1, reason: 'only the retry reached the real load');

    await model.close();
  });
}
