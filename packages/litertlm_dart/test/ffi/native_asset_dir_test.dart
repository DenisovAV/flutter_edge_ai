// Where a plain Dart program's code assets are: the directory of the file
// that holds a StreamProxy symbol resolved through its asset id. `dart test`
// runs this package's build hook, so this suite is itself such a program.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
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

  test(
    'resolves the directory the SDK put the code assets in',
    () {
      final dir = nativeAssetDir;
      expect(dir, isNotNull);
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
      expect(
        File(
          nativeAssetPath(
            dir,
            Platform.isWindows
                ? 'LiteRtLm.dll'
                : Platform.isMacOS
                ? 'libLiteRtLm.dylib'
                : 'libLiteRtLm.so',
          ),
        ).existsSync(),
        isTrue,
        reason: dir,
      );
    },
    skip: Platform.isMacOS || Platform.isLinux || Platform.isWindows
        ? false
        : 'the hook bundles LiteRT-LM for macOS, Linux and Windows hosts',
  );
}
