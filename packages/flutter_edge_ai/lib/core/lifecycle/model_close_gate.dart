import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../flutter_edge_ai_interface.dart';
import '../utils/edge_ai_log.dart';

/// Keeps the shells from building an inference model while the previous one
/// is still closing.
///
/// Two native models must not be resident at once, and an engine with one
/// native slot (MediaPipe) would let the old close take the new model down
/// with it. The shells' close listeners fire only once a teardown has ended,
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

  /// Closes [model] and waits for its teardown — joining it if one is
  /// already running, since `close()` hands every caller the teardown in
  /// progress. A close that fails is logged, not passed on: the caller asked
  /// for a new model, and the old one's error names neither.
  Future<void> closeAndWait(InferenceModel model, {required String label}) {
    final pending = _PendingClose(label);
    pending.done = Future.sync(model.close).then<void>(
      (_) {},
      onError: (Object e) {
        edgeAiLog('Closing the previous model ($label) failed: $e');
      },
    );
    _pending = pending;
    unawaited(
      pending.done.whenComplete(() {
        if (identical(_pending, pending)) _pending = null;
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
      throw TimeoutException(
        'The previous model (${pending.label}) has not finished closing after '
        '${(_limit.inMilliseconds / 1000).toStringAsFixed(1)} s, so no new '
        'model is built: two native models '
        'must not be resident at once. Its close keeps running, and a request '
        'made after it finishes will succeed.',
        _limit,
      );
    }
  }
}

class _PendingClose {
  _PendingClose(this.label);

  final String label;
  final Stopwatch _clock = Stopwatch()..start();
  late final Future<void> done;

  Duration get elapsed => _clock.elapsed;
}
