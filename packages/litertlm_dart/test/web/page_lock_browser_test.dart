// The conversation's half of the page lock (lib/src/web/page_lock.dart): a
// generation of a WebConversationHandle holds the lock from before
// `sendMessageStreaming` until the JS stream has ENDED — through every chunk,
// after a listener that left early (the handle drains the stream), and it
// lets go when the stream fails. A Dart-driven stub stands in for the
// `@litert-lm/core` Conversation, so each `iterator.next()` resolves when the
// test says. The EmbeddingGemma 2 embedder's half is the VM suite
// test/web/page_lock_test.dart; both on the real runtime is
// example/integration_test/web_eg2_llm_test.dart.
//
// Run: dart test -p chrome test/web/page_lock_browser_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart';
import 'package:test/test.dart';

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
              ..['cancel'] = (() {}).toJS
              ..['delete'] = (() => Future<void>.value().toJS).toJS)
            as JsLiteRtLmConversation;
  }

  late final JsLiteRtLmConversation conversation;
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

WebConversationHandle _handle(JsLiteRtLmConversation conversation) =>
    WebConversationHandle(
      conversation,
      enableThinking: false,
      extraContext: const {},
      onGeneration: () {},
    );

final _hi = jsonEncode({
  'role': 'user',
  'content': [
    {'type': 'text', 'text': 'hi'},
  ],
});

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Starts a generation and waits until it holds the lock and asked for its
/// first chunk.
Future<(_StubStream, StreamSubscription<String>)> _generate() async {
  final stub = _StubStream();
  final handle = _handle(stub.conversation);
  final subscription = handle
      .chatRawMessage(_hi)
      .listen(
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

  test('a listener that cancels early: the handle drains the stream and '
      'holds the lock until it ends', () async {
    final (stub, subscription) = await _generate();
    await subscription.cancel();
    final other = _ask();
    stub.step(); // the chunk the pump was waiting for
    await _settle();
    expect(stub.waiting, 1, reason: 'the handle stopped reading the stream');
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
