// The plugin's macOS Swift package and its podspec. Up to litertlm_dart
// 0.19.1+4 this file also held Package.swift's companion binary targets to the
// hook, the Podfile stager and the SwiftPM packaging script (#689). From
// litertlm_dart 0.20.0 (native-v0.20.0) LiteRtLm links no companion library
// on macOS, the stager and the packaging script are gone, and Package.swift's
// binary targets are left to this package's next release to remove.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

final _packageSwift = _read('macos/flutter_edge_ai_litertlm/Package.swift');
final _podspec = _read('macos/flutter_edge_ai_litertlm.podspec');

void main() {
  test('Package.swift and the podspec declare the same minimum macOS', () {
    final swift = RegExp(
      r'\.macOS\("([\d.]+)"\)',
    ).firstMatch(_packageSwift)?.group(1);
    final pod = RegExp(r":osx, '([\d.]+)'").firstMatch(_podspec)?.group(1);
    expect(swift, isNotNull);
    expect(pod, swift);
  });
}
