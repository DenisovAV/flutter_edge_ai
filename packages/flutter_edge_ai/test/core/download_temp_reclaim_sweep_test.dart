/// Host-VM coverage for the I/O half of the #383 reclaim: the directory walk
/// `sweepOrphanedDownloadTemps`. The pure predicate is covered in
/// `download_temp_reclaim_test.dart`; the on-device test exercises the walk on a
/// real Android `filesDir` but with `minAge: 0`, which disables the age gate at
/// the only place the real `stat.modified → age` wiring runs. These tests drive
/// that wiring end-to-end on a `systemTemp` sandbox with real file mtimes and an
/// injected `now`, so the "never delete a possibly-live temp" property is
/// verified through the actual filesystem — no device, no mocks.
library;

import 'dart:io';

import 'package:flutter_edge_ai/core/model_management/utils/download_temp_reclaim.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sweepOrphanedDownloadTemps (#383)', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('sweep_reclaim_');
    });
    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    // A fixed reference clock; file mtimes are set relative to it so `age` is
    // exact and independent of wall-clock during the run.
    final nowRef = DateTime(2026, 1, 1, 12, 0, 0);
    const minAge = Duration(minutes: 10);
    final oldMtime = nowRef.subtract(const Duration(minutes: 30));
    final freshMtime = nowRef.subtract(const Duration(minutes: 2));

    File writeFile(String name, {required DateTime mtime}) {
      final f = File(p.join(sandbox.path, name))
        ..writeAsBytesSync(const [0, 1, 2, 3]);
      f.setLastModifiedSync(mtime);
      return f;
    }

    test('mixed sweep, age gate LIVE: deletes only the old orphan; keeps the '
        'fresh temp, the keep-set temp, and a real model', () async {
      final orphan = writeFile(
        'com.bbflight.background_downloader111',
        mtime: oldMtime,
      );
      final freshOrphan = writeFile(
        'com.bbflight.background_downloader222',
        mtime: freshMtime,
      );
      final keep = writeFile(
        'com.bbflight.background_downloader333',
        mtime: oldMtime,
      );
      final model = writeFile('gemma-4-E2B-it.litertlm', mtime: oldMtime);

      final reclaimed = await sweepOrphanedDownloadTemps(
        sandbox,
        keepPaths: {keep.path},
        minAge: minAge,
        now: nowRef,
      );

      expect(reclaimed, 1);
      expect(
        orphan.existsSync(),
        isFalse,
        reason: 'old, unreferenced temp is deleted',
      );
      expect(
        freshOrphan.existsSync(),
        isTrue,
        reason: 'fresh temp spared — could be a just-restarted download',
      );
      expect(
        keep.existsSync(),
        isTrue,
        reason: 'keep-set temp (pending resume) preserved',
      );
      expect(model.existsSync(), isTrue, reason: 'a real model is preserved');
    });

    test('a fresh orphan alone survives and returns 0 (never unlink a '
        'possibly-live download via the real mtime path)', () async {
      final freshOrphan = writeFile(
        'com.bbflight.background_downloader777',
        mtime: freshMtime,
      );
      final reclaimed = await sweepOrphanedDownloadTemps(
        sandbox,
        keepPaths: const {},
        minAge: minAge,
        now: nowRef,
      );
      expect(reclaimed, 0);
      expect(freshOrphan.existsSync(), isTrue);
    });

    test('a single old orphan is deleted and the count is exactly 1', () async {
      final orphan = writeFile(
        'com.bbflight.background_downloader1',
        mtime: oldMtime,
      );
      final reclaimed = await sweepOrphanedDownloadTemps(
        sandbox,
        keepPaths: const {},
        minAge: minAge,
        now: nowRef,
      );
      expect(reclaimed, 1);
      expect(orphan.existsSync(), isFalse);
    });

    test('a prefix-named SUBDIRECTORY is skipped, never deleted', () async {
      final subdir = Directory(
        p.join(sandbox.path, 'com.bbflight.background_downloader_dir'),
      )..createSync();
      final reclaimed = await sweepOrphanedDownloadTemps(
        sandbox,
        keepPaths: const {},
        minAge: minAge,
        now: nowRef,
      );
      expect(reclaimed, 0);
      expect(
        subdir.existsSync(),
        isTrue,
        reason: 'a Directory is not a File; the entity-type guard must skip it',
      );
    });

    test(
      'a prefix-named SYMLINK is skipped and its target is not '
      'followed/deleted (pins followLinks:false)',
      () async {
        // A prefix-named, OLD target: if a future change flipped the walk to
        // followLinks:true, the link would resolve to this File, pass both the
        // prefix and age guards, and be deleted — this test would then fail.
        final target = writeFile('real_target_file', mtime: oldMtime);
        final link = Link(
          p.join(sandbox.path, 'com.bbflight.background_downloader_link'),
        )..createSync(target.path);

        final reclaimed = await sweepOrphanedDownloadTemps(
          sandbox,
          keepPaths: const {},
          minAge: minAge,
          now: nowRef,
        );

        expect(reclaimed, 0);
        expect(
          link.existsSync(),
          isTrue,
          reason:
              'a Link is not a File under followLinks:false; must be spared',
        );
        expect(
          target.existsSync(),
          isTrue,
          reason: 'the symlink target must never be followed and deleted',
        );
      },
      skip: Platform.isWindows
          ? 'symlink creation needs privilege on Windows'
          : false,
    );

    test('a non-existent directory returns 0 without throwing', () async {
      final gone = Directory(p.join(sandbox.path, 'does_not_exist'));
      expect(await sweepOrphanedDownloadTemps(gone, keepPaths: const {}), 0);
    });

    test('an empty directory returns 0', () async {
      expect(await sweepOrphanedDownloadTemps(sandbox, keepPaths: const {}), 0);
    });
  });
}
