/// Maps Flutter app lifecycle events to [AnySyncAccount.suspend] and
/// [AnySyncAccount.resume] (design §4.3). The only library of this package
/// that imports Flutter; the main library never exports it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'flutter_edge_ai_any.dart';

/// Suspends [account] when the app goes to the background and resumes it
/// when it comes back: on iOS at once on `paused` (the shim wraps the close
/// in a background task); on Android [androidDelay] after `paused`, so a
/// short trip to another app does not close the SDK. Best effort: the OS may
/// end the process first.
@experimental
final class AnySyncLifecycle with WidgetsBindingObserver {
  AnySyncLifecycle(
    this.account, {
    this.androidDelay = const Duration(seconds: 5),
  });

  final AnySyncAccount account;
  final Duration androidDelay;
  Timer? _pending;
  bool _started = false;

  /// Starts listening to [WidgetsBinding.instance].
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Stops listening; a scheduled suspend is dropped.
  void stop() {
    if (!_started) return;
    _started = false;
    _pending?.cancel();
    _pending = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _pending?.cancel();
        if (defaultTargetPlatform == TargetPlatform.android) {
          _pending = Timer(androidDelay, _suspend);
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          _suspend();
        }
      case AppLifecycleState.resumed:
        _pending?.cancel();
        _pending = null;
        // A no-op unless suspended.
        account.resume().ignore();
      case AppLifecycleState.detached ||
          AppLifecycleState.inactive ||
          AppLifecycleState.hidden:
        break;
    }
  }

  void _suspend() {
    _pending = null;
    // A no-op unless open.
    account.suspend().ignore();
  }
}
