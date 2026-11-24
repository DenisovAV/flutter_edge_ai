// litertlm_dart looks the libraries of a plain Dart program (no dart:ui) up
// among its code assets, the GPU accelerators and NPU dispatch included. In
// Flutter, which this package always runs in, that does not apply: flutter
// test, like an app, has dart:ui, so litertlm_dart sees no plain Dart program
// and looks the NPU stack up beside the app's executable.

import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart';
// ignore: implementation_imports — the constant every plain-Dart path is gated on, and the directory rule behind it.
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart'
    show liteRtLmOutsideFlutter;
// ignore: implementation_imports — the NPU directory rule under test.
import 'package:litertlm_dart/src/ffi/npu_vendor_host.dart'
    show nativeLibraryDirOf;

final class _App implements NpuPlatform {
  @override
  Future<String> readNativeAssetsManifest() => Future.error('no manifest');

  @override
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  ) async => null;

  @override
  String get executableDir => '/app';
}

void main() {
  test('Flutter is not a plain Dart program to litertlm_dart: the NPU stack '
      'is looked up beside the app, not among code assets', () {
    expect(const bool.fromEnvironment('dart.library.ui'), isTrue);
    expect(liteRtLmOutsideFlutter, isFalse);
    expect(nativeLibraryDirOf('linux', _App()), '/app/lib');
    expect(nativeLibraryDirOf('windows', _App()), '/app');
  });
}
