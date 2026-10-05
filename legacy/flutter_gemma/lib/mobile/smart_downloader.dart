import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_gemma/core/domain/download_error.dart';
import 'package:flutter_gemma/core/domain/download_exception.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Decision for a failed download: whether to resume, do a fresh retry, or give
/// up. Extracted so the resume-attempt cap (#355) is unit-testable.
enum ResumeAction { resume, retry, giveUp }

@visibleForTesting
const int kMaxResumeAttempts = 3;

/// Watchdog window after a resume: if no progress/terminal event arrives within
/// this, the task is presumed silently dead (#355) and the stream is closed.
@visibleForTesting
const Duration kResumeWatchdog = Duration(seconds: 90);

/// Deterministic background_downloader task ID for a model download (#383/#2).
///
/// Derived only from the stable `Task.split` identity — NOT the url (so a rotated
/// signed URL still maps to the same partial) and NOT the absolute path (so an iOS
/// app-container UUID change on every update doesn't churn the id). `Object.hashCode`
/// is not a spec-stable key across runs/SDKs; sha256 of the triple is.
///
/// Not `@visibleForTesting`: it is a real internal API used in production by both
/// the download path and the reclaim reconciliation (`mobile_model_manager`).
String computeTaskId(BaseDirectory base, String directory, String filename) =>
    sha256.convert(utf8.encode('${base.name}|$directory|$filename')).toString();

/// Directory to hand background_downloader so the download lands exactly at
/// [targetPath].
///
/// [Task.split] maps an absolute path onto background_downloader's BaseDirectory
/// model, but a target NOT under one of its recognized bases falls back to
/// [BaseDirectory.root] with the drive/root STRIPPED from [splitDirectory]. The
/// case that bites us is Windows' `%LOCALAPPDATA%\flutter_gemma`: LocalAppData is
/// not a background_downloader base (path_provider maps applicationSupport →
/// Roaming, applicationDocuments → Documents), so split returns root +
/// `Users\..\AppData\Local\flutter_gemma`. On Windows the root base resolves to
/// `''` (not the drive), so the reconstructed filePath is `$CWD`-relative and the
/// file lands in the wrong place while getReadTargetPath / validateModelFiles
/// look at the absolute path — `install()` "succeeds" but `isModelInstalled()`
/// stays false. Return the ABSOLUTE directory for the root case so the file
/// lands at [targetPath].
///
/// Non-root (recognized-base) targets keep [splitDirectory] verbatim — that
/// value is stored on the [DownloadTask], and the reclaim path
/// (`mobile_model_manager`) RE-derives a task id from `DownloadTask.directory`
/// via [computeTaskId]; keeping it the relative, container-UUID-independent
/// split value is what keeps that recompute matching. (The task's own stored
/// `taskId` is derived from the split triple regardless of this function.) The
/// root case's absolute directory would make that recompute diverge, but it
/// never reaches it: the reclaim is Android-only and Android always resolves to
/// a recognized base, so it never takes the root fallback.
///
/// [context] is injected only by tests so Windows path semantics can be
/// exercised on a POSIX CI host; production uses the host [p.context] (Windows
/// on the affected platform), so `dirname` uses the correct separators.
@visibleForTesting
String resolveDownloadDirectory(
  BaseDirectory baseDirectory,
  String splitDirectory,
  String targetPath, {
  p.Context? context,
}) => baseDirectory == BaseDirectory.root
    ? (context ?? p.context).dirname(targetPath)
    : splitDirectory;

/// Returns a [Timer] that fires [onTimeout] after [timeout] unless cancelled.
/// The download loop cancels it when the next progress/status event arrives, and
/// wires [onTimeout] to close [progress] with a network error + cancel the
/// listener, so a silently-dead post-resume task can never hang forever.
@visibleForTesting
Timer armResumeWatchdog({
  required StreamController<int> progress,
  required void Function() onTimeout,
  Duration timeout = kResumeWatchdog,
}) {
  return Timer(timeout, onTimeout);
}

/// Whether a non-final, progress-less status should re-arm the resume
/// watchdog.
///
/// The blanket `_cancelResumeWatchdog` that runs before every status disarms
/// the only safety net, so a status that carries no progress and is not final
/// must put it back or the download can hang unbounded.
///
/// `enqueued` only counts once the task has already been seen PAUSED, and the
/// native ordering is worth writing down because it is the opposite of what it
/// looks like. The 9-minute slice emits `enqueued` -> `progress(-5)` ->
/// `paused`, not the other way round: `DownloadTaskRunner` AWAITS the
/// re-enqueue (`doEnqueue` is suspend, and posts `enqueued` itself) and only
/// then returns `paused`, which the runner's `finally` posts last. So `paused`
/// is the final word and arms the watchdog on its own.
///
/// Which leaves `enqueued` covering the resume-driven case only — and makes
/// gating it essential rather than cosmetic, because `enqueued` is ALSO emitted
/// on the very first enqueue. Arming there would put a 90-second deadline on
/// every download before it had a chance to start: WorkManager legitimately
/// holds a job enqueued while offline, in Doze, or behind other work, and iOS
/// defers a background transfer started while backgrounded. The watchdog does
/// not merely report — it cancels the task and deletes its resume data. A phone
/// in a tunnel would lose a multi-gigabyte partial and restart from zero.
@visibleForTesting
bool shouldRearmWatchdog(TaskStatus status, {required bool sawPause}) =>
    status == TaskStatus.paused || (status == TaskStatus.enqueued && sawPause);

/// The scheduling priority to use, given the real host OS.
///
/// Extracted so both arms are testable without pretending to be on another
/// platform. See [SmartDownloader.downloadPriority] for why they differ.
@visibleForTesting
int priorityForPlatform({required bool isAndroid}) => isAndroid ? 5 : 0;

/// Builds the `DownloadTask` for a model download.
///
/// Extracted so the shape can be asserted without a device — every field here
/// is load-bearing and every one of them failed silently when wrong:
///   * `group` must be [SmartDownloader.downloadGroup], the SAME constant
///     `registerCallbacks` uses. A drift between the two ends means the task
///     lands in a group nobody is registered for, `_emitStatusUpdate` finds no
///     callback and no `updates` listener, and the download hangs forever
///     while background_downloader merely logs a warning (#383's class).
///   * `updates` must include progress, or the download looks frozen at 0%.
///   * `retries: 0` because retries are handled here with HTTP-aware logic;
///     package-level retries would race that loop.
///   * `priority` — see [SmartDownloader.downloadPriority].
@visibleForTesting
DownloadTask buildModelDownloadTask({
  required String taskId,
  required String url,
  required String? token,
  required BaseDirectory baseDirectory,
  required String directory,
  required String filename,
  required bool allowPause,
}) => DownloadTask(
  taskId: taskId,
  url: url,
  group: SmartDownloader.downloadGroup,
  headers: {
    if (token != null) 'Authorization': 'Bearer $token',
    'Connection': 'keep-alive',
    // Attempt to work around CDN ETag issues
    'Cache-Control': 'no-cache, no-store',
    'Pragma': 'no-cache',
  },
  baseDirectory: baseDirectory,
  directory: directory,
  filename: filename,
  requiresWiFi: false,
  // Auto-detect: false for HuggingFace (weak ETags), true for others
  allowPause: allowPause,
  priority: SmartDownloader.downloadPriority,
  retries: 0,
  updates: Updates.statusAndProgress,
);

/// Turns a background_downloader progress value into a percentage, or null when
/// it is a STATE SENTINEL rather than progress.
///
/// The package signals state through negative values on the progress channel:
/// -1 failed, -2 canceled, -3 notFound, -4 waiting to retry, -5 paused. Clamping
/// those to 0 made the bar snap to 0% at every 9-minute WorkManager slice.
@visibleForTesting
int? percentFromProgress(double progress) =>
    progress < 0 ? null : (progress * 100).round().clamp(0, 100);

