import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:web/web.dart' as web;

/// The Web Locks API is not exposed by every browser/runtime that can execute
/// Dart web code, so feature-detect it instead of reading `navigator.locks`
/// unconditionally.
@JS('navigator.locks')
external web.LockManager? get _browserLockManager;

/// An exclusive, lifetime-long lease for one persistent web database location.
///
/// The process-local set makes a second open fail deterministically. The Web
/// Lock extends that exclusion to other tabs and workers on the same origin.
final class WebStoreLocationLease {
  WebStoreLocationLease._(this.location)
    : _lockName = 'flutter-edge-ai-sqlite:$location';

  static final Set<String> _heldInThisContext = <String>{};

  final String location;
  final String _lockName;

  Completer<void>? _browserRelease;
  Future<JSAny?>? _browserRequest;
  bool _released = false;

  /// Acquires the location immediately or throws instead of queueing an open
  /// that might resume much later with stale application state.
  static Future<WebStoreLocationLease> acquire(
    String location, {
    bool forceBrowserLocksUnavailable = false,
  }) async {
    if (!_heldInThisContext.add(location)) {
      throw _busy(location);
    }

    final lease = WebStoreLocationLease._(location);
    try {
      await lease._acquireBrowserLock(
        forceUnavailable: forceBrowserLocksUnavailable,
      );
      return lease;
    } catch (_) {
      _heldInThisContext.remove(location);
      rethrow;
    }
  }

  Future<void> _acquireBrowserLock({required bool forceUnavailable}) async {
    final locks = forceUnavailable ? null : _browserLockManager;
    if (locks == null) {
      throw VectorStoreException(
        'Persistent SQLite storage on web requires the Web Locks API '
        '(navigator.locks) in a secure browser context. No database was '
        'opened because this runtime cannot prevent another tab or worker '
        'from opening the same location.',
      );
    }

    final granted = Completer<bool>();
    final release = Completer<void>();
    _browserRelease = release;

    final callback = ((JSAny? lock) {
      if (!granted.isCompleted) {
        granted.complete(lock != null);
      }
      if (lock == null) return null;
      return release.future.toJS;
    }).toJS;

    final request = locks
        .request(
          _lockName,
          web.LockOptions(mode: 'exclusive', ifAvailable: true),
          callback,
        )
        .toDart;
    _browserRequest = request;

    // A rejected request can happen before the callback is invoked (for
    // example, when a browser disables the API in this security context).
    // Forward it to the acquisition waiter instead of leaving that waiter
    // pending forever.
    request.then<void>(
      (_) {
        if (!granted.isCompleted) {
          granted.completeError(
            StateError('The Web Locks request ended before granting a lock.'),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!granted.isCompleted) {
          granted.completeError(error, stackTrace);
        }
      },
    );

    final didAcquire = await granted.future;
    if (!didAcquire) {
      await request;
      _browserRelease = null;
      _browserRequest = null;
      throw _busy(location);
    }
  }

  /// Releases both the browser-wide lock and the deterministic local guard.
  Future<void> release() async {
    if (_released) return;
    _released = true;

    final release = _browserRelease;
    final request = _browserRequest;
    _browserRelease = null;
    _browserRequest = null;
    try {
      if (release != null && !release.isCompleted) release.complete();
      await request;
    } finally {
      _heldInThisContext.remove(location);
    }
  }

  static VectorStoreException _busy(String location) => VectorStoreException(
    'SQLite web location "$location" is already open. Close the existing '
    'WebSqliteVectorStore before opening the same location in this tab, '
    'worker, or another browser tab.',
  );
}
