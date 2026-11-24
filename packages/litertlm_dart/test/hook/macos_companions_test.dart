// `hooks: user_defines: litertlm_dart: macos_companions:` and the header room
// `dart run` / `dart test` need for the constraint provider's install name.

import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/src/hook/macos_companions.dart';
import 'package:litertlm_dart/src/runtime/native_release.dart';
import 'package:test/test.dart';

/// A 64-bit Mach-O header with one LC_SEGMENT_64 holding sections at
/// [sectionOffsets], one other load command of [otherCmdSize] bytes, and
/// nothing else.
Uint8List _machO({required List<int> sectionOffsets, int otherCmdSize = 72}) {
  final segmentSize = 72 + 80 * sectionOffsets.length;
  final sizeofcmds = segmentSize + otherCmdSize;
  final bytes = ByteData(4096);
  bytes.setUint32(0, 0xfeedfacf, Endian.little);
  bytes.setUint32(16, 2, Endian.little); // ncmds
  bytes.setUint32(20, sizeofcmds, Endian.little);
  var at = 32;
  bytes.setUint32(at, 0x19, Endian.little);
  bytes.setUint32(at + 4, segmentSize, Endian.little);
  bytes.setUint32(at + 64, sectionOffsets.length, Endian.little);
  for (var i = 0; i < sectionOffsets.length; i++) {
    bytes.setUint32(at + 72 + i * 80 + 48, sectionOffsets[i], Endian.little);
  }
  at += segmentSize;
  bytes.setUint32(at, 0xd, Endian.little); // LC_ID_DYLIB
  bytes.setUint32(at + 4, otherCmdSize, Endian.little);
  return bytes.buffer.asUint8List();
}