/// Whether [_ensureConfigured] should register a running [TaskNotification]
/// for the given [foreground] setting (#356). Extracted as a pure function so
/// the decision is unit-testable without a `FileDownloader` seam: on Android,
/// `background_downloader` only calls `WorkManager.setForeground()` — the
/// thing that actually activates the foreground service — when a `running`
/// notification is configured. Setting `Config.runInForeground` alone is a
/// no-op without it.
///
/// Scoped to the EXPLICIT `foreground: true` flag only (#357 review). The
/// notification, once configured, is global: `background_downloader`'s
/// `Notifications.kt` shows it for every task in the `running` state,
/// including ones that are NOT running in foreground
/// (`displayNotification`'s `else` branch calls `notify()` unconditionally
/// when `runInForeground` is false for that task). Returning true for the
/// auto-detect branch (`foreground == null`) would therefore show a
/// "Downloading model" notification on EVERY download — including small
/// ones, where none showed before.
///
/// The consequence is that the auto-detect branch has NO foreground service at
/// all: `canRunInForeground` requires both a size threshold AND a running
/// notification, so declining the notification declines the service with it.
/// The size threshold on its own does nothing, and has not since #357 — the
/// docs that promised otherwise were wrong. `foreground: true` is the only way
/// to get one.
@visibleForTesting
bool shouldConfigureForegroundNotification(bool? foreground) =>
    foreground == true;

/// Pure decision for [_handleFailedDownload]. Resume is only chosen while under
/// [maxResumeAttempts] — the old code resumed unconditionally whenever
/// `canResume`, which let a repeatedly-failing resume loop forever (#355).
@visibleForTesting
ResumeAction decideFailedDownloadAction({
  required bool canResume,
  required int resumeAttempt,
  required int currentAttempt,
  required int maxRetries,
  required int maxResumeAttempts,
}) {
  if (canResume && resumeAttempt < maxResumeAttempts) {
    return ResumeAction.resume;
  }
  if (currentAttempt < maxRetries) {
    return ResumeAction.retry;
  }
  return ResumeAction.giveUp;
}

/// Smart downloader with HTTP-aware retry logic
///
/// Features:
/// - HTTP-aware retry: Auth errors (401/403/404) fail after 1 attempt
/// - Transient errors (network/5xx) retry up to maxRetries times
/// - Exponential backoff strategy
/// - Completer-based waiting for completion
/// - Progress tracking with Updates.statusAndProgress
/// - Works with ANY URL (HuggingFace, Google Drive, custom servers, etc.)
/// - Supports multiple concurrent downloads
/// - Auto-detects resume support based on server (HuggingFace = no resume)
/// - Android foreground service for large files, opt in with `foreground: true`
/// Raised when the download-updates fan-out is torn down while a download is
/// still in flight — i.e. the host called `FlutterGemma.dispose()`/`reset()`.
///
/// A distinct type because it must NOT be retried: the generic `catch` in
/// `_downloadWithSmartRetry` treats anything else as transient and restarts,
/// which turned one dispose into up to `maxRetries` restarts of a
/// multi-gigabyte download — each one re-registering the group callbacks two
/// seconds later, so the teardown did not hold either.
class DownloadUpdatesReleasedException implements Exception {
  const DownloadUpdatesReleasedException(this.taskId);

  final String taskId;

  @override
  String toString() =>
      'Download updates were released while task $taskId was still running '
      '(FlutterGemma.dispose() or reset() during a download)';
}

class SmartDownloader {
  /// The background_downloader task group ALL model downloads run under.
  /// Single source of truth — cleanup / resume code that queries or resets
  /// tasks must use this exact group, or it operates on an empty set and
  /// silently no-ops (this is what caused the #383 leak amplifier: three call
  /// sites used the stale literal `'flutter_gemma_downloads'`).
  static const String downloadGroup = 'smart_downloads';

  /// Scheduling priority for model downloads — and it must differ per platform.
  ///
  /// background_downloader documents `0 <= priority <= 10 with 0 being the
  /// HIGHEST`, default 5. This was **10** everywhere, which on iOS is actively
  /// harmful and on Android is inert.
  ///
  /// **iOS** maps it straight onto URLSession: `BDPlugin.swift` does
  /// `urlSessionDownloadTask.priority = 1 - Float(task.priority) / 10`. So 10
  /// produced `0.0` — below `URLSessionTask.lowPriority` (0.25) — for a
  /// multi-gigabyte download the user is watching. 0 gives 1.0.
  ///
  /// **Android** uses priority for exactly two things: the holding queue, which
  /// this package never enables, and `expedited = priority < 5` in
  /// `BDPlugin.kt`. Expedited is the wrong trade for a 2-4 GB transfer, for two
  /// independent reasons:
  ///
  ///   * it SHORTENS the OS execution guarantee from 10 minutes to 3.
  ///     `JobSchedulerService` defines `RUNTIME_MIN_GUARANTEE_MS` = 10 min and
  ///     `RUNTIME_MIN_EJ_GUARANTEE_MS` = 3 min, and caps expedited at the
  ///     regular figure; developer.android.com says expedited work is for
  ///     "short" tasks. Expedited work also draws on a separate 24-hour
  ///     budget.
  ///   * it currently hangs the download outright. WorkManager caps a task at 9
  ///     minutes; background_downloader survives that by pausing and
  ///     RE-ENQUEUING with `initialDelayMillis = 1000`. The re-enqueue sets
  ///     `setInitialDelay` and, below priority 5, `setExpedited` on the same
  ///     builder, and `WorkRequest.Builder.build()` throws
  ///     `IllegalArgumentException: Expedited jobs cannot be delayed`. The
  ///     throw is swallowed to a `Log.w`, `doEnqueue`'s `false` is discarded,
  ///     and the runner returns `TaskStatus.paused` anyway.
  ///
  /// Note the crash is only reachable for RESUMABLE downloads. HuggingFace
  /// serves weak ETags, so `allowPause` is false for those URLs and the native
  /// side fails outright at 9 minutes rather than pausing and re-enqueuing —
  /// which is every URL in the example app. Anyone trying to reproduce the hang
  /// against a HuggingFace model will not see it and may conclude this was
  /// unnecessary. Self-hosted, GCS, Firebase Storage and Kaggle URLs do resume,
  /// and those are the ones that hang.
  ///
  /// So the correct Android value is the highest that is NOT expedited: 5, the
  /// package default. Against the old 10 this changes nothing observable on
  /// Android — priority there is inert outside the holding queue — which is
  /// the point: 10 cost nothing, and anything below 5 would.
  ///
  /// On the package author's suggestion of 0: it was offered on the grounds
  /// that it triggers Android's User Initiated Data Transfer, which has no
  /// 9-minute limit. That is not what the shipped code does — his own open
  /// PR #710 says `setUserInitiated(true)` was never called on the JobInfo —
  /// and the expedited crash is his open PR #709. Revisit both when they land.
  ///
  /// Keyed off `Platform.isAndroid`, NOT `defaultTargetPlatform`: the latter is
  /// a UI-intent signal that a host can legitimately override with
  /// `debugDefaultTargetPlatformOverride` to preview Cupertino, and doing that
  /// in a debug build on a real Android phone would hand this an iOS answer.
  static int get downloadPriority =>
      priorityForPlatform(isAndroid: Platform.isAndroid);

  // Track if FileDownloader has been configured
  static bool _isConfigured = false;
  static bool? _lastForegroundSetting;

