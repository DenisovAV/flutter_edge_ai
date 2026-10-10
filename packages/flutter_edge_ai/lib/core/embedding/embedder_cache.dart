import 'dart:async';

import 'package:flutter_edge_ai/core/registry/runtime_config.dart'
    show ActiveEmbedderParams;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show EmbeddingModel;
import 'package:meta/meta.dart';

/// The cached embedder, the rule for reusing it, and the serialisation that
/// makes the rule mean anything.
///
/// Each of the three shells (mobile/desktop/web) used to hold this state as its
/// own private fields and re-implement the decision over them. Three copies is
/// three chances to get it wrong, and all three were wrong differently:
///
///  * **mobile** compared the active spec's NAME, so a same-named embedder
///    reinstalled to a new path was served stale; its explicit-paths entry
///    returned the cached model with no comparison at all; and its reuse gate
///    required a field that is only assigned AFTER the build returns, so a
///    second caller arriving mid-build fell through and started a SECOND build,
///    leaving the loser outside core's bookkeeping, so nothing in the plugin
///    would ever close it.
///  * **desktop** gated its comparison on that same after-the-build field and
///    then joined any build in flight without comparing anything, so a caller
///    asking for a different model file was handed the one already being built.
///  * **web** was the strictest — it did compare resolved paths — but had no
///    in-flight guard whatsoever, so two concurrent first callers each built
///    their own model.
///
/// None of the three identity-guarded its close listener, so a late close of a
/// superseded embedder evicted the live one. One object, one rule; the shells
/// keep the wiring.
///
/// There is deliberately no `Completer` here. Its only job would be to let a
/// concurrent caller join a build already in flight, which [serialize] makes
/// impossible — and a completer that outlives its build is a hang waiting to
/// happen: any throw between installing it and entering the enclosing `try`
/// leaves every later caller awaiting something nobody will ever complete.
class EmbedderCache {
  EmbedderCache({
    @visibleForTesting this._closeWaitLimit = defaultCloseWaitLimit,
  });

  /// How long callers may wait, in total, for an old embedder's close before
  /// [reuseOrInvalidate] gives up on them.
  @visibleForTesting
  static const defaultCloseWaitLimit = Duration(seconds: 60);

  /// Measured from the moment the close STARTS, not per caller: injectable so
  /// tests need not sit out a minute. The close itself is never bounded — see
  /// [reuseOrInvalidate].
  final Duration _closeWaitLimit;

  /// One field, so "a model with no idea what it was built from" is not a state
  /// this class can be in. As two fields it was representable, which is why the
  /// web shell opened its comparison with `p == null ||` — a branch for a
  /// state that should not exist, treated as "changed" because there was nothing
  /// else honest to do with it.
  _CachedEmbedder? _cached;
  Future<void> _lane = Future<void>.value();

  /// The close of a dropped embedder that has not finished yet. Set while any
  /// close the cache waits on is running, including one that outlived its
  /// caller's wait: the next caller waits for the SAME close, within what is
  /// left of the same deadline, before anything is built.
  _PendingClose? _pendingClose;

  /// The cached embedder, or null when none is built — or when the one that
  /// was built has been closed.
  ///
  /// Checked here as well as in [reuseOrInvalidate] because some callers read
  /// the model directly: every shell's `initializedEmbeddingModel`, and the web
  /// shell's RAG helpers. A model is closed the moment `close()` is called, but
  /// its listener only evicts it once the teardown has finished, so without this
  /// those readers were handed a model whose every call throws.
  EmbeddingModel? get model {
    final model = _cached?.model;
    return model == null || model.isClosed ? null : model;
  }

  /// What [model] was built from. Null exactly when [model] is null — closed
  /// included, so the two getters never describe different models.
  ActiveEmbedderParams? get params => model == null ? null : _cached!.params;

  /// Runs [body] after every earlier `serialize` call on this cache has
  /// settled, so that resolving paths, deciding on reuse and building are one
  /// indivisible step.
  ///
  /// Without this the three steps have awaits between them and two callers can
  /// both finish deciding before either records a model: two worker isolates,
  /// two compiles, and the loser orphaned with nobody to close it. It also
  /// removes the reordering hazard — moving an await earlier in the entry point
  /// silently widened that window once already.
  ///
  /// Not reentrant: a [body] that calls back into the same entry point waits
  /// for itself. Nothing in the plugin does; a backend's `createModel` that
  /// called `getActiveEmbedder` would.
  Future<T> serialize<T>(Future<T> Function() body) {
    final previous = _lane;
    // The lane advances on a completer of its own rather than on a handler
    // attached to the returned future. Attaching one there marks the caller's
    // error as HANDLED, so a fire-and-forget `createEmbeddingModel()` that
    // failed reported nothing at all — the silence this whole change is
    // against. `gate` only ever completes with a value, so a failure belongs
    // to its own caller and still cannot reach the next one in line.
    final gate = Completer<void>();
    _lane = gate.future;
    return previous.then((_) => body()).whenComplete(gate.complete);
  }

