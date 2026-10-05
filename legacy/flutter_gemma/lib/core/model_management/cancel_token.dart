import 'dart:async';
import '../utils/gemma_log.dart';

/// Token for cancelling model downloads
///
/// Similar to Dio's CancelToken pattern. Create a token and pass it to download methods.
/// Call `cancel()` to cancel all operations using this token.
///
/// Example:
/// ```dart
/// final token = CancelToken();
///
/// // Start download
/// downloadModelWithProgress(spec, cancelToken: token);
///
/// // Cancel from anywhere
/// token.cancel('User cancelled');
///
/// // Check in error handler
/// catch (e) {
///   if (CancelToken.isCancel(e)) {
///     print('Download cancelled');
///   }
/// }
/// ```
class CancelToken {
  Completer<void>? _completer;
  String? _cancelReason;
  StackTrace? _stackTrace;

  /// Whether this token has been cancelled
  bool get isCancelled => _cancelReason != null;

  /// The reason for cancellation, if any
  String? get cancelReason => _cancelReason;

  /// Future that completes when this token is cancelled
  Future<void> get whenCancelled {
    _completer ??= Completer<void>();
    if (isCancelled) {
      return Future.value();
    }
    return _completer!.future;
  }

  /// Cancels all operations using this token
  ///
  /// [reason] - Optional message explaining why the operation was cancelled
  void cancel([String reason = 'Operation cancelled']) {
    if (isCancelled) {
      gemmaLog(
        '⚠️ CancelToken already cancelled. '
        'Previous reason: $_cancelReason, new reason: $reason',
      );
      return;
    }

    _cancelReason = reason;
    _stackTrace = StackTrace.current;
    _completer?.complete();

    gemmaLog('🚫 CancelToken cancelled: $reason');
  }

  /// Throws if this token has been cancelled
  void throwIfCancelled() {
    if (isCancelled) {
      throw DownloadCancelledException(_cancelReason!, _stackTrace);
    }
  }

  /// Checks if an exception is a cancellation exception
  static bool isCancel(Object error) {
    return error is DownloadCancelledException;
  }
}

/// Exception thrown when a download is cancelled
class DownloadCancelledException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  DownloadCancelledException(this.message, this.stackTrace);

  @override
  String toString() => 'DownloadCancelledException: $message';
}
