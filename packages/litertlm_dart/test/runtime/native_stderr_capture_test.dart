// A plain Dart program keeps its stderr: loading the libraries moves native
// stderr to a log file only in a Flutter debug build (the adapter's test of
// the other side runs under `flutter test`).
import 'package:litertlm_dart/internal_io.dart';
import 'package:test/test.dart';

void main() {
  test('under dart test nothing is a Flutter debug build, so native stderr '
      'stays where it is', () {
    expect(isDebugBuild, isTrue, reason: 'dart test runs a debug VM');
    expect(isFlutterDebugBuild, isFalse);
    expect(capturesNativeStderr, isFalse);
  });
}
