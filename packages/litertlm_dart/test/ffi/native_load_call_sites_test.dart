// The macOS branch of the native load and the preload's error handling need a
// real app bundle to run, which no VM host has (the framework cannot be
// opened). This holds their source to what the tests of the helpers rely on:
// each macOS library's preloaded handle is checked against the opened one,
// and the preload swallows only the loader's own "no library" ArgumentError.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
import 'package:test/test.dart';

int _count(String source, String pattern) =>
    RegExp(pattern).allMatches(source).length;

int _at(String source, String pattern) =>
    RegExp(pattern).firstMatch(source)?.start ?? -1;

/// [source] from its one match of [start] to the first match of [end] after
/// it; fails, naming the anchor, otherwise.
String _slice(String source, String start, String end) {
  expect(_count(source, start), 1, reason: 'anchor $start');
  final rest = source.substring(_at(source, start));
  final to = _at(rest, end);
  expect(to, isPositive, reason: 'anchor $end');
  return rest.substring(0, to);
}

/// [source] without `//` comments, so a commented-out line never satisfies a
/// check (a `//` after `:`, as in a URL, is kept).
String _withoutComments(String source) => source.replaceAllMapped(
  RegExp(r'(^|[ \t])//.*$', multiLine: true),
  (m) => m[1]!,
);

void main() {
  final client = _withoutComments(
    File(
      'lib/src/ffi/litert_lm_client.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n'),
  );

  test('macOS checks each preloaded library against the opened one', () {
    final macOS = _slice(
      client,
      r'\} else if \(Platform\.isMacOS\) \{',
      r'\} else if \(Platform\.isLinux\) \{',
    );
    // LiteRtLm: preload, open, then the check on the two.
    final preloadLib = _at(
      macOS,
      r'final preloadedLib = preload\(macOSLiteRtLmFramework\);',
    );
    final openLib = _at(macOS, r'openMacOSLiteRtLm\(\)');
    final checkLib = _at(
      macOS,
      r'requireSameLoadedLibrary\(\s*preloadedLib,\s*lib,\s*'
      r'macOSLiteRtLmFramework,?\s*\);',
    );
    // StreamProxy: the same.
    final preloadProxy = _at(
      macOS,
      r'final preloadedProxy = preload\(proxyPath\);',
    );
    final openProxy = _at(
      macOS,
      r'proxyLib = DynamicLibrary\.open\(proxyPath\);',
    );
    final checkProxy = _at(
      macOS,
      r'requireSameLoadedLibrary\(\s*preloadedProxy,\s*proxyLib,\s*'
      r'proxyPath,?\s*\);',
    );
    final order = {
      'preload LiteRtLm': preloadLib,
      'open LiteRtLm': openLib,
      'check LiteRtLm': checkLib,
      'preload StreamProxy': preloadProxy,
      'open StreamProxy': openProxy,
      'check StreamProxy': checkProxy,
    };
    for (final MapEntry(:key, :value) in order.entries) {
      expect(value, isNonNegative, reason: '$key in $macOS');
    }
    final at = order.values.toList();
    for (var i = 1; i < at.length; i++) {
      expect(at[i - 1], lessThan(at[i]), reason: '$order');
    }
  });

  test(
    'macOS refuses before anything loads: an app built with the '
    'plain-Dart define, and a plain Dart program without its code assets',
    () {
      final app = _slice(
        client,
        r'\} else if \(Platform\.isMacOS\) \{',
        r'\} else if \(Platform\.isLinux\) \{',
      );
      final misuse = _at(
        app,
        r'final misuse = macOSFlutterCodeAssetsMisuse\(\);\s*'
        r'if \(misuse != null\) throw ArgumentError\(misuse\);',
      );
      expect(misuse, isNonNegative, reason: app);
      expect(misuse, lessThan(_at(app, r'preload\(')), reason: app);

      final plainDart = _slice(
        client,
        r'\} else if \(Platform\.isMacOS && liteRtLmOutsideFlutter\) \{',
        r'\} else if \(Platform\.isMacOS\) \{',
      );
      final refusal = _at(
        plainDart,
        r'throw ArgumentError\(macOSCodeAssetsRefusal\(assets\)\)',
      );
      expect(refusal, isNonNegative, reason: plainDart);
      expect(
        refusal,
        lessThan(_at(plainDart, r'preload\(')),
        reason: plainDart,
      );
    },
  );

  test('Linux loads the GPU accelerator with RTLD_GLOBAL in a plain Dart '
      'program too: one list, no library skipped', () {
    final linux = _slice(
      client,
      r'\} else if \(Platform\.isLinux\) \{',
      r'\} else if \(Platform\.isWindows\) \{',
    );
    expect(_count(linux, r'for \(final name in linuxGlobalLibraries\)'), 1);
    expect(linux, isNot(contains('continue')));
    expect(linuxGlobalLibraries.first, 'libLiteRt.so');
    expect(linuxGlobalLibraries.last, 'libLiteRtLm.so');
    expect(
      linuxGlobalLibraries.indexOf('libLiteRtWebGpuAccelerator.so'),
      inInclusiveRange(1, linuxGlobalLibraries.length - 2),
    );
  });

  test('Windows: a plain Dart program loads the GPU libraries before the '
      'preloads, and skips none of them', () {
    final windows = _slice(
      client,
      r'\} else if \(Platform\.isWindows\) \{',
      r'\} else if \(Platform\.isAndroid\) \{',
    );
    final gpu = _at(
      windows,
      r'if \(assetDir != null\) preloadWindowsGpuAssets\(assetDir\);',
    );
    expect(gpu, isNonNegative, reason: windows);
    expect(
      gpu,
      lessThan(_at(windows, r'for \(final name in windowsPreloadLibraries\)')),
    );
    expect(windows, isNot(contains("name == 'libLiteRtWebGpuAccelerator")));
    // The other two openers of a plain Dart program's libraries on Windows.
    for (final (file, open) in [
      (
        'litert_lm_library.dart',
        r"nativeAssetPath\(assetDir, 'LiteRtLm\.dll'\)",
      ),
      ('litert_bindings.dart', r"nativeAssetPath\(assetDir, 'LiteRt\.dll'\)"),
    ]) {
      final source = _withoutComments(
        File('lib/src/ffi/$file').readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final at = _at(source, r'preloadWindowsGpuAssets\(assetDir\);');
      expect(at, isNonNegative, reason: file);
      expect(at, lessThan(_at(source, open)), reason: file);
    }
  });

  test('the preload swallows only the loader\'s ArgumentError', () {
    final preload = _slice(
      client,
      r'Pointer<Void>\? _preloadWithSystemLoader\(String path\) \{',
      r'\n\}\n',
    );
    expect(_count(preload, r'\bcatch\b'), 1);
    expect(_count(preload, r'on ArgumentError catch \(e\)'), 1);
    expect(preload, isNot(contains('on Object')));
    expect(preload, isNot(contains('on Exception')));
  });

  test('the default preload returns null for a library the loader cannot '
      'find', () {
    if (Platform.isWindows) return;
    expect(preloadNativeLibrary('/no/such/dir/libLiteRtLm.so'), isNull);
  });
}
