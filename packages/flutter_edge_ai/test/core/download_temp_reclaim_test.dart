import 'package:flutter_edge_ai/core/model_management/utils/download_temp_reclaim.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const dir = '/data/data/app/files';
  String p(String name) => '$dir/$name';
  const old = Duration(minutes: 30);
  const fresh = Duration(minutes: 2);

  group('shouldReclaimDownloadTemp (#383)', () {
    test('deletes an old, unreferenced background_downloader temp', () {
      expect(
        shouldReclaimDownloadTemp(
          basename: 'com.bbflight.background_downloader123456',
          path: p('com.bbflight.background_downloader123456'),
          keepPaths: const {},
          age: old,
        ),
        isTrue,
      );
    });

    test('keeps a non-background_downloader file (a real model)', () {
      expect(
        shouldReclaimDownloadTemp(
          basename: 'gemma-4-E2B-it.litertlm',
          path: p('gemma-4-E2B-it.litertlm'),
          keepPaths: const {},
          age: old,
        ),
        isFalse,
      );
    });

    test('keeps a temp referenced by a valid pending resume (keep-set)', () {
      final path = p('com.bbflight.background_downloader999');
      expect(
        shouldReclaimDownloadTemp(
          basename: 'com.bbflight.background_downloader999',
          path: path,
          keepPaths: {path},
          age: old,
        ),
        isFalse,
      );
    });

    test('keeps a FRESH temp — mtime guard is "older than", never delete a '
        'possibly-live download (the architect-flagged direction)', () {
      expect(
        shouldReclaimDownloadTemp(
          basename: 'com.bbflight.background_downloader777',
          path: p('com.bbflight.background_downloader777'),
          keepPaths: const {},
          age: fresh,
        ),
        isFalse,
      );
    });

    test('deletes exactly at the age boundary (>= minAge deletes)', () {
      // age == minAge is not "< minAge", so it is reclaimable.
      expect(
        shouldReclaimDownloadTemp(
          basename: 'com.bbflight.background_downloader1',
          path: p('com.bbflight.background_downloader1'),
          keepPaths: const {},
          age: kDownloadTempMinReclaimAge,
        ),
        isTrue,
      );
      // One tick younger is spared.
      expect(
        shouldReclaimDownloadTemp(
          basename: 'com.bbflight.background_downloader1',
          path: p('com.bbflight.background_downloader1'),
          keepPaths: const {},
          age: kDownloadTempMinReclaimAge - const Duration(seconds: 1),
        ),
        isFalse,
      );
    });
  });

  group('reconcileResumeRecord (#383/R2)', () {
    const old = Duration(minutes: 30);
    const fresh = Duration(minutes: 2);

    test('current-scheme record (taskId == expectedId) → keep', () {
      expect(
        reconcileResumeRecord(
          taskId: 'abc',
          expectedId: 'abc',
          isNativeRunning: false,
          tempAge: old,
        ),
        ReclaimDecision.keep,
      );
    });

    test(
      'current-scheme id with a FRESH temp still → keep (precedence guard)',
      () {
        // taskId == expectedId must win over the tempAge < minAge → skip branch;
        // this pins the branch ORDER so a future reorder can't misclassify a valid
        // current-scheme record as skip.
        expect(
          reconcileResumeRecord(
            taskId: 'abc',
            expectedId: 'abc',
            isNativeRunning: false,
            tempAge: fresh,
          ),
          ReclaimDecision.keep,
        );
      },
    );

    test(
      'legacy record that WorkManager is running → keep (do not corrupt a live write)',
      () {
        expect(
          reconcileResumeRecord(
            taskId: 'legacy',
            expectedId: 'sha',
            isNativeRunning: true,
            tempAge: old,
          ),
          ReclaimDecision.keep,
        );
      },
    );

    test('legacy, not running, old temp → purge', () {
      expect(
        reconcileResumeRecord(
          taskId: 'legacy',
          expectedId: 'sha',
          isNativeRunning: false,
          tempAge: old,
        ),
        ReclaimDecision.purge,
      );
    });

    test(
      'legacy, not running, FRESH temp → skip (rescheduleKilledTasks race guard)',
      () {
        expect(
          reconcileResumeRecord(
            taskId: 'legacy',
            expectedId: 'sha',
            isNativeRunning: false,
            tempAge: fresh,
          ),
          ReclaimDecision.skip,
        );
      },
    );
  });

  group('isDownloadFragmentName (#383/#3)', () {
    test('a background_downloader temp basename → true', () {
      expect(
        isDownloadFragmentName('com.bbflight.background_downloader1234'),
        isTrue,
      );
    });
    test('a model file → false', () {
      expect(isDownloadFragmentName('gemma-4-E2B-it.litertlm'), isFalse);
    });
  });
}
