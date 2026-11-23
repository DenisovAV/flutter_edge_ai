// What the NPU code asks of the app's platform layer: the one interface
// `Backend.npu` carries. No dart:ffi, no dart:io: the backend type is shared by
// the native and the web arm (the web has no NPU and refuses it).

import 'npu_stacks.dart';

/// What the NPU code needs from the app's platform layer that plain Dart
/// cannot answer: the build's NativeAssetsManifest.json, and on Android a
/// dispatch directory the app's native side prepares. The Flutter one is
/// `FlutterNpuPlatform` (flutter_npu_platform.dart), which reads the manifest
/// through `rootBundle` and asks core's `flutter_gemma_bundled` channel.
abstract interface class NpuPlatform {
  /// The text of the build's `NativeAssetsManifest.json`. Throws when it
  /// cannot be read; `checkNpuStackInManifest` turns that into
  /// `NpuStackCheck.unknown`.
  Future<String> readNativeAssetsManifest();

  /// A directory on Android holding exactly [libFileNames] (`lib<name>.so`)
  /// for LiteRT to load [vendor]'s dispatch from, or null when the native side
  /// returned none. Throws `NpuDispatchUnavailableException` when the stack
  /// cannot be prepared.
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  );

  /// The directory of the running executable: where Native Assets puts a
  /// Linux app's `lib/` and a Windows app's DLLs (`executableDirOf`).
  String get executableDir;
}