  /// Configure FileDownloader for foreground mode
  ///
  /// [foreground]:
  /// - null: NO foreground service (no notification is configured)
  /// - true: always use foreground
  /// - false: never use foreground
  static Future<void> _ensureConfigured(bool? foreground) async {
    // Only reconfigure if setting changed
    if (_isConfigured && _lastForegroundSetting == foreground) return;

    final downloader = FileDownloader();

    if (foreground == true) {
      // Always foreground
      await downloader.configure(
        androidConfig: [(Config.runInForeground, Config.always)],
      );
      gemmaLog('📲 SmartDownloader: Configured for ALWAYS foreground');
    } else if (foreground == false) {
      // Never foreground
      await downloader.configure(
        androidConfig: [(Config.runInForeground, Config.never)],
      );
      gemmaLog('📲 SmartDownloader: Configured for NEVER foreground');
    } else {
      // Deliberately writes NOTHING on the default path.
      //
      // `Config.runInForegroundIfFileLargerThan` is persisted by the plugin to
      // the app's default SharedPreferences — process-wide, surviving process
      // death and reboot, shared with the host's own downloads and with no
      // getter to read it back. And it could never take effect for us here:
      // `TaskRunner` needs `runInForegroundFileSize >= 0 AND
      // notificationConfig?.running != null`, and this branch deliberately
      // configures no notification (#357). So the old write bought nothing and
      // silently overwrote whatever the host had chosen — the same overreach
      // as #445.
      //
      // If the host has its own default notification config with a `running`
      // notification, our tasks inherit it and the host's own threshold
      // applies, which is the correct owner.
      gemmaLog(
        '📲 SmartDownloader: AUTO foreground — leaving the app-wide '
        'runInForeground config untouched',
      );
    }

    // #356: `Config.runInForeground`/`runInForegroundIfFileLargerThan` alone
    // never activates Android's real foreground service — the plugin only
    // calls `WorkManager.setForeground()` once a `running` notification is
    // configured. Without this, `foreground: true` was a no-op: no
    // notification, no setForeground() call, no Doze/battery-optimization
    // exemption. This does NOT touch WorkManager's separate 9-minute
    // `TaskRunner` timeout (#192) — that limit is unrelated and unchanged.
    //
    // Scoped to `foreground == true` only (#357 review) — see
    // shouldConfigureForegroundNotification's doc comment for why the
    // auto-detect (`null`) branch is intentionally excluded.
    if (shouldConfigureForegroundNotification(foreground)) {
      // ForGroup, not the bare form: `configureNotification` installs a config
      // with `taskOrGroup: null` — the DEFAULT — which every task in the
      // process then falls back to, including the host's own downloads, and
      // nothing ever removes it. Same class of overreach as #445 itself.
      downloader.configureNotificationForGroup(
        downloadGroup,
        running: const TaskNotification('Downloading model', '{filename}'),
        progressBar: true,
      );

      // #357 review (Bug 2): on Android 13+ (API 33), background_downloader's
      // `displayNotification()` bails out BEFORE calling `setForeground()` if
      // `POST_NOTIFICATIONS` isn't granted at RUNTIME — declaring it in the
      // manifest alone is necessary but not sufficient, so the foreground
      // service would silently fail to activate. Request it proactively here
      // so a foreground download actually gets the exemption it asked for.
      // Best-effort: don't block/fail the download on a denial, just log it.
      // This is a no-op that resolves to `granted` on platforms/versions that
      // don't need the permission (e.g. desktop, pre-Android-13).
      //
      // #357 review round 2 (Bug C): the native permission callback can, in
      // principle, never arrive (app backgrounded mid-dialog, config change),
      // which would hang this await forever and block the WHOLE download from
      // starting. A 10s timeout guarantees this always resolves; `requestError`
      // is treated the same as any other not-granted status below (Bug B).
      PermissionStatus status;
      try {
        status = await downloader.permissions
            .request(PermissionType.notifications)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => PermissionStatus.requestError,
            );
      } catch (e) {
        // Distinguishable from a normal denial (#357 review minor): this is an
        // unexpected throw from the request call itself, not a user decision.
        gemmaLog(
          '❌ SmartDownloader: POST_NOTIFICATIONS request threw (not a denial): $e',
        );
        status = PermissionStatus.requestError;
      }

      gemmaLog('📲 SmartDownloader: POST_NOTIFICATIONS request → $status');

      // #357 review (Bug B): `gemmaLog` is a no-op in release builds
      // (`if (!kDebugMode) return`), so the line above gives ZERO signal in
      // release when the permission is denied. Without POST_NOTIFICATIONS,
      // the foreground service never activates (see the comment above) and a
      // long background download may be killed by the OS — surface that as a
      // clearly distinguishable warning rather than silently degrading.
      if (status != PermissionStatus.granted) {
        gemmaLog(
          '⚠️ SmartDownloader: POST_NOTIFICATIONS not granted ($status) — '
          'foreground service will NOT activate; a long background download '
          'may be killed. Have the host app pre-request POST_NOTIFICATIONS.',
        );
      }
    }

