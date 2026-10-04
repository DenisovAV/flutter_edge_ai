// A SECOND line of defence on the Apple `vec0` minimum-OS value.
//
// Flutter hardcodes `MinimumOSVersion 13.0` into the Native-Assets framework
// wrapper it generates, and App Store Connect compares each framework's BINARY
// against ITS OWN wrapper plist — so a slice declaring anything else is
// ITMS-90208 regardless of the app's deployment target.
//
// This repo has shipped that rejection twice: once as #286, and once here,
// where asg017's upstream tarball carried the legacy `LC_VERSION_MIN_IPHONEOS
// 7.0` and the simulator slice carried 14.0. Both times the only guard was a
// step inside a build script a human had to remember to run — and the second
// time that step was normalizing a tarball nobody consumes while the shipped
// bytes went unchecked.
//
// So this parses the Mach-O load commands itself rather than shelling out to
// `vtool`, which means it needs no Apple toolchain to run.
//
// The PRIMARY guard is now `_assertIosMinos` in `hook/build.dart`, which runs
// on the bytes about to be registered, on every build, on every machine — so
// CI's iOS job enforces it and a maintainer's memory is no longer load-bearing.
// That is what closes the hole this file's second paragraph describes.
//
// This file remains because it checks the local `prebuilt/` tree BEFORE a
// release is packed, and because it covers the simulator slice, which no
// device build exercises. It is not the tree the hook packs from — `pack()`
// tars from the work directory and `install_prebuilt()` copies here
// afterwards, both from the same normalized file — so treat this as a
// pre-flight, not as verification of the shipped archive.
//
// `native/sqlite_vec/prebuilt/` is gitignored, so in a plain clone there is
// nothing here to read and the test skips. Note the skip is CWD-relative: run
// from the repository root it will also skip with the bytes present.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const _lcVersionMinIphoneos = 0x25;
const _lcBuildVersion = 0x32;
// PLATFORM_* from mach-o/loader.h. IOS is 2 — 1 is MACOS, which is exactly
// the confusion a wrong `vtool` platform argument produces, so the numbers are
// spelled out rather than guessed.
const _platformIos = 2;
const _platformIosSimulator = 7;

/// (platform, minos) from the first version-declaring load command, or null.
({int platform, String minos})? _buildVersion(File f) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  final magic = b.getUint32(0, Endian.little);
  if (magic != 0xfeedfacf) return null; // 64-bit little-endian Mach-O only
  final ncmds = b.getUint32(16, Endian.little);
  var off = 32; // mach_header_64
  for (var i = 0; i < ncmds; i++) {
    final cmd = b.getUint32(off, Endian.little);
    final size = b.getUint32(off + 4, Endian.little);
    if (cmd == _lcBuildVersion) {
      final platform = b.getUint32(off + 8, Endian.little);
      final v = b.getUint32(off + 12, Endian.little);
      return (platform: platform, minos: '${v >> 16}.${(v >> 8) & 0xff}');
    }
    if (cmd == _lcVersionMinIphoneos) {
      // The legacy command. Present at all means the slice was never
      // normalized — that is the state that shipped 7.0.
      final v = b.getUint32(off + 8, Endian.little);
      return (platform: -1, minos: '${v >> 16}.${(v >> 8) & 0xff}');
    }
    off += size;
  }
  return null;
}

void main() {
  final root = Directory('native/sqlite_vec/prebuilt');

  test(
    'every iOS vec0 slice about to be packed declares minos 13.0',
    () {
      const expected = {
        'ios_arm64': _platformIos,
        'ios_sim_arm64': _platformIosSimulator,
      };

      for (final entry in expected.entries) {
        final lib = File('${root.path}/${entry.key}/libvec0.dylib');
        // A HALF-populated prebuilt dir is the dangerous case: it means someone
        // built some targets and is about to pack a release from it. Absent
        // entirely is a plain clone, handled by the skip below.
        expect(
          lib.existsSync(),
          isTrue,
          reason:
              '${entry.key} is missing while other targets are present — '
              're-run native/sqlite_vec/build_local.sh for every target before '
              'packing a release.',
        );

        final got = _buildVersion(lib);
        expect(got, isNotNull, reason: '${entry.key}: no version load command');
        expect(
          got!.minos,
          '13.0',
          reason:
              '${entry.key} declares minos ${got.minos}. Re-run '
              'native/sqlite_vec/build_local.sh — normalize_apple_minos runs '
              'in repackage(), before pack() — or vtool -set-build-version.',
        );
        expect(
          got.platform,
          entry.value,
          reason:
              '${entry.key} declares platform ${got.platform} — a wrong vtool '
              'platform argument is accepted silently and fails later at dlopen',
        );
      }
    },
    skip: Directory('native/sqlite_vec/prebuilt').existsSync()
        ? false
        : 'no local prebuilts — they are fetched from native-sqlite-vec-v* at '
              'build time; run native/sqlite_vec/build_local.sh to materialize them',
  );
}
