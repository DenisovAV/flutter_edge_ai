import 'dart:async';

/// Serializes access to the single runtime context shared by logical sessions.
class EngineQueue {
  bool _invalid = false;

  /// Prevents further use after failure to restore shared runtime state.
  void invalidate() => _invalid = true;

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
      if (_invalid && !allowInvalid) {
        throw StateError(
          'Shared runtime cleanup failed; close and reload this model before using it again.',
        );
      }
      return await action();
    } finally {
      // A cancelled waiter must not allow its successor to overtake the owner.
      unawaited(previous.then((_) => release.complete()));
    }
  }
}