  /// The cached embedder when it matches [requested], else null for "build one".
  ///
  /// A mismatch closes the cached model before returning, so the caller only
  /// ever has to handle "reuse this" or "build a new one".
  ///
  /// "Build one" is never answered while a close the cache started or joined
  /// is still running, so a replacement never shares memory with the model it
  /// replaces while that model is being torn down. That holds for models whose
  /// `close()` returns the teardown already in progress, as
  /// `CommonEmbeddingModel`'s does; a model whose second `close()` returns at
  /// once can only be waited for by the caller that closed it. It is no
  /// guarantee against what a close leaves behind: a worker that died, or a
  /// native close that failed, may leave its model resident, and only a
  /// warning says so.
  ///
  /// The wait is bounded by one deadline, set when the close starts: callers
  /// share it rather than each waiting the full limit. Past it a caller gets a
  /// [TimeoutException] naming the model still closing, at once and until the
  /// close finishes. That close keeps running — nothing is killed, since a
  /// killed worker never frees its native model. Unbounded, one wedged native
  /// call would hang every embedder request in the process behind [serialize].
  Future<EmbeddingModel?> reuseOrInvalidate(
    ActiveEmbedderParams requested, {
    required String label,
  }) async {
    // A close that outlived an earlier caller's wait is still running. With it
    // pending there is no cached model, so this caller would build — and must
    // not until that close is done.
    await _awaitPendingClose(label);

    final cached = _cached;
    if (cached == null) return null;

    // Checked, not trusted. Eviction rides the close listener, so a model that
    // never fires one — or that was already closed when it was recorded, after
    // which `fireCloseListeners` has nothing left to call — would be handed to
    // every later caller, and every `generateEmbedding` on it throws. Only as
    // good as the model's own `isClosed`: the interface default is false, for
    // implementations that predate it.
    if (cached.model.isClosed) {
      edgeAiLog('ℹ️  Cached embedder is closed; building a new one for $label');
      _cached = null;
      // Closed by someone else — the app, often without awaiting, or a worker
      // that died — so its teardown may still be running. `close()` again
      // joins it (CommonEmbeddingModel hands every caller the same teardown),
      // and the rebuild waits for it like any other.
      await _closeAndWait(cached, label);
      return null;
    }

    final changedParam = cached.params.firstDifference(requested);
    if (changedParam == null) {
      edgeAiLog('ℹ️  Reusing existing embedding model instance for $label');
      return cached.model;
    }

    edgeAiLog(
      '⚠️  Embedder config changed ($changedParam) for $label — rebuilding',
    );
    // Dropped BEFORE the await, not after: while a close is in flight the
    // cached model is no longer a valid answer to anybody.
    _cached = null;
    edgeAiLog('🔄 Closing old embedding model and creating new one...');
    await _closeAndWait(cached, label);
    return null;
  }

  /// Starts closing [old], records it as the pending close with its deadline,
  /// and waits for it. The pending close clears itself whenever it ends,
  /// waited for or not.
  Future<void> _closeAndWait(_CachedEmbedder old, String label) async {
    final pending = _PendingClose(old.params);
    pending.done = _closeReportingFailure(old.model, old.params, label);
    _pendingClose = pending;
    unawaited(
      pending.done.whenComplete(() {
        if (identical(_pendingClose, pending)) _pendingClose = null;
        if (pending.timedOutACaller) {
          // The callers it held were told to retry; say when that works.
          // ignore: avoid_print
          print(
            '[flutter_edge_ai] the previous embedder (${old.params.modelPath}) '
            'finished closing after ${_seconds(pending.elapsed)}, past the '
            '${_seconds(_closeWaitLimit)} wait; embedders can be built again.',
          );
        }
      }),
    );
    await _awaitPendingClose(label);
  }

