// One lock for everything this package runs on the page's `@litert-lm/core`
// WebAssembly module: the `.litertlm` LLM engine (`Engine.create`,
// `createConversation`, a generation from its first chunk until the stream
// ends) and the EmbeddingGemma 2 engine (`EmbeddingEngine.create` with the
// load probe, each `computeEmbedding`). Internal; never exported.
//
// Why a page-wide lock, read from @litert-lm/core 0.18.0:
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
final class LiteRtLmPageLock {
  Future<void> _tail = Future<void>.value();

  /// Waits for every earlier lease to be released, then returns this
  /// caller's. The place in the queue is taken when this is CALLED, not when
  /// the future is awaited. The lease must be released on every path, or
  /// every later caller waits forever.
  Future<LiteRtLmPageLease> acquire() {
    final previous = _tail;
    final lease = LiteRtLmPageLease._();
    _tail = lease._released.future;
    return previous.then((_) => lease);
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
