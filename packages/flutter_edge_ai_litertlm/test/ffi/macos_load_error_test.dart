// The macOS load error names the cause and the fix (#689).
//
// The dyld texts below were measured on macOS 26.5 with the native-v0.18.0-f
// libLiteRtLm (paths shortened); the Team ID one is Apple's documented text.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/engine_io.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/macos_load_error.dart';
import 'package:flutter_test/flutter_test.dart';

const _missingCompanion =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): Library not loaded: "
    '@rpath/libGemmaModelConstraintProvider.dylib\n'
    '  Referenced from: <0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '
    '/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm\n'
    "  Reason: tried: '/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/"
    "Versions/A/libGemmaModelConstraintProvider.dylib' (no such file)";

const _wrongArchitecture =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'LiteRtLm.framework/LiteRtLm' (no such file), "
    "'/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/LiteRtLm' "
    "(mach-o file, but is an incompatible architecture (have 'arm64', need "
    "'x86_64')), '/usr/lib/LiteRtLm.framework/LiteRtLm' (no such file, not in "
    'dyld cache)';

const _notBundled =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'LiteRtLm.framework/LiteRtLm' (no such file), "
    "'/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/LiteRtLm' "
    "(no such file), '/usr/lib/LiteRtLm.framework/LiteRtLm' (no such file, not "
    'in dyld cache)';

const _libraryValidation =
    "dlopen(LiteRtLm.framework/LiteRtLm, 0x0002): tried: "
    "'/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/LiteRtLm' "
    '(code signature in <0D589743-9A44-3E57-A0AF-BC3EFE258BA3> '
    "'/Applications/app.app/Contents/Frameworks/LiteRtLm.framework/LiteRtLm' "
    'not valid for use in process: mapping process and mapped file '
    '(non-platform) have different Team IDs)';

void main() {
  group('diagnoseMacOSLoadError', () {
    test('reads each cause from dyld text', () {
      expect(
        diagnoseMacOSLoadError(_missingCompanion),
        MacOSLoadCause.missingCompanion,
      );
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
        diagnoseMacOSLoadError('dlopen: something else entirely'),
        MacOSLoadCause.unknown,
      );
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
        startsWith('flutter_edge_ai_litertlm: LiteRT-LM did not load on macOS'),
      );
      expect(message, contains('LLM, embeddings, speech'));
      expect(message, contains('Swift Package Manager'));
      expect(message, contains('enable-swift-package-manager: false'));
      expect(message, contains('https://flutteredge.ai/docs/desktop#macos'));
      expect(message, endsWith('dyld: $_missingCompanion'));
    });

    test('each cause gets its own fix', () {
      expect(macOSLoadErrorMessage(_wrongArchitecture), contains('arm64'));
      expect(
        macOSLoadErrorMessage(_libraryValidation),
        contains('com.apple.security.cs.disable-library-validation'),
      );
      expect(macOSLoadErrorMessage(_notBundled), contains('flutter clean'));
      expect(
        macOSLoadErrorMessage('dlopen: something else entirely'),
        contains('please open an issue'),
      );
    });
  });

  group('openMacOSLiteRtLm', () {
    test('rethrows a failed open as an ArgumentError naming the cause', () {
      Object? thrown;
      try {
        openMacOSLiteRtLm(
          open: (path) => throw ArgumentError(
            "Failed to load dynamic library '$path': $_missingCompanion",
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      // The backend fallback retries on an Exception only; a load failure must
      // not turn into a CPU attempt that hides it.
      expect(thrown, isNot(isA<Exception>()));
      final message = '${(thrown! as ArgumentError).message}';
      expect(message, contains('Swift Package Manager'));
      expect(message, contains("Failed to load dynamic library '"));
    });

    test('opens LiteRtLm.framework/LiteRtLm', () {
      String? asked;
      final process = DynamicLibrary.process();
      expect(
        openMacOSLiteRtLm(
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
        () => openMacOSLiteRtLm(open: (_) => throw error),
        throwsA(same(error)),
      );
    });
  });

  group('macOSFallbackCandidates', () {
    List<String> dev() => ['/cache/libLiteRtLm.dylib'];

    test('none inside an app', () {
      expect(
        macOSFallbackCandidates(
          executable: '/Applications/app.app/Contents/MacOS/app',
          devCandidates: dev,
        ),
        isEmpty,
      );
    });

    test('the dev candidates outside one', () {
      expect(
        macOSFallbackCandidates(
          executable: '/Users/me/flutter/bin/cache/flutter_tester',
          devCandidates: dev,
        ),
        dev(),
      );
    });
  });

  // The real thing: libLiteRtLm without its constraint provider beside it, the
  // situation of an app built with Swift Package Manager.
  final String? dylib = Platform.isMacOS
      ? firstExistingPath(
          hostNativeLibraryCandidates(
            libFileName: hostNativeLibraryFileName('LiteRtLm'),
            envOverride: Platform.environment['LITERTLM_DYLIB'],
          ),
        )
      : null;
  test(
    'a real libLiteRtLm without its companion names the cause',
    () {
      final dir = Directory.systemTemp.createTempSync('macos_load_error');
      addTearDown(() => dir.deleteSync(recursive: true));
      final framework = Directory('${dir.path}/LiteRtLm.framework')
        ..createSync();
      final binary = File(dylib!).copySync('${framework.path}/LiteRtLm');

      Object? thrown;
      try {
        openMacOSLiteRtLm(open: (_) => DynamicLibrary.open(binary.path));
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      final message = '${(thrown! as ArgumentError).message}';
      expect(message, contains('Swift Package Manager'));
      // A copy the Podfile stager touched names the provider in its framework
      // form, so the spelling is not pinned.
      expect(message, contains('Library not loaded: @rpath/'));
      expect(message, contains('GemmaModelConstraintProvider'));
    },
    skip: dylib == null
        ? 'macOS with a libLiteRtLm in the hook cache or LITERTLM_DYLIB only'
        : false,
  );
}