void main() {
  group('readMacOSCompanionsDefine', () {
    test('unset is a Flutter app; code_assets a plain Dart program', () {
      expect(readMacOSCompanionsDefine(null), MacOSCompanions.frameworks);
      expect(
        readMacOSCompanionsDefine('code_assets'),
        MacOSCompanions.codeAssets,
      );
    });

    test('anything else fails the build, naming the define and its values', () {
      for (final value in <Object>[
        'frameworks',
        'auto',
        'Code_Assets',
        '',
        true,
        1,
      ]) {
        expect(
          () => readMacOSCompanionsDefine(value),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('hooks.user_defines.litertlm_dart.macos_companions'),
                contains('code_assets'),
                contains('"$value"'),
              ),
            ),
          ),
          reason: '$value',
        );
      }
    });
  });

  group('machOHeaderSlack', () {
    test('the room between the load commands and the first section', () {
      // Load commands end at 32 + (72 + 2 * 80) + 72 = 336.
      expect(machOHeaderSlack(_machO(sectionOffsets: [1024, 400])), 64);
      // A zero-fill section (offset 0) is not where the file's bytes start.
      expect(machOHeaderSlack(_machO(sectionOffsets: [0, 380])), 44);
    });

    test('refuses what is not a 64-bit Mach-O', () {
      expect(
        () => machOHeaderSlack(Uint8List.fromList([0xca, 0xfe, 0xba, 0xbe])),
        throwsFormatException,
      );
      final elf = Uint8List(64)..setAll(0, [0x7f, 0x45, 0x4c, 0x46]);
      expect(() => machOHeaderSlack(elf), throwsFormatException);
    });

    final cached = File(
      '${Platform.environment['HOME']}/Library/Caches/litertlm_dart/native/'
      '$liteRtLmNativeReleaseTag/macos_arm64/'
      'libGemmaModelConstraintProvider.dylib',
    );
    test(
      "Google's prebuilt provider has 64 bytes",
      () => expect(machOHeaderSlack(cached.readAsBytesSync()), 64),
      skip: cached.existsSync() ? false : 'the macOS archive in the cache only',
    );
  });

  group('the JIT asset directory', () {
    const id = '@rpath/libGemmaModelConstraintProvider.dylib';

    test('an LC_ID_DYLIB is 24 bytes, the name and its NUL, to 8', () {
      expect(dylibIdCommandSize(id), 72); // otool -l: cmdsize 72
      expect(dylibIdCommandSize('x' * 7), 32);
      expect(dylibIdCommandSize('x' * 8), 40);
    });

    test('a temporary directory since Dart 3.14, .dart_tool/lib before', () {
      for (final (version, temp) in [
        (
          '3.14.0 (stable) (Wed Nov 4 16:28:39 2026 -0800) on "macos_arm64"',
          true,
        ),
        ('3.15.0-12.0.dev (dev) on "macos_arm64"', true),
        ('4.0.0 (stable) on "macos_arm64"', true),
        (
          '3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "macos_arm64"',
          false,
        ),
        (
          '3.12.0 (stable) (Fri May 8 01:51:14 2026 -0700) on "macos_arm64"',
          false,
        ),
      ]) {
        expect(dartJitUsesTempDir(version), temp, reason: version);
      }
      // An SDK this hook cannot read the version of is a current one.
      expect(dartJitUsesTempDir('main (dev)'), isTrue);
    });

    test('the root package is the one owning the hooks runner', () {
      expect(
        dartToolOwnerOf(
          Uri.directory(
            '/w/app/.dart_tool/hooks_runner/shared/litertlm_dart/build/',
          ),
        ),
        '/w/app',
      );
      expect(dartToolOwnerOf(Uri.directory('/w/app/out/')), isNull);
      // A .dart_tool the hooks runner does not own (build_runner's).
      expect(
        dartToolOwnerOf(Uri.directory('/w/app/.dart_tool/build/generated/')),
        isNull,
      );
    });

    test('the directories the SDKs write', () {
      expect(
        const DartJitTempDir('/private/var/folders/ab/cd/T/').path,
        '/private/var/folders/ab/cd/T/dart_native_assets_XXXXXX/lib',
      );
      expect(const DartJitProjectDir('/w/app').path, '/w/app/.dart_tool/lib');
    });

    test("3.14+: macOS's default temporary directory fits in 64 bytes", () {
      // /var/folders/xx/<28>/T with its symbolic link resolved.
      const macOSDefault =
          '/private/var/folders/3h/0y5_f3c539n_829qycm5gd6h0000gn/T';
      expect(macOSDefault, hasLength(56));
      for (final tmp in [macOSDefault, '/tmp']) {
        expect(
          dartJitInstallNameRefusal(
            dir: DartJitTempDir(tmp),
            slack: 64,
            currentId: id,
          ),
          isNull,
        );
      }
    });

    test('3.14+: 65 characters fit; 66 are refused, naming TMPDIR', () {
      expect(
        dartJitInstallNameRefusal(
          dir: DartJitTempDir('/${'t' * 64}'),
          slack: 64,
          currentId: id,
        ),
        isNull,
      );
      final refusal = dartJitInstallNameRefusal(
        dir: DartJitTempDir('/${'t' * 65}'),
        slack: 64,
        currentId: id,
      );
      expect(refusal, contains('temporary directory'));
      expect(refusal, contains('(66 characters)'));
      expect(refusal, contains('65 characters at most'));
      expect(refusal, contains('TMPDIR=/tmp'));
      expect(refusal, contains('dart build cli is not affected'));
    });

    test('3.12/3.13: a package path of 80 characters fits; 81 are refused, '
        'naming the package path', () {
      expect(
        dartJitInstallNameRefusal(
          dir: DartJitProjectDir('/${'p' * 79}'),
          slack: 64,
          currentId: id,
        ),
        isNull,
      );
      final refusal = dartJitInstallNameRefusal(
        dir: DartJitProjectDir('/${'p' * 80}'),
        slack: 64,
        currentId: id,
      );
      expect(refusal, contains("the package's directory /ppp"));
      expect(refusal, contains('(81 characters)'));
      expect(refusal, contains('80 characters at most'));
      expect(refusal, contains('shorter path'));
      expect(refusal, isNot(contains('TMPDIR')));
    });
  });
}
