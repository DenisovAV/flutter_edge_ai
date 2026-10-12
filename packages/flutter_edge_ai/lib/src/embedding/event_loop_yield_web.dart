// The inline host's per-request yield on the web page: a MessageChannel
// message. It is a task, so between two requests the browser gets a turn of
// its event loop and the timer or input event a `close()` is called from can
// run while requests are still queued — which a microtask-only yield never
// allows: it serves the whole queue first.
//
// It is NOT ordered against that timer or event. Posted messages, timers and
// input are different task sources, and the HTML event loop picks the next
// task queue as the browser sees fit, so a few more requests may start after
// the timer was due. What W2 needs is that the close overtakes the queue — it
// completes before the LAST queued request starts — not that it lands before
// the very next one; test/web/inline_host_web_yield_test.dart asserts exactly
// that in the browser.
//
// Unlike a timer it is not clamped: browsers hold nested zero-delay timers to
// >= 4 ms, and with a zero timer here `embedAll` of 200 short texts over an
// instant pass took 864–934 ms in Chrome 155 (≈ 4.3 ms per request,
// R5_adjustments 2026-10-11).
//
// dart:js_interop only, so the web graph stays free of dart:io/ffi/isolate.

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';

@JS('MessageChannel')
extension type _MessageChannel._(JSObject _) implements JSObject {
  external factory _MessageChannel();
  external _MessagePort get port1;
  external _MessagePort get port2;
}

extension type _MessagePort._(JSObject _) implements JSObject {
  external set onmessage(JSFunction? handler);
  external void postMessage(JSAny? message);
}

/// One channel for the page: messages on a port arrive in the order they were
/// posted, so each one completes the oldest waiter.
final _waiting = Queue<Completer<void>>();
_MessagePort? _sender;

_MessagePort _channel() {
  final existing = _sender;
  if (existing != null) return existing;
  final channel = _MessageChannel();
  channel.port1.onmessage = ((JSAny? _) {
    _waiting.removeFirst().complete();
  }).toJS;
  return _sender = channel.port2;
}

/// Completes in a later task than the caller's: the browser runs other tasks
/// in between when it has any, in an order of its own.
Future<void> yieldToEventLoop() {
  final turn = Completer<void>();
  _waiting.add(turn);
  _channel().postMessage(null);
  return turn.future;
}
