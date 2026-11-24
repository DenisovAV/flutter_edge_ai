// Closing a web `.litertlm` session mid-generation. `conversation.cancel()`
// only asks the JS stream to stop: the pump keeps reading it to its end and
// holds the page lock (litertlm_dart lib/src/web/page_lock.dart) until then. close() must wait
// for that, or the owning model deletes its engine while a call is still
// suspended inside the page's WebAssembly module — and a stream that never
// ends would keep every EmbeddingGemma 2 call on the page waiting.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_session_close_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal.dart' show liteRtLmPageLock;

import 'package:flutter_edge_ai_litertlm/src/adapter/turn_errors.dart';

import 'web_session_fixture.dart';

void main() {
  test('close() returns only after the cancelled stream has ended, and the '
      'page lock is free by then', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final streamEnds = Completer<void>();
    final done = JSObject()..['done'] = true.toJS;
    final iterator = JSObject()
      ..['next'] =
          (() => cancelled.future
                  .then((_) => streamEnds.future)
                  .then((_) => done)
                  .toJS)
              .toJS;
    final conversation = JSObject()
      ..['sendMessageStreaming'] = ((JSAny? message) {
        if (!started.isCompleted) started.complete();
        return iterator;
      }).toJS
      ..['cancel'] = (() {
        if (!cancelled.isCompleted) cancelled.complete();
      }).toJS
      ..['getTokenCount'] = (() => Future.value(0.toJS).toJS).toJS
      ..['delete'] = (() => Future<void>.value().toJS).toJS;
    final session = webSessionOver(conversation, modelType: ModelType.gemma4);
    await session.addQueryChunk(const Message(text: 'Hello', isUser: true));
    Object? turnError;
    final subscription = session.getResponseAsync().listen(
      (_) {},
      onError: (Object e) => turnError = e,
    );
    await started.future;

    var closed = false;
    final closing = session.close().then((_) => closed = true);
    await pumpEventQueue();
    expect(closed, isFalse, reason: 'close() returned before the stream ended');

    streamEnds.complete();
    await closing;
    final lease = await liteRtLmPageLock.acquire().timeout(
      const Duration(seconds: 1),
      onTimeout: () => fail('the page lock is still held after close()'),
    );
    lease.release();
    await subscription.cancel();
    expect(
      turnError,
      isA<LiteRtLmSessionClosedError>(),
      reason: 'a close is the same error as natively',
    );
  });
}
