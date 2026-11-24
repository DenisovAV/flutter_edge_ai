// litertlm_dart runs a plain Dart program (no dart:ui) on the CPU only and
// looks its libraries up among the program's code assets. In Flutter, which
// this package always runs in, neither applies: flutter test, like an app,
// has dart:ui, so the engine host reports no plain Dart program and every
// backend and library lookup is the app's.

import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart';

void main() {
  test('Flutter is not a plain Dart program to litertlm_dart', () {
    expect(const bool.fromEnvironment('dart.library.ui'), isTrue);
    expect(const EngineHost().outsideFlutter, isFalse);
  });
}
