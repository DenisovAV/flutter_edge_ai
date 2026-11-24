// litertlm_dart looks the libraries of a plain Dart program (no dart:ui) up
// among its code assets, the GPU accelerators and NPU dispatch included. In
// Flutter, which this package always runs in, that does not apply: flutter
// test, like an app, has dart:ui, so the engine host reports no plain Dart
// program and every library lookup is the app's.

import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart';

void main() {
  test('Flutter is not a plain Dart program to litertlm_dart', () {
    expect(const bool.fromEnvironment('dart.library.ui'), isTrue);
    expect(const EngineHost().outsideFlutter, isFalse);
  });
}
