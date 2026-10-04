/// On-device validation of the #383 orphaned-download-temp reclaim.
///
/// The pure predicate is unit-tested off-device; what only a real Android device
/// can confirm is the INTEGRATION: that `getApplicationSupportDirectory()`
/// resolves to the same `filesDir` where `background_downloader` writes
/// large-file temps, that the sweep enumerates + deletes there, and that a real
/// download's temp actually lands in that directory.
///
/// Run (Android device / FTL):
///   flutter test integration_test/download_temp_reclaim_device_test.dart -d <android>
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/core/model_management/utils/download_temp_reclaim.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _gemma4Url =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
  });

  // ── A. The sweep on a REAL Android filesDir ──────────────────────────────
  testWidgets(
    'A: getApplicationSupportDirectory is filesDir and the sweep deletes '
    'orphaned temps there, keeping the keep-set and non-temp files',
    (tester) async {
      expect(Platform.isAndroid, isTrue, reason: 'device test is Android-only');

      final dir = await getApplicationSupportDirectory();
      print('[reclaim] applicationSupport = ${dir.path}');
      // Android filesDir is under the app data dir (…/files), never external.
      expect(dir.path.contains('/files'), isTrue, reason: 'expected filesDir');

      final orphan = File(
        p.join(dir.path, 'com.bbflight.background_downloader_TEST_orphan'),
      )..writeAsBytesSync(List.filled(1024, 0));
      final keep = File(
        p.join(dir.path, 'com.bbflight.background_downloader_TEST_keep'),
      )..writeAsBytesSync(List.filled(1024, 0));
      final model = File(p.join(dir.path, 'test_model_TEST.litertlm'))
        ..writeAsBytesSync(List.filled(1024, 0));

      addTearDown(() {
        for (final f in [orphan, keep, model]) {
          if (f.existsSync()) f.deleteSync();
        }
      });

      // minAge: 0 so the just-written synthetic temps are eligible (the
      // "older-than" mtime guard itself is covered by the off-device unit test).
      final reclaimed = await sweepOrphanedDownloadTemps(
        dir,
        keepPaths: {keep.path},
        minAge: Duration.zero,
      );

      print('[reclaim] deleted $reclaimed file(s)');
      expect(
        orphan.existsSync(),
        isFalse,
        reason: 'orphan temp must be deleted',
      );
      expect(keep.existsSync(), isTrue, reason: 'keep-set temp must survive');
      expect(model.existsSync(), isTrue, reason: 'a real model must survive');
      expect(reclaimed, greaterThanOrEqualTo(1));
    },
  );

  // ── B. A real download's temp lands in that same directory ───────────────
  testWidgets(
    'B: a live background_downloader partial for a 2.4GB model appears as a '
    'com.bbflight.background_downloader* temp in getApplicationSupportDirectory',
    (tester) async {
      if (_token.isEmpty) {
        markTestSkipped(
          'HUGGINGFACE_TOKEN not provided — skipping the real-download temp '
          'location check (Test A already validates the sweep on real filesDir; '
          "the location is also confirmed by #383's own logcat).",
        );
        return;
      }
      final dir = await getApplicationSupportDirectory();

      bool hasBgTemp() => dir
          .listSync(followLinks: false)
          .any(
            (e) =>
                e is File && p.basename(e.path).startsWith(kDownloadTempPrefix),
          );

      final cancel = CancelToken();
      // Fire the download; don't await — we only need it to START writing its
      // temp. Swallow the cancellation/other errors.
      unawaited(() async {
        try {
          await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
              .fromNetwork(_gemma4Url, token: _token)
              .withCancelToken(cancel)
              .withProgress((_) {})
              .install();
        } catch (_) {
          // Cancellation / network error — expected; we only wanted the temp.
        }
      }());

      // Poll up to ~90s for the native worker to create the temp.
      var appeared = false;
      for (var i = 0; i < 45 && !appeared; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        appeared = hasBgTemp();
      }
      cancel.cancel();
      await Future<void>.delayed(const Duration(seconds: 2));

      print('[reclaim] live download temp seen in filesDir: $appeared');
      expect(
        appeared,
        isTrue,
        reason:
            'a 2.4GB download must create a com.bbflight.background_downloader* '
            'temp in getApplicationSupportDirectory() — that is exactly the dir '
            'the reclaim sweep scans',
      );

      // Best-effort cleanup of any partial we just created.
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && p.basename(e.path).startsWith(kDownloadTempPrefix)) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    },
  );

  // ── C. A synthetic fragment is surfaced + deletable via the public API ──
  testWidgets(
    'C: a com.bbflight.background_downloader* fragment is surfaced by '
    'getOrphanedFiles (isDownloadFragment) and removed by cleanupOrphanedFiles',
    (tester) async {
      expect(Platform.isAndroid, isTrue, reason: 'device test is Android-only');

      final dir = await getApplicationSupportDirectory();
      final fragment = File(p.join(dir.path, '${kDownloadTempPrefix}_TESTFRAG'))
        ..writeAsBytesSync(List.filled(1024, 0));

      addTearDown(() {
        if (fragment.existsSync()) fragment.deleteSync();
      });

      final orphaned = await ModelFileSystemManager.getOrphanedFiles(
        protectedFiles: const [],
      );
      final match = orphaned.where((o) => o.path == fragment.path).toList();
      print(
        '[reclaim] getOrphanedFiles surfaced ${orphaned.length} entr(y/ies)',
      );
      expect(
        match.length,
        1,
        reason:
            'the fragment must be surfaced exactly once by getOrphanedFiles',
      );
      expect(
        match.single.isDownloadFragment,
        isTrue,
        reason: 'a background_downloader* file must be flagged as a fragment',
      );

      // Protect every non-fragment orphaned file already surfaced above so a
      // persistent device's real installed models (with no active download
      // task) can never be swept by this test — only the synthetic fragment
      // (and any other real fragments) are fair game for cleanup (#383).
      final protectedFiles = orphaned
          .where((o) => !o.isDownloadFragment)
          .map((o) => o.filename)
          .toList();
      final deleted = await ModelFileSystemManager.cleanupOrphanedFiles(
        protectedFiles: protectedFiles,
      );
      print('[reclaim] cleanupOrphanedFiles deleted $deleted file(s)');
      expect(
        fragment.existsSync(),
        isFalse,
        reason: 'cleanupOrphanedFiles must delete the fragment',
      );
    },
  );

  // ── D. Legacy resume-record reconciliation purges the legacy record + its
  //      temp, but keeps a current-scheme record + its temp (#383/R2) ──────
  //
  // `_reclaimOrphanedDownloadTemps` (MobileModelManager) is private, so this
  // drives the same public decision primitives it uses — `computeTaskId`,
  // `reconcileResumeRecord`, `ReclaimDecision` — against the REAL
  // `FileDownloader().database.storage`, mirroring the loop in
  // mobile_model_manager.dart. The reconcile scope is narrowed to only the two
  // taskIds this test creates (rather than every group record in real
  // storage) so the test can never mutate unrelated resume state that may
  // already exist on a shared test device.
  testWidgets(
    'D: reconciliation purges a legacy resume record + its temp, keeps a '
    'current-scheme record + its temp',
    (tester) async {
      expect(Platform.isAndroid, isTrue, reason: 'device test is Android-only');

      final dir = await getApplicationSupportDirectory();
      final downloader = FileDownloader();
      // ignore: invalid_use_of_visible_for_testing_member
      final storage = downloader.database.storage;

      const baseDirectory = BaseDirectory.applicationSupport;
      const directory = '';
      const legacyFilename = 'legacy_model_TESTFRAG.litertlm';
      const currentFilename = 'current_model_TESTFRAG.litertlm';

      final expectedLegacyId = computeTaskId(
        baseDirectory,
        directory,
        legacyFilename,
      );
      // Deliberately NOT the id its own (base, directory, filename) triple
      // computes — that mismatch is the definition of "legacy": a taskId
      // minted before #383/#2 introduced the deterministic
      // sha256(base|directory|filename) scheme.
      final legacyTaskId = 'legacy-pre-383-$expectedLegacyId';
      final currentTaskId = computeTaskId(
        baseDirectory,
        directory,
        currentFilename,
      );

      final legacyTemp = File(
        p.join(dir.path, '${kDownloadTempPrefix}_TESTFRAG_legacy'),
      )..writeAsBytesSync(List.filled(1024, 0));
      final currentTemp = File(
        p.join(dir.path, '${kDownloadTempPrefix}_TESTFRAG_current'),
      )..writeAsBytesSync(List.filled(1024, 0));
      // Older than kDownloadTempMinReclaimAge so the purge branch is eligible
      // — a just-written temp is deliberately spared (reconcileResumeRecord).
      final old = DateTime.now().subtract(const Duration(minutes: 30));
      legacyTemp.setLastModifiedSync(old);
      currentTemp.setLastModifiedSync(old);

      final legacyTask = DownloadTask(
        taskId: legacyTaskId,
        url: 'https://example.invalid/$legacyFilename',
        filename: legacyFilename,
        directory: directory,
        baseDirectory: baseDirectory,
        group: SmartDownloader.downloadGroup,
      );
      final currentTask = DownloadTask(
        taskId: currentTaskId,
        url: 'https://example.invalid/$currentFilename',
        filename: currentFilename,
        directory: directory,
        baseDirectory: baseDirectory,
        group: SmartDownloader.downloadGroup,
      );

      addTearDown(() async {
        // Best-effort: clean up everything this test created — the legacy
        // record/temp are expected to already be gone (the test purges them
        // itself), and the current-scheme record/temp are KEPT by design, so
        // this is what actually removes them afterwards.
        for (final id in [legacyTaskId, currentTaskId]) {
          try {
            await storage.removeResumeData(id);
          } catch (_) {}
          try {
            await storage.removePausedTask(id);
          } catch (_) {}
          try {
            await downloader.database.deleteRecordWithId(id);
          } catch (_) {}
        }
        for (final f in [legacyTemp, currentTemp]) {
          if (f.existsSync()) f.deleteSync();
        }
      });

      await storage.storeResumeData(ResumeData(legacyTask, legacyTemp.path));
      await storage.storeResumeData(ResumeData(currentTask, currentTemp.path));

      // Mirror MobileModelManager._reclaimOrphanedDownloadTemps's reconcile
      // loop against the REAL storage, scoped to only the two records this
      // test created (see class comment above for why).
      final pausedIds = (await storage.retrieveAllPausedTasks())
          .map((t) => t.taskId)
          .toSet();
      final allIds = (await downloader.allTasks(
        allGroups: true,
      )).map((t) => t.taskId).toSet();
      final nativeRunningIds = allIds.difference(pausedIds);
      final ourIds = {legacyTaskId, currentTaskId};

      for (final r in await storage.retrieveAllResumeData()) {
        if (r.task.group != SmartDownloader.downloadGroup) continue;
        if (!ourIds.contains(r.task.taskId)) continue;
        final expectedId = computeTaskId(
          r.task.baseDirectory,
          r.task.directory,
          r.task.filename,
        );
        final tempAge = DateTime.now().difference(
          await File(r.tempFilepath).lastModified(),
        );
        final decision = reconcileResumeRecord(
          taskId: r.task.taskId,
          expectedId: expectedId,
          isNativeRunning: nativeRunningIds.contains(r.task.taskId),
          tempAge: tempAge,
        );
        if (decision != ReclaimDecision.purge) continue;
        try {
          await File(r.tempFilepath).delete();
        } catch (_) {}
        await storage.removeResumeData(r.task.taskId);
        await storage.removePausedTask(r.task.taskId);
        await downloader.database.deleteRecordWithId(r.task.taskId);
        print('[reclaim] purged legacy record ${r.task.taskId} (#383/R2 test)');
      }

      expect(
        legacyTemp.existsSync(),
        isFalse,
        reason: "legacy record's temp must be purged",
      );
      expect(
        currentTemp.existsSync(),
        isTrue,
        reason: "current-scheme record's temp must survive",
      );

      final remaining = await storage.retrieveAllResumeData();
      expect(
        remaining.any((r) => r.task.taskId == legacyTaskId),
        isFalse,
        reason: 'legacy resume record must be removed',
      );
      expect(
        remaining.any((r) => r.task.taskId == currentTaskId),
        isTrue,
        reason: 'current-scheme resume record must survive',
      );
    },
  );
}