    _isConfigured = true;
    _lastForegroundSetting = foreground;
  }

  /// Check if URL is from HuggingFace CDN (uses weak ETag, resume not reliable)
  static bool _isHuggingFaceUrl(String url) {
    return url.contains('huggingface.co') ||
        url.contains('cdn-lfs.huggingface.co') ||
        url.contains('cdn-lfs-us-1.huggingface.co') ||
        url.contains('cdn-lfs-eu-1.huggingface.co');
  }

  /// Fan-out for THIS package's download updates, fed by group-scoped
  /// callbacks rather than by listening to `FileDownloader().updates`.
  ///
  /// #445: `FileDownloader().updates` is a SINGLE-SUBSCRIPTION controller
  /// (`var updates = StreamController<TaskUpdate>()` in base_downloader). Taking
  /// its one subscription — which `asBroadcastStream()` does — means every later
  /// `FileDownloader().updates.listen(...)`, in the host app or in any other
  /// package, throws "Stream has already been listened to". Merely depending on
  /// flutter_gemma made background_downloader unusable for the app's own
  /// downloads.
  ///
  /// `registerCallbacks(group:)` is the supported alternative and is a strict
  /// narrowing rather than a workaround: `_emitStatusUpdate` consults
  /// `groupStatusCallbacks[task.group]` BEFORE `updates.hasListener`, so we
  /// receive exactly what we received before, minus other people's tasks —
  /// which every listen site here already discarded by taskId.
  static StreamController<TaskUpdate>? _groupUpdates;

  /// Optional hub stream configured at init (e.g. host cache client forwarder).
  static Stream<TaskUpdate>? _configuredDownloadUpdatesStream;

  /// Memoized broadcast wrapper for [_configuredDownloadUpdatesStream].
  static Stream<TaskUpdate>? _configuredBroadcastStream;

  /// Registers a shared download-updates stream for all SmartDownloader
  /// paths (new downloads and attach-to-existing).
  ///
  /// [stream] may be single- or broadcast; non-broadcast sources are
  /// wrapped with [Stream.asBroadcastStream] so concurrent downloads can
  /// each call [Stream.listen].
  static void configureDownloadUpdatesStream(Stream<TaskUpdate>? stream) {
    _configuredDownloadUpdatesStream = stream;
    _configuredBroadcastStream = null;
    // A hub and our group callback cannot coexist. Group callbacks outrank the
    // `updates` stream in background_downloader's dispatch, so an orphaned
    // registration left over from an earlier download would keep intercepting
    // our tasks and the host's hub — fed by `updates` — would receive nothing
    // at all, hanging every download that resolved to it.
    // NOT absorbing here. A hub is the host saying "route flutter_gemma's
    // updates to me", and group callbacks outrank the `updates` stream that
    // feeds it — so leaving any callback registered, even a silent one, starves
    // the hub and hangs every download that resolves to it. Which is precisely
    // the hazard this call exists to prevent.
    if (stream != null) _releaseGroupFanOut(absorb: false);
  }

  /// Clears injected hub configuration (e.g. registry reset / dispose).
  ///
  /// Also releases the group callbacks, so a host that disposes flutter_gemma
  /// gets `background_downloader` back in the state it found it — our group
  /// entry removed, its `updates` stream never having been touched.
  static void clearConfiguration() {
    _configuredDownloadUpdatesStream = null;
    _configuredBroadcastStream = null;
    // A host `FileDownloader().destroy()` clears `notificationConfigs` as well
    // as the callback map, and `_ensureConfigured` short-circuits on
    // `_isConfigured` — so without this a later `foreground: true` download
    // silently loses its notification, and with it the foreground service.
    _isConfigured = false;
    // absorb: the host is tearing us down, and a task we enqueued may still be
    // running. With no callback its updates fall through to
    // `FileDownloader().updates` and the host starts receiving tasks it has
    // never heard of.
    _releaseGroupFanOut(absorb: true);
  }

  /// Closes the fan-out and leaves a silent sink registered for our group.
  ///
  /// Closing is deliberate and NOT inert for in-flight downloads: live
  /// listeners get `onDone`, which becomes a
  /// [DownloadUpdatesReleasedException] and terminates the download rather than
  /// retrying it.
  ///
  /// [absorb] decides what replaces us, and the two callers want opposites.
  ///
  /// On teardown, a native task we enqueued can still be running, and with no
  /// group callback its updates fall through to `FileDownloader().updates` — so
  /// the host would start receiving tasks it has never heard of. That is #445 in
  /// reverse, and a silent sink absorbs them for one map entry.
  ///
  /// When a hub is installed, the host is asking for the opposite: route our
  /// updates to it. Group callbacks outrank the `updates` stream that feeds the
  /// hub, so ANY callback left registered — including the silent one — starves
  /// it and hangs every download that resolves to it.
  static void _releaseGroupFanOut({required bool absorb}) {
    final controller = _groupUpdates;
    _groupUpdates = null;
    if (absorb) {
      FileDownloader().registerCallbacks(
        group: downloadGroup,
        taskStatusCallback: _absorb,
        taskProgressCallback: _absorb,
      );
    } else {
      // Unconditional: an earlier teardown may have left a sink behind even
      // though `_groupUpdates` is already null, and that sink would outlive
      // this call and starve the hub.
      FileDownloader().unregisterCallbacks(group: downloadGroup);
    }
    unawaited(controller?.close());
  }

  static void _absorb(TaskUpdate update) {}

  @visibleForTesting
  static void resetDownloadUpdatesStreamConfig() => clearConfiguration();

  /// Whether the group-scoped fan-out is currently live.
  ///
  /// Exposes lifecycle only — the property that actually matters (#445) is that
  /// `FileDownloader().updates` stays listenable for the host, and that is
  /// asserted directly rather than through this.
  @visibleForTesting
  static bool get debugGroupFanOutIsLive {
    final c = _groupUpdates;
    return c != null && !c.isClosed;
  }

  @visibleForTesting
  static Stream<TaskUpdate> debugResolveUpdatesStream() =>
      _resolveUpdatesStream();

  static Stream<TaskUpdate> _getUpdatesStream() {
    // Broadcast, because concurrent downloads each call listen(). Never closed
    // on last-listener-cancel: downloads come and go, and a closed controller
    // would leave the registered callbacks writing into nothing.
    var controller = _groupUpdates;
    if (controller == null || controller.isClosed) {
      controller = StreamController<TaskUpdate>.broadcast();
      _groupUpdates = controller;
    }
    final live = controller;

    void forward(TaskUpdate update) {
      if (live.isClosed) return;
      if (!live.hasListener) {
        // background_downloader used to log exactly this ("no callback
        // registered, and no listener to the updates stream"). By registering a
        // callback we silence its warning, so we owe the equivalent — a
        // download whose updates go nowhere looks identical to a stalled one
        // until a watchdog fires 90s later.
        gemmaLog(
          '⚠️ SmartDownloader: dropping ${update.runtimeType} for '
          '${update.task.taskId} — no listener attached',
        );
        return;
      }
      live.add(update);
    }

    // Registered on EVERY call, not once at controller creation. The callback
    // map belongs to background_downloader, not to us: `FileDownloader().destroy()`
    // clears it (base_downloader `groupStatusCallbacks.clear()`), and a host may
    // call `unregisterCallbacks` itself. Either leaves our controller open and
    // healthy-looking while nothing is routed to it any more — every later
    // download would then hang at `await completer.future` with no error, which
    // is the failure this whole file's watchdog machinery exists to avoid.
    // Re-registering is an idempotent map write, so it is free to repeat.
    FileDownloader().registerCallbacks(
      group: downloadGroup,
      taskStatusCallback: forward,
      taskProgressCallback: forward,
    );
    return live.stream;
  }

  static Stream<TaskUpdate> _resolveUpdatesStream() {
    final source = _configuredDownloadUpdatesStream;
    if (source != null) {
      _configuredBroadcastStream ??= source.isBroadcast
          ? source
          : source.asBroadcastStream();
      return _configuredBroadcastStream!;
    }
    return _getUpdatesStream();
  }

  /// Downloads a file with smart retry logic and HTTP-aware error handling
  ///
  /// [url] - File URL (any server)
  /// [targetPath] - Local file path to save to
  /// [token] - Optional authorization token (e.g., HuggingFace, custom auth)
  /// [maxRetries] - Maximum number of retry attempts for transient errors (default: 10)
  /// [cancelToken] - Optional token for cancellation
  /// Note: Auth errors (401/403/404) fail after 1 attempt, regardless of maxRetries.
  /// Only network errors and server errors (5xx) will be retried up to maxRetries times.
  ///
  /// This method waits for completion without progress tracking.
  /// For progress tracking, use [downloadWithProgress] instead.
  ///
  /// Throws [DownloadCancelledException] if cancelled via cancelToken.
  static Future<void> download({
    required String url,
    required String targetPath,
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
  }) async {
    final completer = Completer<void>();

    // Use downloadWithProgress but just wait for completion
    downloadWithProgress(
      url: url,
      targetPath: targetPath,
      token: token,
      maxRetries: maxRetries,
      cancelToken: cancelToken,
    ).listen(
      (_) {}, // Ignore progress updates
      onError: (error) => completer.completeError(error),
      onDone: () => completer.complete(),
      cancelOnError: true,
    );

    return completer.future;
  }

  /// Downloads a file with smart retry logic and HTTP-aware error handling
  ///
  /// [url] - File URL (any server)
  /// [targetPath] - Local file path to save to
  /// [token] - Optional authorization token (e.g., HuggingFace, custom auth)
  /// [maxRetries] - Maximum number of retry attempts for transient errors (default: 10)
  /// [cancelToken] - Optional token for cancellation
  /// [foreground] - Android foreground service mode:
  ///   - null (default): NO foreground service (no notification is configured)
  ///   - true: always use foreground (shows notification)
  ///   - false: never use foreground
  ///
  /// Note: Auth errors (401/403/404) fail after 1 attempt, regardless of maxRetries.
  /// Only network errors and server errors (5xx) will be retried up to maxRetries times.
  /// Returns a stream of progress percentages (0-100)
  ///
  /// The stream will emit [DownloadCancelledException] if cancelled via cancelToken.
  static Stream<int> downloadWithProgress({
    required String url,
    required String targetPath,
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) {
    final progress = StreamController<int>();
    StreamSubscription? currentListener;
    StreamSubscription? cancellationListener;
    String? currentTaskId; // ← ADD: Store task ID for cancellation

    // Listen for cancellation
    if (cancelToken != null) {
      cancellationListener = cancelToken.whenCancelled.asStream().listen((
        _,
      ) async {
        gemmaLog('🚫 Cancellation requested');

        // Cancel the actual download task
        if (currentTaskId != null) {
          gemmaLog('🚫 Cancelling task: $currentTaskId');
          try {
            await FileDownloader().cancelTaskWithId(
              currentTaskId!,
            ); // ← ADD: Actually cancel the task
          } catch (e) {
            gemmaLog('⚠️ Failed to cancel task: $e');
          }
          // Also clear any pending resume watchdog so a cancelled download
          // doesn't leave a Timer holding the (now-closed) progress stream
          // alive for up to 90s.
          _cancelResumeWatchdog(currentTaskId!);
        }

        if (!progress.isClosed) {
          progress.addError(
            DownloadCancelledException(
              cancelToken.cancelReason ?? 'Download cancelled',
              StackTrace.current,
            ),
          );
          progress.close();
        }
        currentListener?.cancel();
        cancellationListener?.cancel();
      });
    }

    // Configure FileDownloader and start download
    _ensureConfigured(foreground)
        .then((_) async {
          await _downloadWithSmartRetry(
            url: url,
            targetPath: targetPath,
            token: token,
            maxRetries: maxRetries,
            progress: progress,
            currentAttempt: 1,
            currentListener: currentListener,
            cancelToken: cancelToken,
            onListenerCreated: (listener) {
              currentListener = listener;
            },
            onTaskCreated: (taskId) {
              currentTaskId = taskId;
            },
          );
        })
        .catchError((Object e, StackTrace st) {
          // If _ensureConfigured() or a synchronous failure in
          // _downloadWithSmartRetry throws, surface it on the progress stream
          // and close it — otherwise the caller's `await for` over
          // progress.stream hangs forever (the silent-hang class this hub work
          // exists to prevent).
          if (!progress.isClosed) {
            progress.addError(e, st);
            progress.close();
          }
        })
        .whenComplete(() {
          // Clean up cancellation listener when download completes
          cancellationListener?.cancel();
        });

    return progress.stream;
  }

  static Future<void> _downloadWithSmartRetry({
    required String url,
    required String targetPath,
    String? token,
    required int maxRetries,
    required StreamController<int> progress,
    required int currentAttempt,
    StreamSubscription? currentListener,
    CancelToken? cancelToken,
    void Function(StreamSubscription)? onListenerCreated,
    void Function(String taskId)? onTaskCreated, // ← ADD: Callback for task ID
    int resumeAttempt = 0,
  }) async {
    // Mutable so the SAME listener can bump it across successive resume
    // rounds for this task (#355): a resume keeps this listener active, and
    // the next `TaskStatus.failed` for it must see a higher resumeAttempt so
    // decideFailedDownloadAction() eventually falls through to retry/giveUp
    // instead of resuming forever. A fresh retry recurses into a NEW call of
    // this method with a fresh `resumeAttempt: 0` scope — it must NOT reuse
    // this local.
    var localResumeAttempt = resumeAttempt;
    // Check cancellation before starting
    try {
      cancelToken?.throwIfCancelled();
    } catch (e) {
      if (!progress.isClosed) {
        progress.addError(e);
        progress.close();
      }
      return;
    }

    // taskId + task location come from the same stable split triple; compute
    // inside the try so a path_provider failure routes to the retry/backoff
    // catch below rather than escaping the retry loop.
    late final String taskId;
    late final BaseDirectory baseDirectory;
    late final String directory;
    late final String filename;

    gemmaLog(
      '🔵 _downloadWithSmartRetry called - attempt $currentAttempt/$maxRetries',
    );
    gemmaLog('🔵 URL: $url');
    gemmaLog('🔵 Target: $targetPath');

    // Declare listener outside try block so it's accessible in catch
    StreamSubscription? listener;

    try {
      (baseDirectory, directory, filename) = await Task.split(
        filePath: targetPath,
      );
      taskId = computeTaskId(baseDirectory, directory, filename);
      gemmaLog('🔵 TaskId: $taskId');

      // Directory background_downloader will actually write into — corrected
      // for the root-fallback case (Windows %LOCALAPPDATA%). The stored `taskId`
      // above is unchanged; see [resolveDownloadDirectory] for the taskId /
      // reclaim invariants.
      final downloadDirectory = resolveDownloadDirectory(
        baseDirectory,
        directory,
        targetPath,
      );

      final downloader = FileDownloader();

      // Check if task already exists (e.g., after app restart or sleep/wake)
      final existingTask = await downloader.taskForId(taskId);
      if (existingTask != null) {
        gemmaLog(
          '🔵 Task $taskId already in progress, attaching to existing...',
        );

        // Create completer to wait for existing task completion
        final completer = Completer<void>();
        // Set on the first `paused`; gates whether a later `enqueued` counts as
        // the 9-minute re-enqueue rather than an initial one.
        var sawPause = false;

        // Attach listener to existing task
        listener = _resolveUpdatesStream().listen(
          (update) async {
            if (update.task.taskId != taskId) return;

            if (update is TaskProgressUpdate) {
              // A live event means the task is not dead — cancel any pending
              // resume watchdog so a normally-progressing task never false-fires (#355).
              final percents = percentFromProgress(update.progress);
              // Disarm only for REAL progress. A sentinel is not evidence of
              // life, and disarming on one relies on a later status re-arming —
              // true today, but an ordering dependency with nothing holding it.
              if (percents == null) return;
              _cancelResumeWatchdog(update.task.taskId);
              gemmaLog('📊 Progress (existing): $percents%');
              if (!progress.isClosed) {
                progress.add(percents);
              }
            } else if (update is TaskStatusUpdate) {
              _cancelResumeWatchdog(update.task.taskId);
              gemmaLog('📡 TaskStatusUpdate (existing): ${update.status}');
              if (update.status == TaskStatus.complete) {
                if (!progress.isClosed) {
                  progress.add(100);
                  progress.close();
                }
                await listener?.cancel();
                // Not verified reachable for double-complete on the reattach
                // path (unlike the fresh-task listener above), but guarded
                // anyway for hygiene/consistency (#357 review, Bug A).
                if (!completer.isCompleted) completer.complete();
              } else if (update.status == TaskStatus.failed ||
                  update.status == TaskStatus.canceled) {
                // Existing task failed - let caller handle retry
                if (!progress.isClosed) {
                  progress.addError(
                    DownloadException(
                      DownloadError.network(
                        'Existing download failed: ${update.status}',
                      ),
                    ),
                  );
                  progress.close();
                }
                await listener?.cancel();
                if (!completer.isCompleted) completer.complete();
              } else if (update.status == TaskStatus.notFound) {
                // FINAL state — nothing further will ever arrive. Grouping it
                // with `paused` and re-arming a watchdog would stall a plain
                // 404 for 90 seconds and then report it as a network timeout,
                // which is the most common real support case (gated or renamed
                // HuggingFace URL) told the least useful thing.
                if (!progress.isClosed) {
                  progress.addError(
                    DownloadException(const DownloadError.notFound()),
                  );
                  progress.close();
                }
                await listener?.cancel();
                if (!completer.isCompleted) completer.complete();
              } else if (update.status == TaskStatus.paused ||
                  update.status == TaskStatus.enqueued) {
                if (update.status == TaskStatus.paused) sawPause = true;
                if (!shouldRearmWatchdog(update.status, sawPause: sawPause)) {
                  return;
                }
                // Neither is final and neither carries progress, and the
                // blanket `_cancelResumeWatchdog` above has just disarmed the
                // only safety net for both. See shouldRearmWatchdog for why
                // `enqueued` is gated on a prior `paused`. If
                // that re-enqueued job is deferred — Doze, a metered-network
                // constraint, quota — no further event ever arrives. Without a
                // re-arm on BOTH, the sequence paused[arm] -> enqueued[disarm]
                // leaves the download hanging unbounded with no error at all.
                gemmaLog(
                  '⏸️ ${update.status} (existing) — re-arming resume watchdog',
                );
                _armResumeWatchdog(
                  taskId: taskId,
                  progress: progress,
                  listener: listener,
                  onSettle: () {
                    if (!completer.isCompleted) completer.complete();
                  },
                );
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) async {
            if (!progress.isClosed) {
              progress.addError(error, stackTrace);
              progress.close();
            }
            await listener?.cancel();
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.completeError(
                DownloadUpdatesReleasedException(taskId),
                StackTrace.current,
              );
            }
          },
        );

        onListenerCreated?.call(listener);
        onTaskCreated?.call(taskId);

        // A paused/killed-mid-download task emits nothing until resumed. The
        // attach path used to only listen → the watchdog fired → a permanent
        // wedge (#383/R1). Resume it so it actually makes progress.
        //
        // Resumed AFTER the listener is attached, not before (#445 review).
        // `resume()` is a platform round trip, and the fan-out discards
        // anything emitted while nobody is listening — so a terminal
        // `complete` landing in that window would be lost, the 90s watchdog
        // would fire, and it would cancel a download that had actually
        // finished, delete its resume data, and restart a multi-gigabyte
        // transfer from zero. The fresh-enqueue path already listens first;
        // this brings the reattach path in line.
        if (existingTask is DownloadTask &&
            await downloader.taskCanResume(existingTask)) {
          gemmaLog('🔵 Existing task $taskId is resumable — resuming');
          await downloader.resume(existingTask);
        }

        // #357 review (Bug E): arm the resume watchdog here too. `retries: 0`
        // means an `existingTask` reattach is effectively always a persisted
        // PAUSED task (paused multi-GB downloads surviving an app restart are
        // a common path) — without a watchdog, a reattached task that goes
        // completely silent (no event ever arrives) hangs at
        // `await completer.future` below forever. The listener above already
        // calls `_cancelResumeWatchdog` on every real
        // TaskProgressUpdate/TaskStatusUpdate, so a live task disarms this
        // immediately; only a truly silent one lets it fire.
        // Not if the task already finished during resume()'s round trip: the
        // taskId is a deterministic hash of (base, directory, filename), so a
        // stale timer firing 90s later would cancel and delete the resume data
        // of a NEW download of the same model.
        if (!completer.isCompleted) {
          _armResumeWatchdog(
            taskId: taskId,
            progress: progress,
            listener: listener,
            onSettle: () {
              if (!completer.isCompleted) completer.complete();
            },
          );
        }

        await completer.future;
        return;
      }

      // Auto-detect allowPause based on URL
      // HuggingFace uses weak ETags - resume not reliable
      // Other servers (GCS, Kaggle, custom) - resume usually works
      final allowPause = !_isHuggingFaceUrl(url);
      gemmaLog(
        '🔵 allowPause: $allowPause (HuggingFace: ${_isHuggingFaceUrl(url)})',
      );

      final task = buildModelDownloadTask(
        taskId: taskId,
        url: url,
        token: token,
        baseDirectory: baseDirectory,
        directory: downloadDirectory,
        filename: filename,
        allowPause: allowPause,
      );

      // Create a completer to wait for download completion
      final completer = Completer<void>();
      // Set on the first `paused`; gates whether a later `enqueued` counts as
      // the 9-minute re-enqueue rather than an initial one.
      var sawPause = false;

      // Listen to broadcast stream to get full status info including HTTP code
      // Using broadcast stream allows multiple downloads and retries
      listener = _resolveUpdatesStream().listen(
        (update) async {
          if (update.task.taskId != task.taskId) return;

          gemmaLog(
            '📡 Received update for task ${task.taskId}: ${update.runtimeType}',
          );

          if (update is TaskProgressUpdate) {
            // A live event means the task is not dead — cancel any pending
            // resume watchdog so a normally-progressing task never false-fires (#355).
            final percents = percentFromProgress(update.progress);
            // Disarm only for REAL progress — see the reattach listener.
            if (percents == null) return;
            _cancelResumeWatchdog(update.task.taskId);
            gemmaLog('📊 Progress: $percents%');
            if (!progress.isClosed) {
              progress.add(percents);
            }
          } else if (update is TaskStatusUpdate) {
            _cancelResumeWatchdog(update.task.taskId);
            gemmaLog(
              '📡 TaskStatusUpdate: ${update.status}, HTTP: ${update.responseStatusCode}',
            );

            switch (update.status) {
              case TaskStatus.complete:
                if (!progress.isClosed) {
                  progress.add(100);
                  progress.close();
                }
                await listener?.cancel();
                // #357 review (Bug A): guarded against double-complete — a
                // fresh retry reuses the same taskId, so this listener can
                // still be alive when the retried task's terminal event also
                // lands on the shared broadcast stream, completing the same
                // completer twice (uncaught zone error) without this guard.
                if (!completer.isCompleted) completer.complete();
                break;

              case TaskStatus.failed:
                gemmaLog('🔴 SmartDownloader: TaskStatus.failed detected');
                gemmaLog(
                  '🔴 HTTP Status Code from update: ${update.responseStatusCode}',
                );
                gemmaLog('🔴 Exception: ${update.exception}');
                gemmaLog('🔴 Progress closed: ${progress.isClosed}');
                gemmaLog('🔴 Current attempt: $currentAttempt');

                // Try to get HTTP code from multiple sources
                int? httpCode = update.responseStatusCode;

                // If not in responseStatusCode, check exception
                if (httpCode == null && update.exception != null) {
                  if (update.exception is TaskHttpException) {
                    httpCode = (update.exception as TaskHttpException)
                        .httpResponseCode;
                    gemmaLog(
                      '🔴 HTTP Status Code from TaskHttpException: $httpCode',
                    );
                  }
                }

                // Capture-and-increment SYNCHRONOUSLY (before the await) rather
                // than after it returns (#357 review): a broadcast stream's
                // onData handlers don't serialize, so a second `failed`/
                // `notFound` event for this task could interleave with this
                // await and read the stale (pre-increment) counter. Bumping it
                // here — before yielding control — guarantees two concurrent
                // failed events for this task always see DIFFERENT
                // resumeAttempt values. If the call turns out NOT to have
                // triggered a resume, give the slot back so a non-resume
                // failure never consumes budget it didn't use.
                final attemptForThisRound = localResumeAttempt;
                localResumeAttempt++;

                final resumePending = await _handleFailedDownload(
                  task: task,
                  downloader: downloader,
                  url: url,
                  targetPath: targetPath,
                  token: token,
                  maxRetries: maxRetries,
                  progress: progress,
                  currentAttempt: currentAttempt,
                  httpStatusCode: httpCode,
                  currentListener: listener,
                  cancelToken: cancelToken,
                  onListenerCreated: onListenerCreated,
                  onTaskCreated: onTaskCreated,
                  resumeAttempt: attemptForThisRound,
                  onSettle: () {
                    // Watchdog fire is a terminal outcome for this round —
                    // settle the completer so the outer
                    // `.whenComplete(() => cancellationListener?.cancel())`
                    // in downloadWithProgress runs (#357 review fix: was
                    // never called before, leaking the subscription).
                    if (!completer.isCompleted) completer.complete();
                  },
                );

                // Only cleanup if no resume is pending
                // If resume was triggered, we need to keep listening for the result
                if (!resumePending) {
                  localResumeAttempt--; // give the slot back — not consumed
                  await listener?.cancel();
                  if (!completer.isCompleted) completer.complete();
                } else {
                  gemmaLog(
                    '🔄 Resume pending - keeping listener active '
                    '(resumeAttempt now $localResumeAttempt)',
                  );
                }
                break;

              case TaskStatus.canceled:
                if (!progress.isClosed) {
                  progress.addError(
                    const DownloadException(DownloadError.canceled()),
                    StackTrace.current,
                  );
                  progress.close();
                }
                await listener?.cancel();
                if (!completer.isCompleted) completer.complete();
                break;

              case TaskStatus.notFound:
                gemmaLog(
                  '🔴 SmartDownloader: TaskStatus.notFound detected (404)',
                );

                // 404 is a non-retryable error - handle immediately
                // Note: 404 always returns false (no resume), but using same pattern for consistency
                //
                // Same synchronous capture-and-increment as the `failed` case
                // above (#357 review) — closes the race window where a second
                // concurrent event could read a stale counter mid-await.
                final attemptForThisRound404 = localResumeAttempt;
                localResumeAttempt++;

                final resumePending404 = await _handleFailedDownload(
                  task: task,
                  downloader: downloader,
                  url: url,
                  targetPath: targetPath,
                  token: token,
                  maxRetries: maxRetries,
                  progress: progress,
                  currentAttempt: currentAttempt,
                  httpStatusCode: 404,
                  currentListener: listener,
                  cancelToken: cancelToken,
                  onListenerCreated: onListenerCreated,
                  onTaskCreated: onTaskCreated,
                  resumeAttempt: attemptForThisRound404,
                  onSettle: () {
                    // 404 never resumes (checked earlier in
                    // _handleFailedDownload), so the watchdog is never armed
                    // on this path — kept for consistency with the `failed`
                    // case above in case that ever changes.
                    if (!completer.isCompleted) completer.complete();
                  },
                );

                if (!resumePending404) {
                  localResumeAttempt--; // give the slot back — not consumed
                  await listener?.cancel();
                  if (!completer.isCompleted) completer.complete();
                }
                break;

              case TaskStatus.paused:
              case TaskStatus.enqueued:
                if (update.status == TaskStatus.paused) sawPause = true;
                if (!shouldRearmWatchdog(update.status, sawPause: sawPause)) {
                  break;
                }
                gemmaLog('⏸️ ${update.status} — re-arming resume watchdog');
                _armResumeWatchdog(
                  taskId: task.taskId,
                  progress: progress,
                  listener: listener,
                  onSettle: () {
                    if (!completer.isCompleted) completer.complete();
                  },
                );
                break;

              default:
                break;
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) async {
          if (!progress.isClosed) {
            progress.addError(error, stackTrace);
            progress.close();
          }
          await listener?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.completeError(
              DownloadUpdatesReleasedException(task.taskId),
              StackTrace.current,
            );
          }
        },
      );

      // Notify about new listener
      onListenerCreated?.call(listener);

      gemmaLog('🔵 Enqueueing task ${task.taskId}...');
      final result = await downloader.enqueue(task);
      gemmaLog('🔵 Enqueue result: $result');
      if (!result) {
        throw const DownloadException(
          DownloadError.network('enqueue() returned false'),
        );
      }

      // Notify about task ID for cancellation
      onTaskCreated?.call(task.taskId); // ← ADD: Notify task created

      // ✅ Wait for download to complete
      gemmaLog('🔵 Waiting for download completion...');
      await completer.future;
      gemmaLog('🔵 Download completed!');

      // Ensure listener is canceled after completion
      await listener.cancel();
    } catch (e) {
      gemmaLog('❌ Exception in _downloadWithSmartRetry: $e');
      gemmaLog('❌ Stack trace: ${StackTrace.current}');

      // Cancel listener before retry
      await listener?.cancel();

      // An explicit teardown is not a transient failure. Retrying it restarts
      // the download AND re-registers the group callbacks a couple of seconds
      // later, so the release never actually holds — and in the gap our tasks
      // spill into the host's `FileDownloader().updates`, which is #445 running
      // backwards.
      if (e is DownloadUpdatesReleasedException) {
        if (!progress.isClosed) {
          progress.addError(e, StackTrace.current);
          await progress.close();
        }
        return;
      }

      if (currentAttempt < maxRetries) {
        gemmaLog(
          '⚠️ Retrying after exception... attempt ${currentAttempt + 1}/$maxRetries',
        );
        await Future.delayed(
          Duration(seconds: currentAttempt * 2),
        ); // Exponential backoff

        // Check cancellation before retry
        try {
          cancelToken?.throwIfCancelled();
        } catch (e) {
          if (!progress.isClosed) {
            progress.addError(e);
            progress.close();
          }
          return;
        }

        // resumeAttempt intentionally omitted → resets to 0 for a fresh retry
        return _downloadWithSmartRetry(
          url: url,
          targetPath: targetPath,
          token: token,
          maxRetries: maxRetries,
          progress: progress,
          currentAttempt: currentAttempt + 1,
          currentListener: currentListener,
          cancelToken: cancelToken,
          onListenerCreated: onListenerCreated,
          onTaskCreated: onTaskCreated, // ← ADD: Pass callback through
        );
      } else {
        if (!progress.isClosed) {
          progress.addError(
            DownloadException(
              DownloadError.unknown(
                'Download failed after $maxRetries attempts: $e',
              ),
            ),
            StackTrace.current,
          );
          progress.close();
        }
      }
    }
  }

  /// Handles a failed download by attempting resume or retry.
  ///
  /// Returns `true` if resume was triggered (caller should keep listener active).
  /// Returns `false` if giving up or starting fresh retry (caller can cleanup).
  static Future<bool> _handleFailedDownload({
    required DownloadTask task,
    required FileDownloader downloader,
    required String url,
    required String targetPath,
    String? token,
    required int maxRetries,
    required StreamController<int> progress,
    required int currentAttempt,
    int? httpStatusCode,
    StreamSubscription? currentListener,
    CancelToken? cancelToken,
    void Function(StreamSubscription)? onListenerCreated,
    void Function(String taskId)? onTaskCreated,
    required int resumeAttempt,
    void Function()? onSettle,
  }) async {
    gemmaLog('🟡 _handleFailedDownload called');
    gemmaLog('🟡 httpStatusCode: $httpStatusCode');
    gemmaLog('🟡 progress.isClosed: ${progress.isClosed}');

    // Check if error is retryable based on HTTP status code
    if (httpStatusCode != null) {
      gemmaLog('🟢 httpStatusCode is not null: $httpStatusCode');

      // Auth errors (401, 403) and not-found (404) should NOT be retried
      if (httpStatusCode == 401) {
        gemmaLog('🟢 Detected 401 - stopping immediately');
        if (!progress.isClosed) {
          gemmaLog('🟢 Adding error to progress stream');
          progress.addError(
            const DownloadException(DownloadError.unauthorized()),
            StackTrace.current,
          );
          progress.close();
          gemmaLog('🟢 Progress stream closed');
        } else {
          gemmaLog('⚠️ Progress already closed - cannot add error!');
        }
        return false; // Stop immediately, no resume pending
      }

      if (httpStatusCode == 403) {
        if (!progress.isClosed) {
          progress.addError(
            const DownloadException(DownloadError.forbidden()),
            StackTrace.current,
          );
          progress.close();
        }
        return false; // Stop immediately, no resume pending
      }

      if (httpStatusCode == 404) {
        if (!progress.isClosed) {
          progress.addError(
            const DownloadException(DownloadError.notFound()),
            StackTrace.current,
          );
          progress.close();
        }
        return false; // Stop immediately, no resume pending
      }
    }

    // Decide resume vs retry vs give-up. Resume is CAPPED (#355): the old code
    // resumed unconditionally whenever canResume, so a repeatedly-failing
    // resume (HF weak-ETag) or a silently-dead task looped/hung forever.
    bool canResume = false;
    try {
      canResume = await downloader.taskCanResume(task);
    } catch (e) {
      // ❌ (not ⚠️): an unexpected throw, distinct from a normal
      // canResume=false decision (#357 review minor).
      gemmaLog('❌ taskCanResume threw: $e — treating as not resumable');
    }

    final action = decideFailedDownloadAction(
      canResume: canResume,
      resumeAttempt: resumeAttempt,
      currentAttempt: currentAttempt,
      maxRetries: maxRetries,
      maxResumeAttempts: kMaxResumeAttempts,
    );

    if (action == ResumeAction.resume) {
      gemmaLog(
        '🔄 Resuming task ${task.taskId} '
        // +1: human-readable 1-indexed; the cap comparison is 0-indexed
        '(resume attempt ${resumeAttempt + 1}/$kMaxResumeAttempts)...',
      );
      try {
        // #357 review (Bug D): `resume()` returns Future<bool> — `false` means
        // no resume data was available / the native re-enqueue failed. That's
        // NOT a throw, so it fell through the old code unnoticed: the watchdog
        // got armed and this returned true anyway, and since no status event
        // will ever arrive for a resume that was never actually accepted, the
        // caller stalled for the full 90s watchdog window for nothing.
        final resumed = await downloader.resume(task);
        if (!resumed) {
          gemmaLog(
            '⚠️ resume() returned false (no resume data / enqueue failed) — '
            'falling through to retry/give-up',
          );
          // Fall through to the bounded retry/give-up logic below — do NOT
          // arm the watchdog or return true.
        } else {
          gemmaLog('🔄 Resume triggered, waiting for status update...');
          // Resume was accepted - let event loop handle the result.
          // If resume succeeds → TaskStatus.complete will fire.
          // If resume fails (e.g., weak ETag) → TaskStatus.failed will fire and
          // the SAME listener re-enters this method with resumeAttempt + 1
          // (threaded by the caller in _downloadWithSmartRetry).
          _armResumeWatchdog(
            taskId: task.taskId,
            progress: progress,
            listener: currentListener,
            onSettle: onSettle,
          );
          return true; // ✅ Resume pending - caller should keep listener active!
        }
      } catch (e) {
        gemmaLog('⚠️ resume() threw: $e — falling through to retry/give-up');
        // resume() was never accepted, so no status event will ever arrive
        // for it — do NOT arm the watchdog or return true here, that would
        // leave the listener waiting forever. Fall through to the bounded
        // retry/give-up logic below instead.
      }
    }
    // action == retry or giveUp → fall through to the retry/give-up logic
    // below, which is already correctly capped on currentAttempt < maxRetries.
    if (currentAttempt < maxRetries) {
      // Exponential backoff
      await Future.delayed(Duration(seconds: currentAttempt * 2));

      // Check cancellation before retry
      try {
        cancelToken?.throwIfCancelled();
      } catch (e) {
        if (!progress.isClosed) {
          progress.addError(e);
          progress.close();
        }
        return false; // Cancelled, no resume pending
      }

      // Start fresh retry - new listener will be created
      // resumeAttempt intentionally omitted → resets to 0 for a fresh retry
      await _downloadWithSmartRetry(
        url: url,
        targetPath: targetPath,
        token: token,
        maxRetries: maxRetries,
        progress: progress,
        currentAttempt: currentAttempt + 1,
        currentListener: currentListener,
        cancelToken: cancelToken,
        onListenerCreated: onListenerCreated,
        onTaskCreated: onTaskCreated,
      );
      return false; // Fresh retry started, no resume pending on THIS listener
    } else {
      if (!progress.isClosed) {
        progress.addError(
          DownloadException(
            DownloadError.network(
              'Download failed after $maxRetries attempts. This may be due to network issues or server problems.',
            ),
          ),
          StackTrace.current,
        );
        progress.close();
      }
      return false; // Gave up, no resume pending
    }
  }

  /// Keyed by taskId (#355 follow-up): SmartDownloader supports CONCURRENT
  /// downloads, so a single shared `Timer?` field would let one task's
  /// arm/cancel clobber another's watchdog. Each in-flight task gets its own
  /// entry.
  static final Map<String, Timer> _resumeWatchdogs = {};

  /// Arms the resume watchdog (#355 part 3): if no progress/status update
  /// arrives for [taskId] within [kResumeWatchdog], the task is presumed
  /// silently dead and [progress] is force-closed with a network error so the
  /// caller's `await for` over the stream can never hang forever.
  ///
  /// [onSettle] (#357 review): the `_downloadWithSmartRetry` listener that
  /// armed this watchdog is awaiting its own `Completer<void>` and cancels
  /// `cancellationListener` in a `.whenComplete()` once that completer
  /// settles. A watchdog firing IS a terminal outcome for that round — it
  /// force-closes [progress] and cancels [listener] — but without also
  /// completing the completer, that `.whenComplete()` never runs and the
  /// cancellation subscription leaks. [onSettle] lets the caller pass its
  /// completer-completion so a watchdog fire settles the same way any other
  /// terminal status update does.
  static void _armResumeWatchdog({
    required String taskId,
    required StreamController<int> progress,
    required StreamSubscription? listener,
    void Function()? onSettle,
  }) {
    _resumeWatchdogs.remove(taskId)?.cancel();
    _resumeWatchdogs[taskId] = armResumeWatchdog(
      progress: progress,
      onTimeout: () {
        gemmaLog(
          '⏱️ Resume watchdog fired for $taskId — cancelling + closing as failed',
        );
        _resumeWatchdogs.remove(taskId);
        // Cancel the presumed-dead native task and purge its persisted state so
        // task/metadata/temp don't leak (#383/#4). Fire-and-forget: settling the
        // install as failed must not wait on native cancellation.
        final downloader = FileDownloader();
        unawaited(() async {
          try {
            await downloader.cancelTaskWithId(taskId);
            // ignore: invalid_use_of_visible_for_testing_member
            final storage = downloader.database.storage;
            await storage.removeResumeData(taskId);
            await storage.removePausedTask(taskId);
            await downloader.database.deleteRecordWithId(taskId);
          } catch (_) {}
        }());
        if (!progress.isClosed) {
          progress.addError(
            const DownloadException(
              DownloadError.network('Download resume timed out (no progress)'),
            ),
            StackTrace.current,
          );
          progress.close();
        }
        listener?.cancel();
        onSettle?.call();
      },
    );
  }

  /// Cancels a pending resume watchdog for [taskId] — called the moment any
  /// subsequent progress/status event arrives for that task, proving it's not
  /// dead. Only ever touches this task's own entry, so concurrent downloads
  /// can't cancel each other's watchdog.
  static void _cancelResumeWatchdog(String taskId) {
    _resumeWatchdogs.remove(taskId)?.cancel();
  }

  /// Checks if a URL is from HuggingFace CDN
  ///
  /// This is kept for backward compatibility but SmartDownloader works with ANY URL.
  /// You don't need to check this before using SmartDownloader.
  @Deprecated('SmartDownloader works with all URLs. No need to check anymore.')
  static bool isHuggingFaceUrl(String url) {
    return url.contains('huggingface.co') ||
        url.contains('cdn-lfs.huggingface.co') ||
        url.contains('cdn-lfs-us-1.huggingface.co') ||
        url.contains('cdn-lfs-eu-1.huggingface.co');
  }
}
