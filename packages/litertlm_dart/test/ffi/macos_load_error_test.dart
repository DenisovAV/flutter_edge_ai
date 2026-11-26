// The macOS load error names the cause and the fix (#689).
//
// The dyld texts below were measured on macOS 26.5 with the native-v0.18.0-f
// libLiteRtLm, in a Swift Package Manager app (paths shortened), or are built
// around a measured fragment where marked. The code signature, policy and
// symbol ones are assembled from Apple's documented wording.

import 'dart:ffi';
import 'dart:io';

import 'package:litertlm_dart/src/runtime/host_native_library.dart';
import 'package:litertlm_dart/src/ffi/macos_load_error.dart';
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
import 'package:test/test.dart';

const _app = '/Applications/app.app/Contents';

const _missingCompanion =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: "
    '@rpath/libGemmaModelConstraintProvider.dylib\n'
    '  Referenced from: <0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '
    '$_app/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm\n'
    "  Reason: tried: '$_app/Frameworks/LiteRtLm.framework/Versions/A/"
    "libGemmaModelConstraintProvider.dylib' (no such file)";

// Built around the measured "incompatible architecture" fragment.
const _wrongArchitecture =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'LiteRtLm.framework/LiteRtLm' (no such file), "
    "'$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (mach-o file, but is an "
    "incompatible architecture (have 'arm64', need 'x86_64')), "
    "'/usr/lib/LiteRtLm.framework/LiteRtLm' (no such file, not in dyld cache)";

const _notBundled =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'LiteRtLm.framework/LiteRtLm' (no such file), "
    "'/System/Volumes/Preboot/Cryptexes/OSLiteRtLm.framework/LiteRtLm' (no "
    "such file), '$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (no such "
    "file), '/usr/lib/LiteRtLm.framework/LiteRtLm' (no such file, not in dyld "
    "cache), 'LiteRtLm.framework/LiteRtLm' (no such file)";

// Built around the measured "slice is not valid mach-o file" fragment.
const _corruptFramework =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'LiteRtLm.framework/LiteRtLm' (no such file), "
    "'$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (slice is not valid "
    "mach-o file), '/usr/lib/LiteRtLm.framework/LiteRtLm' (no such file, not "
    "in dyld cache), 'LiteRtLm.framework/LiteRtLm' (no such file)";