  /// Waits for the pending close, if any, until its deadline — whatever is
  /// left of it, not a fresh limit per caller.
  Future<void> _awaitPendingClose(String label) async {
    final pending = _pendingClose;
    if (pending == null) return;
    final remaining = _closeWaitLimit - pending.elapsed;
    try {
      if (remaining <= Duration.zero) throw TimeoutException(null);
      await pending.done.timeout(remaining);
    } on TimeoutException {
      pending.timedOutACaller = true;
      throw TimeoutException(
        'The previous embedder (${pending.params.modelPath}) has not finished '
        'closing after ${_seconds(_closeWaitLimit)}, so no new embedder is '
        'built for $label: two native models must not be resident at once. '
        'Its close keeps running — usually a native call that has not '
        'returned — and a request made after it finishes will succeed.',
        _closeWaitLimit,
      );
    }
  }

  static String _seconds(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

  /// Closes [model]; a throw is reported, never passed on.
  ///
  /// Reported on its own terms, not as the new caller's failure. They asked for
  /// a different embedder; handing them the old one's teardown error would name
  /// neither model, and the rebuild they asked for would never happen. The
  /// inference lane in the shells does the same (see `createModel`). Nothing
  /// depends on this succeeding — the bookkeeping is already cleared.
  Future<void> _closeReportingFailure(
    EmbeddingModel model,
    ActiveEmbedderParams params,
    String label,
  ) async {
    try {
      await model.close();
    } catch (e, st) {
      // `print`, not `gemmaLog`, for the reason `_warn` in
      // flutter_edge_ai_litertlm's litert_default_scope.dart already documents:
      // edgeAiLog opens with `if (!kDebugMode) return`, so it is silent in
      // release — and release is the build where a leaked worker isolate gets
      // debugged. It fires only in an abnormal state, so it costs nothing in
      // the normal case. Worded neutrally: the throw may come from the native
      // teardown, or from a close listener the app registered, which leaves
      // nothing behind.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai] WARNING: closing the previous embedder '
        '(${params.modelPath}) threw while rebuilding for $label. If the '
        'error is from its native teardown, its model may still be resident; '
        'if it is from a close listener, nothing was left behind: $e\n$st',
      );
    }
  }

  /// Records a freshly built [model] and what it was built from.
  void record(EmbeddingModel model, ActiveEmbedderParams params) {
    // Listener first, cache second. `addCloseListener` is abstract on the
    // published interface, not inherited from `CloseNotifier`, so a third-party
    // model may throw here — and with the assignment first, the shells' `catch`
    // would forget a live, open model with nobody left to close it. The closure
    // reads `_cached` when it fires, not now, so this order is safe.
    model.addCloseListener(() {
      // Identity-guarded, as the inference singleton and the session layer
      // already are. Without it a late close of a SUPERSEDED model clears
      // whatever is registered now — including a newer, live model, whose next
      // caller then reloads weights that are already in memory while the live
      // one leaks with nobody left to close it.
      if (!identical(_cached?.model, model)) return;
      _cached = null;
    });
    _cached = _CachedEmbedder(model, params);
  }

  /// Records [model], or closes it when the cache cannot take custody.
  ///
  /// The shell that built [model] owns it until this returns: a third-party
  /// model may throw from `addCloseListener`, which is abstract on the
  /// interface, and dropping it then would leave a live worker nobody can
  /// reach. One place, not three — the shells each had a copy, and each copy
  /// let a throwing `close()` replace the error that explains the failure.
  Future<void> adopt(EmbeddingModel model, ActiveEmbedderParams params) async {
    try {
      record(model, params);
    } catch (error, stack) {
      try {
        await model.close();
      } catch (closeError, closeStack) {
        // `print`, as in [reuseOrInvalidate]: a leak is debugged in release.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai] WARNING: an embedder the cache could not take '
          'also failed to close; its worker and native model may be leaked: '
          '$closeError\n$closeStack',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Forgets the cached embedder without closing it.
  ///
  /// For a build that failed: there is nothing to close, and leaving the
  /// bookkeeping behind is what made a one-off error permanent.
  void invalidate() => _cached = null;
}

/// The close of a dropped embedder, from its start: when the callers' shared
/// wait runs out, and whether it has already turned a caller away. A class,
/// not a record, because records have no reliable identity and [EmbedderCache]
/// compares this one by `identical`.
class _PendingClose {
  _PendingClose(this.params);

  final ActiveEmbedderParams params;
  final Stopwatch _since = Stopwatch()..start();
  late final Future<void> done;

  /// Set once a caller got a [TimeoutException] for this close, so its end is
  /// announced: they were told to retry.
  bool timedOutACaller = false;

  Duration get elapsed => _since.elapsed;
}

/// A built embedder and the params it was built from, which only ever travel
/// together.
class _CachedEmbedder {
  const _CachedEmbedder(this.model, this.params);

  final EmbeddingModel model;
  final ActiveEmbedderParams params;
}
