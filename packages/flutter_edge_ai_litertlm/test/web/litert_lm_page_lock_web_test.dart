// The LLM web session's half of the page lock (lib/src/web/
// litert_lm_page_lock.dart): a generation holds the lock from before
// `sendMessageStreaming` until the JS stream has ENDED — through every chunk,
// after a consumer that cancelled early (the session drains the stream), and
// it lets go when the stream fails. A Dart-driven stub stands in for the
// `@litert-lm/core` Conversation, so each `iterator.next()` resolves when the
// test says. The EmbeddingGemma 2 pass's half is the VM suite
// test/litert_lm_page_lock_test.dart; both on the real runtime is
// example/integration_test/web_eg2_llm_test.dart.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run on the GCE VM:
//   flutter test --platform chrome test/web/litert_lm_page_lock_web_test.dart
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

/// A Conversation whose stream advances one `next()` at a time, on command.
final class _StubStream {
  _StubStream() {
    final iterator = JSObject()
      ..['next'] = (() {
        final step = Completer<JSObject>();
        _pending.add(step);
        return step.future.toJS;
      }).toJS;
    conversation =
        (JSObject()
              ..['sendMessageStreaming'] = ((JSAny? message) => iterator).toJS
              ..['cancel'] = (() {}).toJS)
            as LiteRtLmConversation;
  }

  late final LiteRtLmConversation conversation;
  final _pending = <Completer<JSObject>>[];

  /// `next()` calls the session made that are still unanswered.
  int get waiting => _pending.length;

  /// Answers the oldest `next()`: a chunk with no content, or the end.
  void step({bool done = false}) =>
      _pending.removeAt(0).complete(JSObject()..['done'] = done.toJS);

  /// Rejects the oldest `next()`, as a failed generation does.
  void fail() =>
      _pending.removeAt(0).completeError(StateError('generation failed'));
}

LiteRtLmWebSession _session(LiteRtLmConversation conversation) =>
    LiteRtLmWebSession(
      conversation: conversation,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      generationMutex: Mutex(),
      onClose: () {},
    );

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Starts a generation and waits until it holds the lock and asked for its
/// first chunk.
Future<(_StubStream, StreamSubscription<String>)> _generate() async {
  final stub = _StubStream();
  final session = _session(stub.conversation);
  await session.addQueryChunk(const Message(text: 'hi', isUser: true));
  final subscription = session.getResponseAsync().listen(
    (_) {},
    onError: (Object _) {}, // the failing-stream case
  );
  await _settle();
  expect(stub.waiting, 1, reason: 'the pump did not start');
  return (stub, subscription);
}

/// Asks for the page lock and reports whether it has been granted.
({Future<LiteRtLmPageLease> lease, bool Function() granted}) _ask() {
  var granted = false;
  final lease = liteRtLmPageLock.acquire().then((lease) {
    granted = true;
    return lease;
  });
  return (lease: lease, granted: () => granted);
}

void main() {
  test('a generation holds the page lock through every chunk and releases it '
      'when the stream ends', () async {
    final (stub, subscription) = await _generate();
    final other = _ask();
    await _settle();
    expect(other.granted(), isFalse, reason: 'free while generating');
    stub.step();
    await _settle();
    expect(other.granted(), isFalse, reason: 'free after the first chunk');
    stub.step(done: true);
    await _settle();
    expect(other.granted(), isTrue);
    (await other.lease).release();
    await subscription.cancel();
  });

  test('a consumer that cancels early: the session drains the stream and '
      'holds the lock until it ends', () async {
    final (stub, subscription) = await _generate();
    await subscription.cancel();
    final other = _ask();
    stub.step(); // the chunk the pump was waiting for
    await _settle();
    expect(stub.waiting, 1, reason: 'the session stopped reading the stream');
    expect(other.granted(), isFalse, reason: 'released before the stream end');
    stub.step(done: true);
    await _settle();
    expect(other.granted(), isTrue);
    (await other.lease).release();
  });

  test('a stream that fails releases the lock', () async {
    final (stub, subscription) = await _generate();
    final other = _ask();
    stub.fail();
    await _settle();
    expect(other.granted(), isTrue);
    (await other.lease).release();
    await subscription.cancel();
  });
}
