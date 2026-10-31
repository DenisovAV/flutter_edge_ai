// The macOS branch of the native load and the preload's error handling need a
// real app bundle to run, which no VM host has (the framework cannot be
// opened). This holds their source to what the tests of the helpers rely on:
// each macOS library's preloaded handle is checked against the opened one,
// and the preload swallows only the loader's own "no library" ArgumentError.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
