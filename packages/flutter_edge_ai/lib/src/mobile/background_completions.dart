import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/utils/network_url.dart';

/// A download of core's that finished while the app was not running (#873).
@immutable
final class BackgroundCompletion {
  const BackgroundCompletion({
    required this.url,
    required this.totalBytes,
    required this.statedBy,
  });

  /// The URL the finished task downloaded. The task id is derived from the
  /// target path alone (`computeTaskId`), so a completion for a path may come
  /// from an earlier install of another source under the same name; this tells
  /// the two apart.
  final String url;

  /// The size of the whole file, as the final response stated it.
  final int totalBytes;

  /// The header that stated [totalBytes]: `Content-Range`, `X-Linked-Size` or
  /// `Content-Length`.
  final String statedBy;
}

/// The size of the whole file as a finished download's final response stated
/// it, and the header that stated it: on a 206 the total of `Content-Range`,
/// on a 200 `X-Linked-Size` (Hugging Face) or else `Content-Length`. Null when
/// the response stated no size above zero, and for any other status. Header
/// names are matched without regard to case.
({int bytes, String header})? statedTotalOf(
  int? statusCode,
  Map<String, String>? headers,
) {
  if (headers == null || headers.isEmpty) return null;
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value.trim();
    }
    return null;
  }

  ({int bytes, String header})? stated(String? value, String name) {
    final parsed = value == null ? null : int.tryParse(value);
    return parsed != null && parsed > 0 ? (bytes: parsed, header: name) : null;
  }

  switch (statusCode) {
    case 206:
      // `bytes 0-1023/2048`: the total follows the slash; `*` means unknown.
      final range = header('content-range');
      if (range == null) return null;
      final slash = range.lastIndexOf('/');
      return slash < 0
          ? null
          : stated(range.substring(slash + 1), 'Content-Range');
    case 200:
      return stated(header('x-linked-size'), 'X-Linked-Size') ??
          stated(header('content-length'), 'Content-Length');
    default:
      return null;
  }
}

/// The completions `resumeFromBackground()` replays for core's download group
/// (#873).
///
/// When a task finishes while the app is dead, background_downloader stores its
/// final status update, and `resumeFromBackground()` replays it once per
/// process — popping it as it does, so an update nobody listens to then is
/// gone for good. [reconcile] listens to the stream core's downloads use, makes
/// that one call and keeps the downloads of its group that really finished,
/// for the network install to [takeFor] before it downloads a file again.
///
/// Internal to core.
final class BackgroundCompletions {
  BackgroundCompletions({
    required this._updates,
    required this._resume,
    required this._group,
    this._waitLimit = const Duration(seconds: 10),
  });

  final Stream<TaskUpdate> Function() _updates;
  final Future<void> Function() _resume;
  final String _group;

  /// How long [takeFor] waits for the replay, and then for the task lookup,
  /// before it gives up on the evidence and lets the file be downloaded.
  final Duration _waitLimit;

  final Map<String, BackgroundCompletion> _byTaskId = {};
  Future<bool>? _reconciled;

  /// Listens, then calls `resumeFromBackground()` — once, however often this
  /// is called and by whom. True when the replay ran; false when it threw.
  /// Never throws.
  ///
  /// False matters beyond this class: a replay that failed has not written the
  /// resume records back to storage, so the startup temp sweep must not run
  /// (it would delete a resumable partial download).
  ///
  /// If the host app already made that call itself, the updates went to it
  /// and nothing is kept here.
  Future<bool> reconcile() => _reconciled ??= _capture();

  Future<bool> _capture() async {
    StreamSubscription<TaskUpdate>? subscription;
    try {
      subscription = _updates().listen(
        _keep,
        onError: (Object error) =>
            edgeAiLog('BackgroundCompletions: update stream error: $error'),
      );
      await _resume();
      // The replay reaches the group callback synchronously inside the call,
      // and listeners of the broadcast fan-out — or of a host hub fed from
      // `FileDownloader().updates` — through microtasks; this zero-length
      // timer runs after all of them. A hub that forwards only after a timer
      // or other I/O delivers too late, and its completions are not kept (see
      // `SmartDownloader.configureDownloadUpdatesStream`).
      await Future<void>.delayed(Duration.zero);
      return true;
    } catch (error) {
      _warn(
        'replaying the downloads that finished while the app was closed '
        'failed ($error). Models they downloaded will be downloaded again, '
        'and the startup cleanup of partial downloads is skipped this run.',
      );
      return false;
    } finally {
      await subscription?.cancel();
    }
  }

  void _keep(TaskUpdate update) {
    if (update is! TaskStatusUpdate) return;
    if (update.status != TaskStatus.complete) return;
    final task = update.task;
    if (task.group != _group) return;
    // Only a transfer that ended in a 200 or 206 stating the file's size. A
    // `complete` without one is not evidence: `trackTasks(markDownloadedComplete:
    // true)` reports a tracked file that merely exists, and
    // `Config.skipExistingFiles` a 304.
    final total = statedTotalOf(
      update.responseStatusCode,
      update.responseHeaders,
    );
    if (total == null) return;
    _byTaskId[task.taskId] = BackgroundCompletion(
      url: task.url,
      totalBytes: total.bytes,
      statedBy: total.header,
    );
  }

  /// The completion kept for [taskId] when a download of [url] may reuse its
  /// file, or null when it may not and the file is downloaded as before.
  ///
  /// Waits for [reconcile] first — triggering it when an install runs before
  /// core's own call at startup — but no longer than the wait limit: past it,
  /// or when the replay failed, there is no evidence. Null as well when nothing
  /// was replayed for [taskId], when a task for it is live or paused
  /// ([isActive]: the existing attach or resume path handles it), or when what
  /// was replayed downloaded another source under the same name
  /// ([sameDownloadSource]).
  ///
  /// A completion is used once: once the replay has run, asking for [taskId]
  /// removes it, whatever the answer.
  Future<BackgroundCompletion?> takeFor(
    String taskId,
    String url, {
    required Future<bool> Function(String taskId) isActive,
  }) async {
    final bool replayed;
    try {
      // The timeout is on this wait only: the replay itself carries on, and
      // the startup sweep still waits for its real outcome.
      replayed = await reconcile().timeout(_waitLimit);
    } on TimeoutException {
      _warn(
        'replaying the downloads that finished while the app was closed did '
        'not answer within ${_waitLimit.inSeconds} s; downloading the model.',
      );
      return null;
    }
    if (!replayed) return null;
    final completion = _byTaskId.remove(taskId);
    if (completion == null) return null;
    try {
      if (await isActive(taskId).timeout(_waitLimit)) return null;
    } on TimeoutException {
      _warn(
        'looking up download $taskId did not answer within '
        '${_waitLimit.inSeconds} s; downloading the model.',
      );
      return null;
    }
    return sameDownloadSource(completion.url, url) ? completion : null;
  }
}

/// A failure the app would not otherwise see, printed in release builds too.
void _warn(String message) {
  // ignore: avoid_print
  print('[flutter_edge_ai] WARNING: ${sanitizeForLog(message)}');
}
