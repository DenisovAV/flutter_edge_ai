// The own-build check every libLiteRtLm open goes through: another package's
// LiteRT-LM under our library's name (llamadart before 0.12.0 bundles one by
// default) is refused right after the open, naming the cause and the fix,
// instead of being bound and failing later somewhere unrelated.
//
// The check itself runs on any host through its symbol probe. The real-library
// cases need the hook's macOS download cache (a macOS dev box has it after any
// example build) or LITERTLM_DYLIB=<path>, and skip without it.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_io.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/backend_preference.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_runtime_check.dart';
import 'package:flutter_test/flutter_test.dart';

const _iosPath = '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm';

/// A foreign LiteRT-LM: it exports the upstream C API (llamadart's v0.17.0-8
/// build has `litert_lm_engine_create`), so every lookup but ours succeeds.
bool _foreign(String symbol) => symbol != liteRtLmOwnBuildSymbol;

String? _hostDylib() => firstExistingPath(
  hostNativeLibraryCandidates(
    libFileName: hostNativeLibraryFileName('LiteRtLm'),
    envOverride: Platform.environment['LITERTLM_DYLIB'],
  ),
);

/// The C library of this host: a real handle that cannot export the sentinel
/// (a handle's lookup searches that image and its dependencies only).
String? _hostCLibrary() => Platform.isMacOS
    ? '/usr/lib/libSystem.B.dylib'
    : Platform.isLinux
    ? 'libc.so.6'
    : Platform.isWindows
    ? 'kernel32.dll'
    : null;

