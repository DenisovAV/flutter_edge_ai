// The other side of litertlm_dart's test: in a Flutter debug build (here
// `flutter test`) native stderr is captured on iOS, macOS and Linux, as it was
// before the runtime left this package.
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

void main() {
  test('a Flutter debug build captures native stderr where it did', () {
    expect(isFlutterDebugBuild, kDebugMode);
    expect(
      capturesNativeStderr,
      Platform.isIOS || Platform.isMacOS || Platform.isLinux,
    );
  });
}
