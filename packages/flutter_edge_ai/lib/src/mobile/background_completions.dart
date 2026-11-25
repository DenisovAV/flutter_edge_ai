import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/utils/network_url.dart';

/// A download of core's that finished while the app was not running (#873).
@immutable
final class BackgroundCompletion {
  const BackgroundCompletion({required this.url, required this.totalBytes});

  /// The URL the finished task downloaded. The task id is derived from the
  /// target path alone (`computeTaskId`), so a completion for a path may come
  /// from an earlier install of another source under the same name; this tells
  /// the two apart.
  final String url;

  /// The size of the whole file as the final response stated it, or null when
  /// its headers did not say.
  final int? totalBytes;
}

/// The size of the whole file from a finished download's final response: on a
/// 206 the total of `Content-Range`, on a 200 `X-Linked-Size` (Hugging Face)
/// or else `Content-Length`. Null when the response does not state it. Header
/// names are matched without regard to case.
int? totalBytesOf(int? statusCode, Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return null;
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value.trim();
    }
    return null;
  }

  int? size(String? value) {
    final parsed = value == null ? null : int.tryParse(value);
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  switch (statusCode) {
    case 206:
      // `bytes 0-1023/2048`: the total follows the slash; `*` means unknown.
      final range = header('content-range');
      if (range == null) return null;
      final slash = range.lastIndexOf('/');
      return slash < 0 ? null : size(range.substring(slash + 1));
    case 200:
      return size(header('x-linked-size')) ?? size(header('content-length'));
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
/// that one call and keeps the `complete` updates of its group, for the
/// network install to [takeFor] before it downloads a file again.
///
/// Internal to core.
final class BackgroundCompletions {
  BackgroundCompletions({
    required this._updates,
    required this._resume,
    required this._group,
  });

  final Stream<TaskUpdate> Function() _updates;
  final Future<void> Function() _resume;
  final String _group;

  final Map<String, BackgroundCompletion> _byTaskId = {};
  Future<void>? _reconciled;

  /// Listens, then calls `resumeFromBackground()` — once, however often this
  /// is called and by whom. Never throws: without the replay there is simply
  /// no evidence, and a file is downloaded as before.
  ///
  /// If the host app already made that call itself, the updates went to it
  /// and nothing is kept here.
  Future<void> reconcile() => _reconciled ??= _capture();

  Future<void> _capture() async {
    StreamSubscription<TaskUpdate>? subscription;
    try {
      subscription = _updates().listen(_keep, onError: (Object _) {});
      await _resume();
      // The replay reaches the group callback synchronously inside the call,
      // and listeners of the broadcast fan-out (or of a host hub fed by
      // `FileDownloader().updates`) one event-loop turn later.
      await Future<void>.delayed(Duration.zero);
    } catch (error) {
      edgeAiLog('⚠️ BackgroundCompletions: replay failed: $error');
    } finally {
      await subscription?.cancel();
    }
  }

  void _keep(TaskUpdate update) {
    if (update is! TaskStatusUpdate) return;
    if (update.status != TaskStatus.complete) return;
    final task = update.task;
    if (task.group != _group) return;
    _byTaskId[task.taskId] = BackgroundCompletion(
      url: task.url,
      totalBytes: totalBytesOf(
        update.responseStatusCode,
        update.responseHeaders,
      ),
    );
  }

  /// The completion kept for [taskId] when a download of [url] may reuse its
  /// file, or null when it may not and the file is downloaded as before.
  ///
  /// Waits for [reconcile] first — triggering it when an install runs before
  /// core's own call at startup. Null when a task for [taskId] is live or
  /// paused ([isActive]: the existing attach or resume path handles it), when
  /// nothing was replayed for it, or when what was replayed downloaded another
  /// source under the same name. A completion is used once: taking it removes
  /// it, whatever the answer.
  Future<BackgroundCompletion?> takeFor(
    String taskId,
    String url, {
    required Future<bool> Function(String taskId) isActive,
  }) async {
    await reconcile();
    if (await isActive(taskId)) return null;
    final completion = _byTaskId.remove(taskId);
    if (completion == null || !sameNetworkUrl(completion.url, url)) {
      return null;
    }
    return completion;
  }
}
