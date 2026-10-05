import 'package:flutter/foundation.dart' show VoidCallback;

/// Lets the lifecycle OWNER (core) react when a model built by a separate
/// engine package closes. The package constructs the model; core registers a
/// reset callback via [addCloseListener]; the concrete model fires the
/// listeners from its own `close()`'s `finally`. Best practice: the engine
/// `createModel(spec, config)` contract stays a pure factory — no lifecycle
/// callback leaks into the contract that third-party engines implement.
///
/// Listeners fire EXACTLY ONCE provided `close()` is idempotent
/// (`if (_isClosed) return;`). [fireCloseListeners] clears the list so a
/// second invocation is a no-op even without the guard.
mixin CloseNotifier {
  final List<VoidCallback> _closeListeners = [];

  void addCloseListener(VoidCallback listener) => _closeListeners.add(listener);

  void fireCloseListeners() {
    final listeners = List<VoidCallback>.of(_closeListeners);
    _closeListeners.clear();
    for (final l in listeners) {
      l();
    }
  }
}
