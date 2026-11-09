import 'dart:async';

import 'package:flutter/foundation.dart';

import '../interface.dart';

/// Keeps the shells from building an inference model while the previous one
/// is still closing.
///
/// Two native models must not be resident at once, and an engine with one
/// native slot (MediaPipe) would let the old close take the new model down
/// with it. The cache's close listener fires only once a teardown has ended,
/// but a model can be closed by someone else — the app, often without
/// awaiting — and a caller arriving meanwhile has to wait for that teardown,
/// not race it.
///
/// The same rule as `EmbedderCache`'s, for the inference lane: the wait is
/// bounded by one deadline, set when the close starts and shared by every
/// caller. Past it a caller gets a [TimeoutException] naming the model still
/// closing; the close keeps running.
class ModelCloseGate {
  ModelCloseGate([@visibleForTesting this._limit = defaultLimit]);

  /// How long callers wait for a close before giving up.
  static const defaultLimit = Duration(seconds: 60);

  final Duration _limit;
  _PendingClose? _pending;

  /// Whether a close is running that a build must wait for.
  bool get isClosing => _pending != null;

  /// Whether the close running is one whose `tag` [test] accepts.
  bool isClosingWhere(bool Function(Object? tag) test) {
    final pending = _pending;
    return pending != null && test(pending.tag);
  }

  /// Closes [model] and waits for its teardown — joining it if one is
  /// already running, since `close()` hands every caller the teardown in
  /// progress. [label] names [model]; [tag] says what it was built from, for
  /// [isClosingWhere]. A close that fails is reported, not passed on: the
  /// caller asked for a new model, and the old one's error names neither.
  Future<void> closeAndWait(
    InferenceModel model, {
    required String label,
    Object? tag,
  }) => closeWith(model.close, label: label, tag: tag);

  /// [closeAndWait] for a model that is not an [InferenceModel]: [close]
  /// starts its teardown, or returns the one already running.
  Future<void> closeWith(
    Future<void> Function() close, {
    required String label,
    Object? tag,
  }) {
    final pending = _PendingClose(label, tag);
    pending.done = Future.sync(close).then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        // `print`, not `edgeAiLog`, as in `EmbedderCache`: edgeAiLog is
        // silent in release, and release is where a model left resident gets
        // debugged. It fires only in an abnormal state. Worded neutrally: the
        // throw may come from the native teardown, or from a close listener
        // the app registered, which leaves nothing behind.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai] WARNING: closing the previous model ($label) '
          'threw. If the error is from its native teardown, its weights may '
          'still be resident; if it is from a close listener, nothing was '
          'left behind: $e\n$st',
        );
      },
    );
    _pending = pending;
    unawaited(
      pending.done.whenComplete(() {
        if (identical(_pending, pending)) _pending = null;
        if (pending.timedOutACaller) {
          // The callers it held were told to retry; say when that works.
          // ignore: avoid_print
          print(
            '[flutter_edge_ai] the previous model ($label) finished closing '
            'after ${_seconds(pending.elapsed)}, past the ${_seconds(_limit)} '
            'wait; models can be built again.',
          );
        }
      }),
    );
    return wait();
  }

  /// Waits for the close in progress, if any, until its deadline — whatever
  /// is left of it, not a fresh limit per caller.
  Future<void> wait() async {
    final pending = _pending;
    if (pending == null) return;
    final remaining = _limit - pending.elapsed;
    try {
      if (remaining <= Duration.zero) throw TimeoutException(null);
      await pending.done.timeout(remaining);
    } on TimeoutException {
      pending.timedOutACaller = true;
      throw TimeoutException(
        'The previous model (${pending.label}) has not finished closing after '
        '${_seconds(_limit)}, so no new model is built: two native models '
        'must not be resident at once. Its close keeps running, and a request '
        'made after it finishes will succeed.',
        _limit,
      );
    }
  }
}

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

class _PendingClose {
  _PendingClose(this.label, this.tag);

  final String label;
  final Object? tag;
  final Stopwatch _clock = Stopwatch()..start();
  late final Future<void> done;

  /// Whether a caller gave up on this close, and so wants to hear when it
  /// ends.
  bool timedOutACaller = false;

  Duration get elapsed => _clock.elapsed;
}
