// `Session` on the web: `@litert-lm/core` 0.20.0's `Session` (session.d.ts),
// text prefill and whole-reply decode, each call holding the page lock the
// LLM and EmbeddingGemma 2 share (page_lock.dart).

import 'dart:js_interop';

import '../api/session.dart';
import '../runtime/errors.dart' show LiteRtLmNativeException;
import 'litert_lm_js.dart';
import 'page_lock.dart';
import 'web_runtime_version.dart';

/// A [SessionHandle] over a runtime session.
final class WebSessionHandle implements SessionHandle {
  /// Registers itself in [_live], the engine's open sessions, which the
  /// engine's close closes.
  WebSessionHandle(this._js, this._pageLock, this._live) {
    _live.add(this);
  }

  final JsLiteRtLmSession _js;
  final LiteRtLmPageLock _pageLock;
  final Set<WebSessionHandle> _live;
  bool _closed = false;

  static JSArray<JSString> _texts(List<InputData> inputs) => [
    for (final input in inputs)
      switch (input) {
        TextInputData(:final text) => text.toJS,
        _ => throw UnsupportedError(
          "The web runtime ($liteRtLmWebRuntime) Session prefills text only: "
          "its runPrefill takes strings.",
        ),
      },
  ].toJS;

  Future<T> _call<T>(String what, Future<T> Function() body) =>
      _pageLock.run(() async {
        if (_closed) throw StateError('The session is closed.');
        try {
          return await body();
        } on StateError {
          rethrow;
        } catch (e) {
          throw LiteRtLmNativeException('$liteRtLmWebRuntime $what: $e');
        }
      });

  @override
  Future<void> runPrefill(List<InputData> inputs) async {
    final texts = _texts(inputs);
    await _call('refused the prefill', () => _js.runPrefill(texts).toDart);
  }

  @override
  Future<String> runDecode() => _call('refused the decode', () async {
    final responses = await _js.runDecode().toDart;
    try {
      final texts = responses.getTexts().toDart;
      return texts.isEmpty ? '' : texts.first.toDart;
    } finally {
      responses.delete();
    }
  });

  /// Prefill then decode, as LiteRT-LM's own `GenerateContent` does: the
  /// runtime's `Session` has no call that does both.
  @override
  Future<String> generateContent(List<InputData> inputs) async {
    await runPrefill(inputs);
    return runDecode();
  }

  @override
  Stream<String> generateContentStream(List<InputData> inputs) => Stream.error(
    UnsupportedError(
      'The web runtime ($liteRtLmWebRuntime) Session has no streaming '
      'decode: use generateContent.',
    ),
  );

  @override
  void cancelProcess() {
    if (!_closed) _js.cancel();
  }

  @override
  Future<SessionHandle> clone() => _call(
    'could not clone the session',
    () async => WebSessionHandle(await _js.clone().toDart, _pageLock, _live),
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    await _pageLock.run(() async {
      _closed = true;
      try {
        await awaitIfThenable(_js.delete());
      } catch (e) {
        noteWebDeleteFailure('A session', e);
      }
    });
    _live.remove(this);
  }
}
