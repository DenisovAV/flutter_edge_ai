// Where a plain Dart program's code assets are: the directory of the file
// that holds a StreamProxy symbol resolved through its asset id. `dart test`
// runs this package's build hook, so this suite is itself such a program.
@TestOn('vm')
library;

import 'dart:io';

import 'dart:ffi';

import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_library.dart';
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
import 'package:litertlm_dart/src/runtime/load_errors.dart'
    show LibraryLoadFailure;
import 'package:test/test.dart';

void main() {
  test('dart test is a plain Dart program: no dart:ui', () {
    expect(liteRtLmOutsideFlutter, isTrue);
  });

  group('directoryOfModule', () {
    test('POSIX: everything before the last slash', () {
      expect(
        directoryOfModule(
          '/private/var/folders/x/T/dart_native_assets_ab12CD/lib/'
          'libStreamProxy.dylib',
          windows: false,
        ),
        '/private/var/folders/x/T/dart_native_assets_ab12CD/lib',
      );
      expect(
        directoryOfModule(
          '/opt/app/bundle/lib/libStreamProxy.so',
          windows: false,
        ),
        '/opt/app/bundle/lib',
      );
      expect(directoryOfModule('/libStreamProxy.so', windows: false), '/');
      expect(directoryOfModule('libStreamProxy.so', windows: false), isNull);
      // A backslash is a file name character on POSIX.
      expect(directoryOfModule(r'/a\b/c.so', windows: false), r'/a\b');
    });

    test('Windows: either separator; a drive root keeps its backslash', () {
      expect(
        directoryOfModule(
          r'C:\Users\Zoë\AppData\Local\Temp\dart_native_assets_x\lib\StreamProxy.dll',
          windows: true,
        ),
        r'C:\Users\Zoë\AppData\Local\Temp\dart_native_assets_x\lib',
      );
      expect(
        directoryOfModule(r'C:/bundle/lib/StreamProxy.dll', windows: true),
        'C:/bundle/lib',
      );
      expect(
        directoryOfModule(r'\\?\C:\bundle\lib\StreamProxy.dll', windows: true),
        r'\\?\C:\bundle\lib',
      );
      expect(directoryOfModule(r'C:\StreamProxy.dll', windows: true), r'C:\');
      expect(directoryOfModule('StreamProxy.dll', windows: true), isNull);
    });
  });

  test('pathInAssetDir joins with the platform separator once', () {
    expect(
      pathInAssetDir('/t/lib', 'libLiteRt.so', windows: false),
      '/t/lib/libLiteRt.so',
    );
    expect(
      pathInAssetDir('/', 'libLiteRt.so', windows: false),
      '/libLiteRt.so',
    );
    expect(
      pathInAssetDir(r'C:\b\lib', 'LiteRt.dll', windows: true),
      r'C:\b\lib\LiteRt.dll',
    );
    expect(
      pathInAssetDir(r'C:\', 'LiteRt.dll', windows: true),
      r'C:\LiteRt.dll',
    );
  });

  test('an AOT build keeps a call of the anchor: an entry point calls it', () {
    // Without a reachable @Native call, a Windows `dart build cli` dropped the
    // anchor's symbol and asset id (Dart 3.13.3 and 3.14.1, measured on an
    // Intel PC), and the lookup found no code assets. The keeper is never
    // run; only the tree shaker has to see it.
    final source = File(
      'lib/src/ffi/native_asset_dir.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      source,
      contains(
        "@pragma('vm:entry-point')\n"
        'Pointer<Void> keepStreamProxyAnchorCall() => '
        '_streamProxyAnchor(nullptr);',
      ),
    );
    expect(keepStreamProxyAnchorCall, isA<Function>());
  });

  test('the anchor is a StreamProxy export on every platform', () {
    final source = File('native/litert_lm/stream_proxy.c').readAsStringSync();
    // Both arms (Windows and POSIX) export it.
    expect(
      RegExp(
        'STREAM_PROXY_EXPORT\\s+void\\* $streamProxyAnchorSymbol\\(',
      ).allMatches(source).length,
      2,
    );
    expect(streamProxyAssetId, 'package:litertlm_dart/src/native/StreamProxy');
    final hook = File('hook/build.dart').readAsStringSync();
    expect(hook, contains("name: 'src/native/StreamProxy'"));
  });

  group('checkedAssetDir', () {
    test('a directory holding libLiteRtLm under its asset name is ours', () {
      final there = {
        pathInAssetDir('/t/lib', 'libLiteRtLm.so', windows: Platform.isWindows),
      };
      expect(
        checkedAssetDir(
          '/t/lib',
          mainLibraryFile: 'libLiteRtLm.so',
          exists: there.contains,
        ),
        '/t/lib',
      );
      expect(
        checkedAssetDir(
          '/t/lib',
          mainLibraryFile: 'LiteRtLm.dll',
          exists: there.contains,
        ),
        isNull,
        reason: 'another file name is not our library',
      );
    });

    test('a stray StreamProxy found by a process lookup is not ours', () {
      // The VM's fallback when no asset has the anchor's id: e.g. the
      // directory of an executable that loaded some StreamProxy by name.
      expect(
        checkedAssetDir(
          '/usr/local/bin',
          mainLibraryFile: 'libLiteRtLm.so',
          exists: (_) => false,
        ),
        isNull,
      );
      expect(
        checkedAssetDir(
          null,
          mainLibraryFile: 'libLiteRtLm.so',
          exists: (_) => true,
        ),
        isNull,
      );
    });
  });

  test('without code assets the failure names dart build cli and that dart '
      'compile exe runs no hooks', () {
    expect(
      () => requireAssetDir(null),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          plainDartNoAssetsMessage,
        ),
      ),
    );
    expect(requireAssetDir('/t/lib'), '/t/lib');
    expect(plainDartNoAssetsMessage, contains('dart build cli'));
    expect(
      plainDartNoAssetsMessage,
      contains('dart compile exe runs no build'),
    );
  });

  final hostHasArchive =
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;
  final dartAssetDir = RegExp(
    r'[/\\](dart_native_assets_[^/\\]+[/\\]lib|\.dart_tool[/\\]lib)$',
  );

  test(
    'resolves the directory the Dart SDK copied the code assets into',
    () {
      final dir = nativeAssetDir;
      expect(dir, matches(dartAssetDir));
      expect(requireNativeAssetDir(), dir);
      final proxy = Platform.isWindows
          ? 'StreamProxy.dll'
          : Platform.isMacOS
          ? 'libStreamProxy.dylib'
          : 'libStreamProxy.so';
      expect(
        File(nativeAssetPath(dir!, proxy)).existsSync(),
        isTrue,
        reason: dir,
      );
      expect(liteRtLmAssetFile, isNot(isEmpty));
      expect(
        File(nativeAssetPath(dir, liteRtLmAssetFile)).existsSync(),
        isTrue,
      );
    },
    skip: hostHasArchive
        ? false
        : 'the hook bundles LiteRT-LM for macOS, Linux and Windows hosts',
  );

  // The plain-Dart load path end to end, without a model: this package's own
  // test run sets no macos_companions define, so on macOS it must fail naming
  // it; on Linux and Windows the libraries load, and only the model is
  // missing.
  test(
    'openLiteRtLmLibrary opens the code asset (macOS: names the define)',
    () {
      if (Platform.isMacOS) {
        expect(
          openLiteRtLmLibrary,
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              contains('macos_companions: code_assets'),
            ),
          ),
        );
      } else {
        expect(openLiteRtLmLibrary(), isA<DynamicLibrary>());
      }
    },
    skip: hostHasArchive ? false : 'no native archive for this host',
  );

  test('a client loads the libraries, and only the model is missing', () async {
    Object? thrown;
    try {
      await LiteRtLmFfiClient().initialize(modelPath: '/no/such/model');
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    if (Platform.isMacOS) {
      expect(thrown, isA<LibraryLoadFailure>());
      expect('$thrown', contains('macos_companions: code_assets'));
    } else {
      expect(thrown, isNot(isA<LibraryLoadFailure>()), reason: '$thrown');
    }
  }, skip: hostHasArchive ? false : 'no native archive for this host');
}
