// One lock for everything litertlm_dart runs on the page's `@litert-lm/core`
// WebAssembly module: the `.litertlm` LLM engine (`Engine.create`,
// `createConversation`, a generation from its first chunk until the stream
// ends) and the EmbeddingGemma 2 engine (`EmbeddingEngine.create` with the
// load probe, each `computeEmbedding`). Internal (internal.dart), for the
// flutter_edge_ai_litertlm tests that order their own calls against it.
//
// Why a page-wide lock, read from @litert-lm/core 0.18.0 and again from
// 0.19.0, which adds a per-module creation mutex (`runExclusiveEngineCreation`)
// that orders the two engines' creates, but not a generation against an
// embedding:
// - Both engines run in ONE Emscripten module per page
//   (`getOrLoadGlobalLiteRtLm()`), but the runtime's own `Mutex` is per engine
//   object (`Engine.mutexes.executor`, `EmbeddingEngine.mutex`): nothing
//   orders a call of one engine against a call of the other. Both run on
//   WebGPU, on the module's one device (`preinitializedWebGPUDevice`, set up
//   by whichever engine is created first), so their GPU memory adds up too.
// - In the Asyncify builds (`litertlm_wasm_*asyncify_internal.js`, loaded where
//   the browser has no JSPI) the module has ONE suspended-call slot:
//   `Asyncify.handleSleep` stores the unwound stack in the single
//   `Asyncify.currData` and the caller's promise in the single
//   `Asyncify.asyncPromiseHandlers`, and the release build has no "multiple
//   async operations in flight" assertion. An LLM generation stays suspended
//   for its whole length (`waitUntilDone()`), and an embedding engine's create
//   suspends to read its model stream, so the second would overwrite the
//   first's state.
// - With JSPI the suspensions themselves can coexist, but whether the two
//   engines' C++ shares state behind them is not visible from JS; the
//   runtime's own comment warns that re-entering C++ while a paused stack holds
//   a mutex deadlocks.
// So every call that can suspend inside the module takes this lock, in call
// order. Calls that never suspend (`delete()`, `cancel()`) do not: `cancel()`
// must be able to stop a generation that holds the lock.
//
// Pure Dart (no `dart:js_interop`), so the ordering is tested on the VM.

import 'dart:async';

/// A FIFO async lock: [acquire] queues the caller behind every earlier
/// caller, at the moment it is called.
///
/// A lock can be [poison]ed: a holder that cannot end (a stopped generation
/// that never returned from the module) is let go of, and then nothing may
/// enter the module again — every waiting and later [acquire] fails with
/// [LiteRtLmPagePoisonedError] instead of running beside a suspended call.
final class LiteRtLmPageLock {
  Future<void> _tail = Future<void>.value();

  LiteRtLmPagePoisonedError? _poison;

  /// Why the lock is poisoned; null while it is not.
  LiteRtLmPagePoisonedError? get poison => _poison;

  /// Waits for every earlier lease to be released, then returns this
  /// caller's. The place in the queue is taken when this is CALLED, not when
  /// the future is awaited. The lease must be released on every path, or
  /// every later caller waits forever. Fails with [LiteRtLmPagePoisonedError]
  /// once the lock is poisoned.
  Future<LiteRtLmPageLease> acquire() {
    if (_poison case final poison?) return Future.error(poison);
    final previous = _tail;
    final lease = LiteRtLmPageLease._();
    _tail = lease._released.future;
    return previous.then((_) {
      if (_poison case final poison?) {
        // Pass the turn on, so every waiter behind this one fails too.
        lease.release();
        throw poison;
      }
      return lease;
    });
  }

  /// Runs [body] holding the lock; releases it however [body] ends.
  Future<T> run<T>(Future<T> Function() body) async {
    final lease = await acquire();
    try {
      return await body();
    } finally {
      lease.release();
    }
  }

  /// Gives up on [holder], a lease whose call into the module never ended,
  /// for good: [holder] is released so the waiters behind it get their turn,
  /// and each of them, as every later [acquire], fails with an error that
  /// says [why]. Said once with `print`, as release builds show it.
  void poisonFor(LiteRtLmPageLease holder, String why) {
    if (_poison == null) {
      final poison = _poison = LiteRtLmPagePoisonedError(why);
      // ignore: avoid_print
      print('[litertlm_dart] ERROR: ${poison.message}');
    }
    holder.release();
  }
}

/// The page's `@litert-lm/core` module may still be suspended in a call that
/// never ended, so litertlm_dart runs nothing more on this page: reload it.
final class LiteRtLmPagePoisonedError extends StateError {
  LiteRtLmPagePoisonedError(String why)
    : super(
        '$why The page\'s @litert-lm/core WebAssembly module may still be '
        'suspended in that call, and another call beside it would corrupt it, '
        'so litertlm_dart runs no more LLM or EmbeddingGemma 2 work on this '
        'page. Reload the page.',
      );
}

/// One holder's turn on a [LiteRtLmPageLock].
final class LiteRtLmPageLease {
  LiteRtLmPageLease._();

  final Completer<void> _released = Completer<void>();

  /// Whether [release] was called.
  bool get isReleased => _released.isCompleted;

  /// Lets the next caller in. Idempotent.
  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// The page's lock, shared by the LLM web session and the EmbeddingGemma 2
/// web pass.
final liteRtLmPageLock = LiteRtLmPageLock();
