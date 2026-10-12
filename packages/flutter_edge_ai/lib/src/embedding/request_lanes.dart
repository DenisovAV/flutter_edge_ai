// The request queue and serving loop both embedding hosts run (R5 §4.4
// W1-W3, §4.5): the isolate worker on native and the inline host on web share
// this file, so text-before-media, FIFO within a lane, one request in flight
// and "close fails what has not started" mean the same thing on every
// platform. Pure Dart.

import 'dart:async';
import 'dart:collection';

/// Two FIFO queues: text requests are served before media requests (a long
/// image batch must not hold up a search query), and each lane keeps arrival
/// order.
final class RequestLanes<T> {
  final _text = Queue<T>();
  final _media = Queue<T>();

  /// Files [request] in the media lane when [media], else in the text lane.
  void add(T request, {required bool media}) =>
      (media ? _media : _text).add(request);

  /// The oldest text request if there is one, else the oldest media request,
  /// else null.
  T? takeNext() {
    if (_text.isNotEmpty) return _text.removeFirst();
    if (_media.isNotEmpty) return _media.removeFirst();
    return null;
  }

  /// Empties both lanes and returns what they held (text lane first).
  List<T> drain() {
    final all = [..._text, ..._media];
    _text.clear();
    _media.clear();
    return all;
  }

  bool get isEmpty => _text.isEmpty && _media.isEmpty;

  int get length => _text.length + _media.length;
}

/// Serves requests one at a time from [RequestLanes] until a close is
/// requested.
///
/// The split between [file] (called from a message listener or a caller) and
/// [run] (the loop) is what lets a close overtake a queue: filing never starts
/// work (W1), so a close is seen as soon as the event loop is free, not after
/// every request ahead of it ran.
final class RequestPump<T> {
  /// [serve] runs one request and must not throw (W7): a throw ends [run].
  ///
  /// [yieldToEventLoop] runs before every request (W2, see [run]); it must give
  /// the event loop a turn, so a close can arrive while requests are still
  /// queued. The default, a zero-duration timer, is what the isolate host
  /// needs: it completes only after the messages queued before it. The web
  /// inline host passes a `MessageChannel` message instead: browsers clamp
  /// nested zero-delay timers to at least 4 ms, which made every request on
  /// the page cost ≈ 4.3 ms however fast the pass was. A message is not
  /// ordered against the timer or input event a close comes from, so on the
  /// page a close overtakes the queue within a few requests rather than
  /// before the next one.
  RequestPump(
    this._serve, {
    Future<void> Function() yieldToEventLoop = _zeroTimer,
  }) : _yield = yieldToEventLoop;

  static Future<void> _zeroTimer() => Future<void>.delayed(Duration.zero);

  final Future<void> Function(T request) _serve;
  final Future<void> Function() _yield;
  final _lanes = RequestLanes<T>();
  bool _closeRequested = false;
  Completer<void>? _wake;

  /// True once [requestClose] was called.
  bool get closeRequested => _closeRequested;

  /// Requests that have not started.
  int get queued => _lanes.length;

  /// Files [request]. Returns false, filing nothing, once a close was
  /// requested — the caller then fails the request as closed.
  bool file(T request, {required bool media}) {
    if (_closeRequested) return false;
    _lanes.add(request, media: media);
    _wakeUp();
    return true;
  }

  /// Stops taking requests and returns every request that has not started,
  /// for the caller to fail. The one being served, if any, finishes; [run]
  /// completes after it.
  List<T> requestClose() {
    _closeRequested = true;
    final notStarted = _lanes.drain();
    _wakeUp();
    return notStarted;
  }

  /// The serving loop. Completes once a close was requested and the request
  /// in flight, if any, has finished.
  Future<void> run() async {
    while (!_closeRequested) {
      if (_lanes.isEmpty) {
        final idle = _wake = Completer<void>();
        await idle.future;
        continue;
      }
      // W2: yield to the EVENT loop before every request. A pass may block
      // this isolate inside a synchronous native call, so a close sent
      // meanwhile is still in the message queue when the call returns — and
      // awaiting an already-completed future drains only microtasks, never
      // that queue. The default zero-duration timer is posted to the BACK of
      // the same queue, so by the time it fires the listener has filed the
      // close and [requestClose] has emptied the lanes. On the web page the
      // turn comes from a MessageChannel message: a task too, never clamped,
      // but from another task source than the timer or input event a close()
      // is called from, so the browser may serve a few more requests before
      // that close runs (test/web/inline_host_web_yield_test.dart checks that
      // it still overtakes the queue).
      await _yield();
      if (_closeRequested) break;
      final next = _lanes.takeNext();
      if (next == null) continue;
      await _serve(next);
    }
  }

  void _wakeUp() {
    final waiting = _wake;
    _wake = null;
    waiting?.complete();
  }
}