const _libraryValidation =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (code signature in "
    "<0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '$_app/Frameworks/LiteRtLm."
    "framework/LiteRtLm' not valid for use in process: mapping process and "
    'mapped file (non-platform) have different Team IDs)';

// The companion is in the app but signed by another team: the advice must not
// be the workaround again.
const _companionRefused =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: "
    '@rpath/GemmaModelConstraintProvider.framework/Versions/A/'
    'GemmaModelConstraintProvider\n'
    "  Reason: tried: '$_app/Frameworks/GemmaModelConstraintProvider.framework/"
    "Versions/A/GemmaModelConstraintProvider' (code signature in "
    "<0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '$_app/Frameworks/"
    "GemmaModelConstraintProvider.framework/Versions/A/"
    "GemmaModelConstraintProvider' not valid for use in process: mapping "
    'process and mapped file (non-platform) have different Team IDs)';

const _blockedByPolicy =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (code signature in "
    "<0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '$_app/Frameworks/LiteRtLm."
    "framework/LiteRtLm' not valid for use in process: library load "
    'disallowed by system policy)';

// An ad-hoc-signed framework under Hardened Runtime without the library
// validation exception.
const _adHocRefused =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'$_app/Frameworks/LiteRtLm.framework/LiteRtLm' (code signature in "
    "<0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '$_app/Frameworks/LiteRtLm."
    "framework/LiteRtLm' not valid for use in process: mapped file has no "
    'Team ID and is not a platform binary (signed with custom identity or '
    'adhoc?))';

const _companionWrongArchitecture =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: "
    '@rpath/libGemmaModelConstraintProvider.dylib\n'
    "  Reason: tried: '$_app/Frameworks/LiteRtLm.framework/Versions/A/"
    "libGemmaModelConstraintProvider.dylib' (mach-o file, but is an "
    "incompatible architecture (have 'x86_64', need 'arm64'))";

const _companionBlocked =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: "
    '@rpath/GemmaModelConstraintProvider.framework/Versions/A/'
    'GemmaModelConstraintProvider\n'
    "  Reason: tried: '$_app/Frameworks/GemmaModelConstraintProvider.framework/"
    "Versions/A/GemmaModelConstraintProvider' (code signature in "
    "<0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '$_app/Frameworks/"
    "GemmaModelConstraintProvider.framework/Versions/A/"
    "GemmaModelConstraintProvider' not valid for use in process: library "
    'load disallowed by system policy)';

// A companion from another native version: the provider loads, a symbol
// does not resolve.
const _symbolNotFound =
    'dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Symbol not found: '
    '__ZN6litert2lm28GemmaModelConstraintProvider6CreateEv\n'
    '  Referenced from: <0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '
    '$_app/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm\n'
    '  Expected in:     <4C4C4472-5555-3144-A1A2-2E0A54650C0F> '
    '$_app/Frameworks/GemmaModelConstraintProvider.framework/Versions/A/'
    'GemmaModelConstraintProvider';

ArgumentError _loadFailure(String dyldText) =>
    ArgumentError("Failed to load dynamic library 'x': $dyldText");

Object? _thrownBy(void Function() body) {
  try {
    body();
  } catch (error) {
    return error;
  }
  return null;
}

void main() {
  group('diagnoseMacOSLoadError', () {
    test('reads each cause from dyld text', () {
      expect(
        diagnoseMacOSLoadError(_wrongArchitecture),
        MacOSLoadCause.wrongArchitecture,
      );
      expect(diagnoseMacOSLoadError(_notBundled), MacOSLoadCause.notBundled);
      expect(
        diagnoseMacOSLoadError(_libraryValidation),
        MacOSLoadCause.libraryValidation,
      );
      expect(
        diagnoseMacOSLoadError(_blockedByPolicy),
        MacOSLoadCause.blockedByPolicy,
      );
    });

    test('a companion that is there but refused is not a missing one', () {
      expect(
        diagnoseMacOSLoadError(_companionRefused),
        MacOSLoadCause.libraryValidation,
      );
      expect(
        diagnoseMacOSLoadError(_companionBlocked),
        MacOSLoadCause.blockedByPolicy,
      );
      expect(
        diagnoseMacOSLoadError(_companionWrongArchitecture),
        MacOSLoadCause.wrongArchitecture,
      );
    });

    test('an ad-hoc signature refused is library validation', () {
      expect(
        diagnoseMacOSLoadError(_adHocRefused),
        MacOSLoadCause.libraryValidation,
      );
    });

    test('a companion from another version is not a missing one', () {
      expect(diagnoseMacOSLoadError(_symbolNotFound), MacOSLoadCause.unknown);
    });

    test('a constraint provider an older build links is a stale build, not a '
        'setup step: LiteRtLm links no companion from native-v0.20.0-a', () {
      expect(diagnoseMacOSLoadError(_missingCompanion), MacOSLoadCause.unknown);
    });

    test('a framework that is there but broken is not a missing one', () {
      expect(diagnoseMacOSLoadError(_corruptFramework), MacOSLoadCause.unknown);
    });

    test('a library that is not a LiteRT-LM companion is not one', () {
      expect(
        diagnoseMacOSLoadError(
          'dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: '
          '@rpath/libSomethingElse.dylib',
        ),
        MacOSLoadCause.unknown,
      );
    });
  });

  group('macOSLoadErrorMessage', () {
    test('names what broke, the fix, and keeps dyld text', () {
      final message = macOSLoadErrorMessage(_missingCompanion);
      expect(
        message,
        startsWith('litertlm_dart: LiteRT-LM did not load on macOS'),
      );
      expect(message, contains('LLM, embeddings, speech'));
      // A companion is never a setup step any more: a stale build.
      expect(message, contains('flutter clean'));
      expect(message, isNot(contains('Podfile')));
      expect(message, isNot(contains('Frameworks (xcframework')));
      expect(message, endsWith('dyld: $_missingCompanion'));
    });

    test('each cause gets its own fix', () {
      expect(
        macOSLoadErrorMessage(_wrongArchitecture),
        contains('Apple silicon (arm64) only'),
      );
      expect(
        macOSLoadErrorMessage(_libraryValidation),
        contains('com.apple.security.cs.disable-library-validation'),
      );
      expect(
        macOSLoadErrorMessage(_blockedByPolicy),
        contains('com.apple.quarantine'),
      );
      expect(macOSLoadErrorMessage(_notBundled), contains('is not in the app'));
      final unknown = macOSLoadErrorMessage(_corruptFramework);
      expect(unknown, contains('flutter clean'));
      expect(unknown, contains('please open an issue'));
      expect(unknown, isNot(contains('is not in the app')));
    });
  });

  group('openMacOSLiteRtLm', () {
    test('rethrows a failed open as an ArgumentError naming the cause', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLm(
          outsideFlutter: false,
          open: (path) => throw ArgumentError(
            "Failed to load dynamic library '$path': $_missingCompanion",
          ),
        ),
      );
      expect(thrown, isA<ArgumentError>());
      // The backend fallback retries on an Exception only; a load failure must
      // not turn into a CPU attempt that hides it.
      expect(thrown, isNot(isA<Exception>()));
      final message = '${(thrown! as ArgumentError).message}';
      expect(message, contains('flutter clean'));
      expect(message, contains("Failed to load dynamic library '"));
    });

    test('opens LiteRtLm.framework/LiteRtLm', () {
      String? asked;
      final process = DynamicLibrary.process();
      expect(
        openMacOSLiteRtLm(
          outsideFlutter: false,
          open: (path) {
            asked = path;
            return process;
          },
        ),
        same(process),
      );
      expect(asked, 'LiteRtLm.framework/LiteRtLm');
    });

    test('lets any other error through unchanged', () {
      final error = StateError('not a load failure');
      expect(
        () =>
            openMacOSLiteRtLm(outsideFlutter: false, open: (_) => throw error),
        throwsA(same(error)),
      );
    });
  });

  group('openMacOSLiteRtLmForTflite', () {
    const inApp = '/Applications/app.app/Contents/MacOS/app';
    const tester =
        '/flutter/bin/cache/artifacts/engine/darwin-x64/flutter_tester';
    final process = DynamicLibrary.process();

    test('returns the framework when it loads', () {
      expect(
        openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => fail('not consulted'),
          executable: inApp,
          open: (path) => process,
        ),
        same(process),
      );
    });

    test('inside an app, never tries a cached copy', () {
      var asked = false;
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () {
            asked = true;
            return ['/cache/libLiteRtLm.dylib'];
          },
          executable: inApp,
          open: (path) => throw _loadFailure(_missingCompanion),
          exists: (_) => true,
        ),
      );
      expect(asked, isFalse);
      expect(thrown, isA<UnsupportedError>());
      final message = '${(thrown! as UnsupportedError).message}';
      expect(message, contains('did not load on macOS'));
      expect(message, contains('dyld: '));
    });

    test(
      'outside an app, a copy that does not load does not hide one that does',
      () {
        final opened = <String>[];
        expect(
          openMacOSLiteRtLmForTflite(
            outsideFlutter: false,
            devCandidates: () => [
              '/dev/libLiteRtLm.dylib',
              '/cache/libLiteRtLm.dylib',
            ],
            executable: tester,
            open: (path) {
              opened.add(path);
              if (path == '/cache/libLiteRtLm.dylib') return process;
              throw _loadFailure('no');
            },
            exists: (_) => true,
          ),
          same(process),
        );
        expect(opened, [
          'LiteRtLm.framework/LiteRtLm',
          '/dev/libLiteRtLm.dylib',
          '/cache/libLiteRtLm.dylib',
        ]);
      },
    );

    test('the framework is returned without isOwnBuild: the caller refuses a '
        'foreign one itself, so it is never skipped for a dev copy', () {
      expect(
        openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => fail('not consulted'),
          isOwnBuild: (_) => fail('not asked for the framework'),
          executable: tester,
          open: (path) => process,
        ),
        same(process),
      );
    });

    test('outside an app, a copy that loads but is not our build is skipped '
        'like one that does not load', () {
      final foreign = DynamicLibrary.executable();
      final opened = <String>[];
      expect(
        openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => [
            '/dev/libLiteRtLm.dylib',
            '/cache/libLiteRtLm.dylib',
          ],
          isOwnBuild: (library) => !identical(library, foreign),
          executable: tester,
          open: (path) {
            opened.add(path);
            if (path == '/dev/libLiteRtLm.dylib') return foreign;
            if (path == '/cache/libLiteRtLm.dylib') return process;
            throw _loadFailure(_notBundled);
          },
          exists: (_) => true,
        ),
        same(process),
      );
      expect(opened, [
        'LiteRtLm.framework/LiteRtLm',
        '/dev/libLiteRtLm.dylib',
        '/cache/libLiteRtLm.dylib',
      ]);
    });

    test('outside an app, names a copy that is not our build', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => ['/dev/libLiteRtLm.dylib'],
          isOwnBuild: (_) => false,
          executable: tester,
          open: (path) => path == '/dev/libLiteRtLm.dylib'
              ? process
              : throw _loadFailure(_notBundled),
          exists: (_) => true,
        ),
      );
      expect(thrown, isA<UnsupportedError>());
      expect(
        '${(thrown! as UnsupportedError).message}',
        contains(
          '/dev/libLiteRtLm.dylib: loads, but is not a litertlm_dart '
          'build',
        ),
      );
    });

    test('outside an app, names each copy that failed and why', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => [
            '/gone/libLiteRtLm.dylib',
            '/cache/libLiteRtLm.dylib',
          ],
          executable: tester,
          open: (path) => throw _loadFailure(
            path == '/cache/libLiteRtLm.dylib'
                ? _missingCompanion
                : _notBundled,
          ),
          exists: (path) => path == '/cache/libLiteRtLm.dylib',
        ),
      );
      expect(thrown, isA<UnsupportedError>());
      final message = '${(thrown! as UnsupportedError).message}';
      expect(message, contains('/cache/libLiteRtLm.dylib: '));
      expect(message, contains('Library not loaded'));
      expect(message, contains('Not found: /gone/libLiteRtLm.dylib'));
      // An app's advice would be wrong for a host test.
      expect(message, isNot(contains('did not load on macOS')));
      expect(message, isNot(contains('is not in the app')));
    });

    test('outside an app with no copy, says so', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => ['/cache/libLiteRtLm.dylib'],
          executable: tester,
          open: (path) => throw _loadFailure(_notBundled),
          exists: (_) => false,
        ),
      );
      final message = '${(thrown! as UnsupportedError).message}';
      expect(message, contains('No copy exists.'));
      expect(message, contains('Not found: /cache/libLiteRtLm.dylib'));
      // The framework's own reason is kept, in case it is there but broken.
      expect(
        message,
        contains(
          '\nLiteRtLm.framework/LiteRtLm: Failed to load dynamic library',
        ),
      );
    });

    test('by default reads the running executable and the disk', () {
      // flutter_tester, which runs this file, is not inside an app, so the
      // copies are tried; the existence check is the real one.
      final dir = Directory.systemTemp.createTempSync('tflite_open');
      addTearDown(() => dir.deleteSync(recursive: true));
      final copy = File('${dir.path}/libLiteRtLm.dylib')..writeAsStringSync('');
      expect(
        openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => ['${dir.path}/missing.dylib', copy.path],
          open: (path) =>
              path == copy.path ? process : throw _loadFailure(_notBundled),
        ),
        same(process),
      );
    });

    test('lets any other error through unchanged', () {
      final error = StateError('not a load failure');
      expect(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: false,
          devCandidates: () => fail('not reached'),
          executable: tester,
          open: (_) => throw error,
        ),
        throwsA(same(error)),
      );
    });
  });

  // The real thing: libLiteRtLm alone in a framework directory, nothing
  // beside it. From native-v0.20.0-a it links no companion, so it loads.
  // LiteRT-LM ships macOS arm64 only, so another host has nothing to load.
  final String? dylib = Platform.isMacOS && Abi.current() == Abi.macosArm64
      ? firstExistingPath(
          hostNativeLibraryCandidates(
            libFileName: hostNativeLibraryFileName('LiteRtLm'),
            envOverride: Platform.environment['LITERTLM_DYLIB'],
          ),
        )
      : null;
  final bool olderDylib =
      dylib != null && machOLinkedDylibsOf(dylib).any(linksConstraintProvider);
  test(
    'a real libLiteRtLm loads with no companion beside it',
    () {
      final dir = Directory.systemTemp.createTempSync('macos_load_error');
      addTearDown(() => dir.deleteSync(recursive: true));
      final framework = Directory('${dir.path}/LiteRtLm.framework')
        ..createSync();
      final binary = File(dylib!).copySync('${framework.path}/LiteRtLm');
      expect(
        openMacOSLiteRtLm(
          outsideFlutter: false,
          open: (_) => DynamicLibrary.open(binary.path),
        ),
        isA<DynamicLibrary>(),
      );
    },
    skip: dylib == null
        ? 'macOS arm64 with a libLiteRtLm in the hook cache or LITERTLM_DYLIB '
              'only'
        : olderDylib
        ? '$dylib is a build of a release before native-v0.20.0-a: it links '
              'the constraint provider'
        : false,
  );

  group('in a plain Dart program', () {
    final process = DynamicLibrary.process();
    const found = NativeAssetsFound('/t/lib');
    const plainDart = MacOSPlainDartAssets('/t/lib');

    test('an older build is told by what LiteRtLm links, whatever files lie '
        'beside it', () {
      MacOSCodeAssets assetsOf(
        NativeAssetLookup lookup,
        List<String> Function(String path) linkedBy,
      ) => macOSCodeAssets(lookup: () => lookup, linkedBy: linkedBy);
      List<String> never(String path) => fail('read $path');

      expect(
        assetsOf(const NativeAssetsAbsent('No asset with id'), never),
        isA<MacOSNoCodeAssets>(),
      );
      expect(
        assetsOf(const NativeAssetsNotOurs('/usr/lib/x.dylib'), never),
        isA<MacOSNoCodeAssets>(),
      );
      // From native-v0.20.0-a LiteRtLm links no companion.
      expect(
        assetsOf(found, (path) {
          expect(path, '/t/lib/libLiteRtLm.dylib');
          return ['/usr/lib/libc++.1.dylib', '/usr/lib/libSystem.B.dylib'];
        }),
        isA<MacOSPlainDartAssets>().having((a) => a.dir, 'dir', '/t/lib'),
      );
      // An older release's build links the provider, in any of its forms:
      // Google's install name, a Flutter app's framework, and litertlm_dart
      // 0.19.1+4's code asset as the Dart SDK rewrote it (dart run, then
      // dart build cli).
      for (final name in [
        '@rpath/libGemmaModelConstraintProvider.dylib',
        '@rpath/GemmaModelConstraintProvider.framework/Versions/A/'
            'GemmaModelConstraintProvider',
        '/t/lib/libLtGmcp.dylib',
        '@rpath/lib/libLtGmcp.dylib',
      ]) {
        expect(
          assetsOf(found, (_) => ['/usr/lib/libc++.1.dylib', name]),
          isA<MacOSOlderBuildAssets>()
              .having((a) => a.dir, 'dir', '/t/lib')
              .having((a) => a.provider, 'provider', name),
          reason: name,
        );
      }
      expect(
        assetsOf(found, (_) => throw const FormatException('truncated')),
        isA<MacOSUnreadableAssets>().having(
          (a) => a.reason,
          'reason',
          'truncated',
        ),
      );
    });

    test('each case is refused in its own words', () {
      expect(macOSCodeAssetsRefusal(plainDart), isNull);
      final older = macOSCodeAssetsRefusal(
        const MacOSOlderBuildAssets(
          '/t/lib',
          '@rpath/libGemmaModelConstraintProvider.dylib',
        ),
      )!;
      expect(older, contains('/t/lib/libLiteRtLm.dylib'));
      expect(older, contains('@rpath/libGemmaModelConstraintProvider.dylib'));
      expect(older, contains('native-v0.20.0-a'));
      expect(older, contains('Build the program again'));
      expect(older, isNot(contains('macos_companions')));
      // A dart compile exe binary is not told to set the define.
      final absent = macOSCodeAssetsRefusal(
        const MacOSNoCodeAssets(NativeAssetsAbsent('No asset with id x')),
      )!;
      expect(absent, contains('dart compile exe'));
      expect(absent, isNot(contains('macos_companions')));
      expect(absent, contains('No asset with id x'));
      // An unreadable LiteRtLm is not told to set a define that is set.
      final unreadable = macOSCodeAssetsRefusal(
        const MacOSUnreadableAssets('/t/lib', 'truncated'),
      )!;
      expect(unreadable, contains('/t/lib/libLiteRtLm.dylib'));
      expect(unreadable, contains('truncated'));
      expect(unreadable, isNot(contains('macos_companions')));
    });

    test('opens libLiteRtLm among the code assets, and nothing else', () {
      final asked = <String>[];
      expect(
        openMacOSLiteRtLm(
          outsideFlutter: true,
          codeAssets: () => plainDart,
          open: (path) {
            asked.add(path);
            return process;
          },
        ),
        same(process),
      );
      expect(asked, ['/t/lib/libLiteRtLm.dylib']);
    });

    test('an older release\'s build is refused, saying why, and nothing is '
        'opened', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLm(
          outsideFlutter: true,
          codeAssets: () => const MacOSOlderBuildAssets('/t/lib', '@rpath/x'),
          open: (path) => fail('opened $path'),
        ),
      );
      expect(thrown, isA<ArgumentError>());
      final message = '${(thrown! as ArgumentError).message}';
      expect(message, contains('native-v0.20.0-a'));
      expect(message, contains('Build the program again'));
    });

    test('a code asset that does not load is named, with dyld\'s text', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLm(
          outsideFlutter: true,
          codeAssets: () => plainDart,
          open: (path) => throw _loadFailure(_wrongArchitecture),
        ),
      );
      expect(thrown, isA<ArgumentError>());
      final message = '${(thrown! as ArgumentError).message}';
      expect(message, contains('/t/lib/libLiteRtLm.dylib'));
      expect(message, contains('Apple silicon'));
      expect(message, contains('dyld: '));
    });

    test('the .tflite path opens the code asset and tries no other copy', () {
      final asked = <String>[];
      expect(
        openMacOSLiteRtLmForTflite(
          outsideFlutter: true,
          codeAssets: () => plainDart,
          devCandidates: () => fail('not consulted'),
          open: (path) {
            asked.add(path);
            return process;
          },
        ),
        same(process),
      );
      expect(asked, ['/t/lib/libLiteRtLm.dylib']);
    });

    test('the .tflite path without a loadable code asset refuses, never '
        'trying a copy from the cache: it would work on the developer\'s Mac '
        'only', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: true,
          codeAssets: () => const MacOSOlderBuildAssets('/t/lib', '@rpath/x'),
          allowHostCopies: false,
          devCandidates: () => fail('not consulted'),
          open: (path) => fail('opened $path'),
        ),
      );
      expect(thrown, isA<UnsupportedError>());
      expect(
        '${(thrown! as UnsupportedError).message}',
        contains('native-v0.20.0-a'),
      );
    });

    test('this package\'s own host tests may still try the copies, and the '
        'failure says why the code asset was not opened', () {
      final thrown = _thrownBy(
        () => openMacOSLiteRtLmForTflite(
          outsideFlutter: true,
          codeAssets: () => const MacOSOlderBuildAssets('/t/lib', '@rpath/x'),
          allowHostCopies: true,
          devCandidates: () => ['/cache/libLiteRtLm.dylib'],
          executable: '/usr/local/bin/dart',
          open: (path) => throw _loadFailure('no'),
          exists: (_) => true,
        ),
      );
      expect(thrown, isA<UnsupportedError>());
      final message = '${(thrown! as UnsupportedError).message}';
      expect(message, contains('/cache/libLiteRtLm.dylib: Failed to load'));
      expect(message, contains('native-v0.20.0-a'));
    });

    test('inside Flutter the code assets are never looked at', () {
      expect(
        openMacOSLiteRtLm(
          outsideFlutter: false,
          codeAssets: () => fail('looked up'),
          open: (path) => process,
        ),
        same(process),
      );
    });

    test('the opened path names the code asset in a plain Dart program and '
        'the framework in an app', () {
      expect(
        macOSLiteRtLmOpenedPath(outsideFlutter: false),
        'LiteRtLm.framework/LiteRtLm',
      );
    });
  });

  final cached = firstExistingPath(
    hostNativeLibraryCandidates(
      libFileName: hostNativeLibraryFileName('LiteRtLm'),
    ),
  );
  test(
    'the libLiteRtLm the hook bundles links no constraint provider',
    () {
      final linked = machOLinkedDylibsOf(cached!);
      expect(linked.where(linksConstraintProvider), isEmpty);
      expect(linked, contains('/usr/lib/libc++.1.dylib'));
    },
    skip: cached == null || !Platform.isMacOS
        ? 'macOS with a libLiteRtLm in the hook cache only'
        : machOLinkedDylibsOf(cached).any(linksConstraintProvider)
        ? '$cached is a build of a release before native-v0.20.0-a'
        : false,
  );
}
