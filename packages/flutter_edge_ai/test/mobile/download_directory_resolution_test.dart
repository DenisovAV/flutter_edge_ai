// Regression test for the Windows %LOCALAPPDATA% fresh-download landing bug.
//
// background_downloader's `Task.split` strips the drive/root from the directory
// for a target that is NOT under one of its recognized bases, and on Windows the
// `BaseDirectory.root` base reconstructs against '' (= $CWD). So a fresh download
// to `%LOCALAPPDATA%\flutter_edge_ai` landed at `<cwd>\Users\..\AppData\Local\
// flutter_gemma\` while getReadTargetPath/validateModelFiles looked at the
// absolute path — `install()` "succeeded" but `isModelInstalled()` was false and
// `getActiveStt()`/createModel threw "file paths not found".
//
// `resolveDownloadDirectory` restores the absolute directory for the
// root-fallback case so the file lands exactly at `targetPath`. This guards the
// download-LANDING invariant that `path_resolution_roundtrip_test` cannot: that
// test only asserts getWriteTargetPath == getReadTargetPath, never how
// background_downloader maps the absolute target onto a write location.
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveDownloadDirectory', () {
    test('root-fallback keeps the ABSOLUTE target directory, not the '
        'drive-stripped split directory (Windows %LOCALAPPDATA%)', () {
      // What Task.split yields for a target not under a recognized base: root +
      // the directory with the leading root/drive stripped (relative).
      final target = p.join(p.separator, 'x', 'flutter_gemma', 'model.bin');
      final strippedDir = p.join('x', 'flutter_gemma');

      final dir = resolveDownloadDirectory(
        BaseDirectory.root,
        strippedDir,
        target,
      );

      // Must be the target's own directory (absolute), so the download lands at
      // targetPath — NOT the stripped relative dir that made it land under $CWD.
      expect(dir, p.dirname(target));
      expect(dir, isNot(strippedDir));
    });

    test('recognized base keeps the stable split directory (mobile / '
        'macOS / Linux applicationSupport)', () {
      // A target under a recognized base keeps the relative split directory so
      // the taskId stays stable across mobile container-UUID churn (see
      // computeTaskId). Only the root-fallback case is rewritten.
      final dir = resolveDownloadDirectory(
        BaseDirectory.applicationSupport,
        'flutter_gemma',
        p.join('anywhere', 'flutter_gemma', 'model.bin'),
      );

      expect(dir, 'flutter_gemma');
    });

    // Host-independent reproduction of the exact Windows landing bug via an
    // explicit Windows path Context. Task.split/filePath switch on dart:io
    // `Platform.isWindows` (not `defaultTargetPlatform`), so the bug can't be
    // reproduced on a POSIX CI host by overriding the target platform — a
    // windows `p.Context` can. This is the test that actually fails if the fix
    // (the absolute-directory branch) is reverted.
    test('Windows root-fallback lands at the ABSOLUTE target; the raw split dir '
        r'would land $CWD-relative', () {
      final win = p.Context(style: p.Style.windows);
      const target = r'C:\Users\me\AppData\Local\flutter_gemma\model.bin';
      // What Task.split yields on Windows: root base + drive-stripped directory.
      final strippedDir = win.relative(win.dirname(target), from: r'C:\');
      final filename = win.basename(target);
      // background_downloader reconstructs a root task as
      // join(baseDirectoryPath(root), directory, filename); on Windows the root
      // base is '' — so a relative `directory` lands $CWD-relative.
      String landing(String dir) => win.join('', dir, filename);

      // Pre-fix wiring (raw split dir) → relative landing = the bug.
      expect(win.isAbsolute(landing(strippedDir)), isFalse);

      // The fix feeds the absolute dirname → lands exactly at the target.
      final fixed = resolveDownloadDirectory(
        BaseDirectory.root,
        strippedDir,
        target,
        context: win,
      );
      expect(win.canonicalize(landing(fixed)), win.canonicalize(target));
    });
  });
}
