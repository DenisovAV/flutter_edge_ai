// Closing a web `.litertlm` session mid-generation. `conversation.cancel()`
// only asks the JS stream to stop: the pump keeps reading it to its end and
// holds the page lock (litert_lm_page_lock.dart) until then. close() must wait
// for that, or the owning model deletes its engine while a call is still
// suspended inside the page's WebAssembly module — and a stream that never
// ends would keep every EmbeddingGemma 2 call on the page waiting.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_lm_web_session_close_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_page_lock.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web_inference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

/// The stream ends this long after `cancel()`, as a real one takes a moment.
const _endAfterCancel = Duration(milliseconds: 300);

void main() {
  test('close() returns only after the cancelled stream has ended, and the '
      'page lock is free by then', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final done = JSObject()..['done'] = true.toJS;
    final iterator = JSObject()
      ..['next'] =
          (() => cancelled.future
                  .then((_) => Future<void>.delayed(_endAfterCancel))
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
      }).toJS;
    final session = LiteRtLmWebSession(
      conversation: conversation as LiteRtLmConversation,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      generationMutex: Mutex(),
      onClose: () {},
    );

    await session.addQueryChunk(const Message(text: 'Hello', isUser: true));
    final subscription = session.getResponseAsync().listen((_) {});
    await started.future;

    final watch = Stopwatch()..start();
    await session.close();
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(_endAfterCancel - const Duration(milliseconds: 50)),
      reason: 'close() returned before the cancelled stream ended',
    );
    final lease = await liteRtLmPageLock.acquire().timeout(
      const Duration(milliseconds: 100),
      onTimeout: () => fail('the page lock is still held after close()'),
    );
    lease.release();
    await subscription.cancel();
  });
}
