// The macOS companion libraries reach an app from three places that the
// compiler never sees together (#689): the plugin's Package.swift (Swift
// Package Manager on), the Podfile stager (off), and the hook, which points
// LiteRtLm at the frameworks either one embeds. They must agree on the release,
// the names, the install name, the bundle id the stager recognises and the
// minimum macOS. A native bump that moves the hook but not Package.swift would
// pair a new LiteRtLm with the previous release's companions; it fails here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

final _packageSwift = _read('macos/flutter_edge_ai_litertlm/Package.swift');
final _podspec = _read('macos/flutter_edge_ai_litertlm.podspec');
final _hook = _read('hook/build.dart');
final _stager = _read('tool/stage_macos_companions.sh');
final _packager = _read('native/litert_lm/package_macos_spm_companions.sh');

/// `(name, checksum)` pairs of Package.swift's `companions`.
Map<String, String> _swiftCompanions() => {
  for (final m in RegExp(
    r'\("(\w+)", "([0-9a-f]*)"\)',
  ).allMatches(_packageSwift))
    m.group(1)!: m.group(2)!,
};

void main() {
  test('Package.swift fetches from the native release the hook uses', () {
    final hookVersion = RegExp(
      r"version: '([^']+)',\n  releaseTagPrefix: 'native-v',",
    ).firstMatch(_hook)?.group(1);
    expect(hookVersion, isNotNull, reason: "the hook's LiteRT-LM bundle");
    final tag = RegExp(
      r'^let nativeTag = "([^"]+)"$',
      multiLine: true,
    ).firstMatch(_packageSwift)?.group(1);
    expect(tag, 'native-v$hookVersion');
    expect(
      _packageSwift,
      contains(
        'https://github.com/DenisovAV/flutter_edge_ai/releases/download/'
        r'\(nativeTag)/\(name).xcframework.zip',
      ),
    );
  });

  test('every macOS companion the stager stages is a binary target, with a '
      'checksum', () {
    final stagerList = RegExp(
      r'^COMPANIONS="([^"]+)"$',
      multiLine: true,
    ).firstMatch(_stager)!.group(1)!.split(' ');
    final packagerList = RegExp(
      r'^COMPANIONS="([^"]+)"$',
      multiLine: true,
    ).firstMatch(_packager)!.group(1)!.split(' ');
    final swift = _swiftCompanions();
    // The stager also names the Metal sampler, which no macOS tarball has
    // carried since native-v0.18.0; the release ships the other two.
    expect(swift.keys.toSet(), packagerList.toSet());
    expect(stagerList.toSet().containsAll(swift.keys), isTrue);
    for (final name in swift.keys) {
      expect(_hook, contains("'$name'"), reason: "the hook's companions");
    }
    for (final MapEntry(:key, :value) in swift.entries) {
      expect(value, matches(RegExp(r'^[0-9a-f]{64}$')), reason: key);
    }
  });

  test('the hook, the stager and the packaging script use one install name '
      'and one bundle id', () {
    const installName = r'@rpath/$name.framework/Versions/A/$name';
    expect(_hook, contains(installName));
    expect(_stager, contains(r'@rpath/${base}.framework/Versions/A/${base}'));
    expect(_packager, contains(r'@rpath/${base}.framework/Versions/A/${base}'));
    // The stager leaves a framework alone when it carries this bundle id, so
    // it does not replace the copy Xcode signed with an ad-hoc one.
    expect(_packager, contains(r'dev.flutteredge.litertlm.${base}'));
    expect(_stager, contains(r'dev.flutteredge.litertlm.${base}'));
  });

  test('the packaging script gives the same zip in any timezone and a '
      'numeric CFBundleVersion', () {
    // `touch -t` and zip read the local zone: zips built in CET and in UTC
    // had different checksums.
    expect(_packager, contains('export TZ=UTC'));
    // App Store validation wants one to three integers there; the tag itself
    // goes into its own key.
    expect(
      _packager,
      contains(r'<key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>'),
    );
    expect(
      _packager,
      contains(
        r'<key>DevFlutteredgeNativeTag</key><string>native-v${NATIVE_VERSION}</string>',
      ),
    );
  });

  test('Package.swift and the podspec declare the same minimum macOS', () {
    final swift = RegExp(
      r'\.macOS\("([\d.]+)"\)',
    ).firstMatch(_packageSwift)?.group(1);
    final pod = RegExp(r":osx, '([\d.]+)'").firstMatch(_podspec)?.group(1);
    expect(swift, isNotNull);
    expect(pod, swift);
  });
}