void main() {
  group('checkOwnLiteRtLmBuild', () {
    test('passes a library that exports our sentinel', () {
      expect(
        () => checkOwnLiteRtLmBuild(
          (symbol) => symbol == liteRtLmOwnBuildSymbol,
          path: _iosPath,
        ),
        returnsNormally,
      );
    });

    test('refuses a foreign LiteRT-LM by path and symbol, naming the cause '
        'and the fix', () {
      expect(
        () => checkOwnLiteRtLmBuild(_foreign, path: _iosPath),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(
                'The LiteRT-LM library at $_iosPath is not the one '
                'flutter_edge_ai_litertlm ships',
              ),
              contains('(it lacks $liteRtLmOwnBuildSymbol)'),
              contains(
                'Another package in this app bundles its own LiteRT-LM under '
                'the same name — llamadart before 0.12.0 does by default. '
                'Upgrade llamadart, or set',
              ),
              contains(
                'remove llamadart_litert_lm_flutter if it depends on it',
              ),
              contains(
                '`hooks: user_defines: llamadart: '
                'llamadart_native_runtimes: [llama_cpp]`',
              ),
              contains("in the app's pubspec.yaml"),
            ),
          ),
        ),
      );
    });

    test('asks only for the sentinel', () {
      final asked = <String>[];
      checkOwnLiteRtLmBuild((symbol) {
        asked.add(symbol);
        return true;
      }, path: 'libLiteRtLm.so');
      expect(asked, [liteRtLmOwnBuildSymbol]);
    });

    test('is an Error: the backend fallback loop stops at the first backend '
        'instead of retrying the same library on the next', () async {
      final backends = ffiBackendFallbackOrder(
        PreferredBackend.gpu,
        npuAvailable: false,
      );
      expect(
        backends.length,
        greaterThan(1),
        reason: 'gpu must have a fallback for this case to mean anything',
      );
      final tried = <PreferredBackend>[];
      await expectLater(
        initializeFfiRuntime<Object>(
          preferredBackend: PreferredBackend.gpu,
          backends: backends,
          logTag: '[Test]',
          createClient: Object.new,
          initializeClient: (_, backend) async {
            tried.add(backend);
            checkOwnLiteRtLmBuild(_foreign, path: _iosPath);
          },
          shutdownClient: (_) {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(liteRtLmOwnBuildSymbol),
          ),
        ),
      );
      expect(tried, [PreferredBackend.gpu]);
    });
  });

  group('the sentinel', () {
    test('is ours: no upstream C API header at the pin declares it, and '
        'patch_c_api.sh adds it and exports it from the Windows DLL', () {
      // include/c/ is upstream's `c/` copied verbatim at the pin (plus the
      // section 14 getters) and replaced at every pin bump, so this fails the
      // bump that makes the sentinel upstream's.
      final headers = [
        for (final f in Directory('native/litert_lm/include/c').listSync())
          if (f is File && f.path.endsWith('.h')) f,
      ];
      expect(
        headers.map((f) => f.uri.pathSegments.last),
        containsAll(['engine.h', 'error_reporter.h']),
      );
      for (final header in headers) {
        expect(
          header.readAsStringSync(),
          isNot(contains(liteRtLmOwnBuildSymbol)),
          reason: '${header.path} is upstream',
        );
      }

      final patch = File('native/litert_lm/patch_c_api.sh').readAsStringSync();
      expect(
        patch,
        contains('void $liteRtLmOwnBuildSymbol(\\'),
        reason: 'section 4c declares and defines it',
      );
      expect(
        patch,
        contains('\n  $liteRtLmOwnBuildSymbol\n'),
        reason: 'the Windows .def exports it',
      );
    });

    test('the release gate requires it from every native archive', () {
      // check_embedding_exports.py runs on each of the seven tarballs
      // (verify_tarball_manifest.sh); the host test below sees one of them.
      final gate = File(
        'native/litert_lm/check_embedding_exports.py',
      ).readAsStringSync();
      final listed = RegExp(
        r'OWN_BUILD_SYMBOLS = \[(.*?)\]',
        dotAll: true,
      ).firstMatch(gate)!.group(1)!;
      expect(
        [for (final m in RegExp(r'"([a-z_]+)"').allMatches(listed)) m.group(1)],
        [liteRtLmOwnBuildSymbol],
      );
      expect(
        gate,
        contains('(OWN_BUILD_SYMBOLS, '),
        reason: 'main() must check the list, not only declare it',
      );
    });

    final dylib = _hostDylib();
    final noDylib = dylib == null
        ? 'no host libLiteRtLm in the download cache'
        : null;

    test('is exported by the host libLiteRtLm this package ships', () {
      final library = DynamicLibrary.open(dylib!);
      expect(requireOwnLiteRtLmBuild(library, dylib), same(library));
    }, skip: noDylib);

    test('LiteRtBindings.open() does not refuse the host libLiteRtLm (macOS '
        'dev candidates)', () {
      expect(LiteRtBindings.open, returnsNormally);
    }, skip: Platform.isMacOS ? noDylib : 'the dev candidates are macOS-only');
  });

  // A foreign framework cannot be planted under the app's name on a host, so
  // the guard is held in the source: every open of libLiteRtLm hands its
  // handle to requireOwnLiteRtLmBuild, and a new open must do the same.
  group('every open of libLiteRtLm goes through the check', () {
    // An open of the library: an opener whose argument is the path constant
    // the loaders name it by, or the macOS framework loaders.
    final opens = RegExp(
      r'(?:DynamicLibrary\.open|openLiteRtLm(?:Preferring|Requiring)'
      r'DefaultScope|openBundledWindowsLibrary)\((?:libPath|path|bundled)\)'
      r'|openMacOSLiteRtLm\w*\(',
    );
    String code(String file) => File(file)
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    for (final (file, count) in const [
      ('lib/src/ffi/litert_lm_library.dart', 5),
      ('lib/src/ffi/litert_lm_client.dart', 5),
      ('lib/src/ffi/litert_bindings.dart', 3),
    ]) {
      test(file, () {
        final source = code(file);
        expect(opens.allMatches(source), hasLength(count));
        expect(
          'requireOwnLiteRtLmBuild('.allMatches(source),
          hasLength(count),
          reason: 'one check per open',
        );
      });
    }

    test('a macOS dev copy that is not ours is skipped, not returned', () {
      expect(
        code('lib/src/ffi/litert_bindings.dart'),
        matches(
          RegExp(
            r'isOwnBuild:\s*\(library\)\s*=>\s*'
            r'library\.providesSymbol\(liteRtLmOwnBuildSymbol\)',
          ),
        ),
      );
    });

    test('no other file opens it by name', () {
      final byName = RegExp(
        r'''(?:DynamicLibrary\.open|open\w*Library|openLiteRtLm\w*)\(\s*['"]'''
        r'''[^'"]*LiteRtLm[.'"/]''',
      );
      final checked = {
        'lib/src/ffi/litert_lm_library.dart',
        'lib/src/ffi/litert_lm_client.dart',
        'lib/src/ffi/litert_bindings.dart',
      };
      final offenders = [
        for (final dir in Directory('..').listSync().whereType<Directory>())
          if (Directory('${dir.path}/lib').existsSync())
            for (final f in Directory(
              '${dir.path}/lib',
            ).listSync(recursive: true))
              if (f is File &&
                  f.path.endsWith('.dart') &&
                  !checked.any(
                    (c) => f.path.endsWith('flutter_edge_ai_litertlm/$c'),
                  ) &&
                  byName.hasMatch(code(f.path)))
                f.path,
      ];
      expect(offenders, isEmpty);
    });
  });

  test('a real library without the sentinel is refused', () {
    final path = _hostCLibrary()!;
    expect(
      () => requireOwnLiteRtLmBuild(DynamicLibrary.open(path), path),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('The LiteRT-LM library at $path is not the one'),
        ),
      ),
    );
  }, skip: _hostCLibrary() == null ? 'no known C library on this host' : null);
}
