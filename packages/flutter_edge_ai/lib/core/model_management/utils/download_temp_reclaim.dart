/// Decision logic + filesystem walk for reclaiming orphaned
/// `background_downloader` partial temp files (#383), split out so both the
/// pure predicate and the directory sweep are testable — the predicate as a
/// pure unit test, the sweep as an on-device integration test — without the
/// surrounding `FileDownloader` / `path_provider` / gate machinery.
///
/// `MobileModelManager._reclaimOrphanedDownloadTemps` owns the SAFETY GATES
/// (Android-only, no active downloads, `resumeFromBackground()` first, the
/// resume keep-set) and calls [sweepOrphanedDownloadTemps] to do the walk.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Filename prefix `background_downloader` gives every partial temp file
/// (`com.bbflight.background_downloader<Random.nextInt()>`, no extension).
const String kDownloadTempPrefix = 'com.bbflight.background_downloader';

/// How recently a temp file must have been touched to be considered possibly
/// LIVE (a download can start writing a beat before its task is Dart-visible).
/// Only temps older than this are candidates for deletion.
const Duration kDownloadTempMinReclaimAge = Duration(minutes: 10);

/// Whether the file at [path] (basename [basename]) is an orphaned download
/// temp safe to delete.
///
/// Deletes ONLY when ALL hold:
/// - the name is a `background_downloader` temp ([kDownloadTempPrefix]);
/// - the path is NOT in [keepPaths] (temps a valid pending resume would reuse);
/// - the file is OLDER than [minAge] (never touch a possibly-live temp — the
///   guard is deliberately "older than", the opposite of "younger than", so a
///   just-(re)started download whose task is momentarily invisible is spared).
///
/// [age] is `now - file.modified`. Callers pass it so the function stays pure.
bool shouldReclaimDownloadTemp({
  required String basename,
  required String path,
  required Set<String> keepPaths,
  required Duration age,
  Duration minAge = kDownloadTempMinReclaimAge,
}) {
  if (!basename.startsWith(kDownloadTempPrefix)) return false;
  if (keepPaths.contains(path)) return false;
  if (age < minAge) return false;
  return true;
}

/// Walks [dir] (non-recursive) and deletes every file for which
/// [shouldReclaimDownloadTemp] is true. Returns the number deleted.
///
/// This is ONLY the filesystem walk — the caller MUST have already applied the
/// safety gates (Android-only, no active downloads, `resumeFromBackground()`,
/// and built [keepPaths] from the resume store). Best-effort: an undeletable or
/// vanished file is skipped, never thrown.
///
/// [now] is injectable so tests are deterministic.
Future<int> sweepOrphanedDownloadTemps(
  Directory dir, {
  required Set<String> keepPaths,
  Duration minAge = kDownloadTempMinReclaimAge,
  DateTime? now,
}) async {
  if (!dir.existsSync()) return 0;
  final at = now ?? DateTime.now();
  var reclaimed = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final FileStat stat;
    try {
      stat = await entity.stat();
    } catch (_) {
      continue; // vanished between list() and stat()
    }
    if (!shouldReclaimDownloadTemp(
      basename: p.basename(entity.path),
      path: entity.path,
      keepPaths: keepPaths,
      age: at.difference(stat.modified),
      minAge: minAge,
    )) {
      continue;
    }
    try {
      await entity.delete();
      reclaimed++;
    } catch (_) {
      // Locked / already removed — skip.
    }
  }
  return reclaimed;
}

/// Outcome of reconciling one persisted resume record against the current
/// task-ID scheme during reclaim (#383/R2).
enum ReclaimDecision { keep, purge, skip }

/// Decide what to do with a group-scoped resume record whose temp is [tempAge] old.
///
/// - [taskId] == [expectedId] → current-scheme record → `keep` (protect its temp).
/// - [isNativeRunning] → WorkManager is actively writing this temp → `keep`.
/// - otherwise it is a legacy/foreign-scheme record: `purge` if the temp is older
///   than [minAge], else `skip` (a just-rescheduled killed task may be about to
///   resume it — the same 10-min guard the blanket sweep uses).
ReclaimDecision reconcileResumeRecord({
  required String taskId,
  required String expectedId,
  required bool isNativeRunning,
  required Duration tempAge,
  Duration minAge = kDownloadTempMinReclaimAge,
}) {
  if (taskId == expectedId) return ReclaimDecision.keep;
  if (isNativeRunning) return ReclaimDecision.keep;
  if (tempAge < minAge) return ReclaimDecision.skip;
  return ReclaimDecision.purge;
}

/// Whether [basename] is a `background_downloader` partial temp file (#383/#3).
bool isDownloadFragmentName(String basename) =>
    basename.startsWith(kDownloadTempPrefix);
