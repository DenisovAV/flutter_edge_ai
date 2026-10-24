import 'package:flutter/foundation.dart';

/// Why Tiny Island does not run here, in one line for the home card; null
/// where it runs.
///
/// Windows and Linux: flutter_scene draws through Flutter GPU, which this
/// example's runners do not enable, and a release build there cannot turn it
/// on with a flag (`--enable-flutter-gpu` is for debug and profile runs).
String? tinyIslandUnsupportedReason() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux =>
      'Not on Windows or Linux yet: the 3D scene needs Flutter GPU, which '
          "this example's ${defaultTargetPlatform == TargetPlatform.windows ? 'Windows' : 'Linux'} "
          'runner does not enable.',
    _ => null,
  };
}

/// What to check when the 3D scene did not load or stopped drawing, for
/// this platform — the cause differs: WebGL2 in a browser, Impeller on
/// Android, the Info.plist flag on Apple platforms.
String tinyIslandSceneHint() {
  if (kIsWeb) {
    return 'flutter_scene draws through WebGL2 in a browser; this one may '
        'not offer it (or lost its GPU context).';
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android =>
      'flutter_scene draws through Flutter GPU, which needs Impeller '
          '(Vulkan or OpenGL ES 3). Devices where Flutter runs on Skia — '
          'Android 8 and 9, some older GPUs such as Vivante — cannot draw it.',
    TargetPlatform.iOS || TargetPlatform.macOS =>
      'flutter_scene draws through Flutter GPU on Metal, turned on by '
          'FLTEnableFlutterGPU in Info.plist.',
    _ => 'flutter_scene draws through Flutter GPU.',
  };
}
