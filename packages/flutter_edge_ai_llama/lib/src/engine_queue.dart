import 'dart:async';

import 'package:llamadart/llamadart.dart' as llama;

import 'runtime_error.dart';

/// Serializes access to the single runtime context shared by logical sessions.
class EngineQueue {
  /// Creates a shared queue with an optional once-only invalidation callback.
  EngineQueue({this.onInvalidated});

  /// Starts model teardown when recovery cannot restore known runtime state.
  final void Function(Object, StackTrace)? onInvalidated;

  /// First recovery failure; retained even when its turn was cancelled.
  Object? _invalidationCause;

  /// Read-only cause of the first failed runtime recovery.
  Object? get invalidationCause => _invalidationCause;
  StackTrace? _invalidationStack;

  /// Whether the shared runtime can no longer serve inference.
  bool get isInvalid => invalidationCause != null;

  /// Prevents further use after failure to restore shared runtime state.
  void invalidate(Object cause, StackTrace stack) {
    if (isInvalid) return;
    _invalidationCause = cause;
    _invalidationStack = stack;
    onInvalidated?.call(cause, stack);
  }

  /// Rejects reuse with the original recovery cause and stack trace.
  void ensureValid() {
    if (isInvalid) {
      Error.throwWithStackTrace(
        StateError(
          'Shared runtime recovery failed; reload the model. Cause: $invalidationCause',
        ),
        _invalidationStack!,
      );
    }
  }

  Future<void> _tail = Future<void>.value();

  /// Runs [action] exclusively, or returns null if cancelled while queued.
  Future<T?> run<T>(
    Future<T> Function() action, {
    Future<void>? cancelled,
    bool allowInvalid = false,
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = previous.then((_) => release.future);
    try {
      final acquired = await Future.any([
        previous.then((_) => true),
        if (cancelled != null) cancelled.then((_) => false),
      ]);
      if (!acquired) return null;
      if (!allowInvalid) ensureValid();
      return await action();
    } catch (error, stack) {
      // The connector owns sequencing: an SDK state failure here means the
      // shared runtime is unusable, rather than an overlapping caller mistake.
      if (!allowInvalid && error is llama.LlamaStateException) {
        invalidate(error, stack);
      }
      Error.throwWithStackTrace(runtimeError(error), stack);
    } finally {
      // A cancelled waiter must not allow its successor to overtake the owner.
      unawaited(previous.then((_) => release.complete()));
    }
  }
}
