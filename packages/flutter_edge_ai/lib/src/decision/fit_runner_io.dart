// Native: the fit runs on an isolate of its own, off the caller's (UI)
// isolate. It holds no native state, so a cancel kills it outright.

import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart' show visibleForTesting;

import '../model_management/cancel_token.dart' show CancelToken;
import 'decider_exceptions.dart' show DeciderCancelledException;
import 'decider_fit.dart';

const _cancelled = 'createDecider was cancelled.';

int _liveFits = 0;

/// How many fit isolates are running — spawned and not yet exited. For
/// tests: a cancelled fit's isolate is gone within moments.
@visibleForTesting
int debugLiveDeciderFits() => _liveFits;

/// Runs [fitDecider] on a new isolate. The request's typed lists are copied
/// to it; the fit comes back by `Isolate.exit`, which transfers it without a
/// copy. A failure of the fit arrives as itself, with the isolate's stack.
///
/// [cancelToken] kills the isolate at once (`Isolate.immediate`) and fails
/// the call with `DeciderCancelledException`.
Future<DeciderFit> runDeciderFit(
  DeciderFitRequest request, {
  CancelToken? cancelToken,
}) {
  if (cancelToken?.isCancelled ?? false) {
    return Future.error(const DeciderCancelledException(_cancelled));
  }
  final result = Completer<DeciderFit>();
  final port = RawReceivePort();
  final link = _CancelLink();
  Isolate? isolate;
  var cancelled = false;
  _liveFits++;

  // The port stays open until the isolate is gone — its result or its exit,
  // whichever comes first — even after a cancel has failed the call.
  void gone() {
    port.close();
    link.onCancel = null;
    _liveFits--;
  }

  port.handler = (Object? message) {
    gone();
    if (result.isCompleted) return;
    switch (message) {
      case [final DeciderFit fit]:
        result.complete(fit);
      case [final Object error, final StackTrace stack]:
        // The fit threw: its own error, with its own stack.
        result.completeError(error, stack);
      case [final Object? error, final Object? stack]:
        // An uncaught error the isolate reported as two strings.
        final remote = RemoteError('$error', '$stack');
        result.completeError(remote, remote.stackTrace);
      default:
        // onExit (null) without a result: killed by a cancel, or ended.
        if (cancelled) {
          result.completeError(const DeciderCancelledException(_cancelled));
        } else {
          result.completeError(
            RemoteError('The decider fit ended without a result.', ''),
            StackTrace.empty,
          );
        }
    }
  };

  if (cancelToken != null) {
    link.onCancel = () {
      cancelled = true;
      link.onCancel = null;
      isolate?.kill(priority: Isolate.immediate);
      if (!result.isCompleted) {
        result.completeError(const DeciderCancelledException(_cancelled));
      }
    };
    _listenForCancel(cancelToken, link);
  }

  Isolate.spawn<(SendPort, DeciderFitRequest)>(
    _fitInIsolate,
    (port.sendPort, request),
    onError: port.sendPort,
    onExit: port.sendPort,
    errorsAreFatal: true,
    debugName: 'decider-fit',
  ).then(
    (spawned) {
      isolate = spawned;
      if (cancelled) spawned.kill(priority: Isolate.immediate);
    },
    onError: (Object error, StackTrace stack) {
      gone();
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  return result.future;
}

/// The fit isolate's entry point: fits, then exits with `[fit]` or
/// `[error, stack]`.
Future<void> _fitInIsolate((SendPort, DeciderFitRequest) message) async {
  final (port, request) = message;
  final DeciderFit fit;
  try {
    fit = await fitDecider(request);
  } catch (error, stack) {
    Isolate.exit(port, [error, stack]);
  }
  Isolate.exit(port, [fit]);
}

/// What the token's listener holds: the call's cancel action until the call
/// settles, nothing after.
final class _CancelLink {
  void Function()? onCancel;
}

/// Top-level, so the listener's context holds the link alone.
void _listenForCancel(CancelToken token, _CancelLink link) {
  unawaited(token.whenCancelled.then((_) => link.onCancel?.call()));
}
