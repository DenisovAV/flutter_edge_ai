// What the build hook says when it has no LiteRT-LM archive for its target.
//
// Kept apart from `hook/build.dart` (which has a `main` and cannot be imported
// by a test) so the wording and, above all, WHICH targets get it are tested.

/// The one target where a missing archive is the whole story: a Windows ARM64
/// process has no other slice to fall back on, and the app builds green and
/// then dies at `DynamicLibrary.open` (#326).
const _windowsArm64 = 'windows_arm64';

/// The notice for a target with no checksum-backed archive, or null when the
/// skip should stay silent.
///
/// Silent on purpose for every other target without an archive:
/// `android_x86_64` (`android-x64` is in the default target set of
/// `flutter build apk`/`appbundle`) and `macos_x86_64` (a macOS release build
/// is universal unless x86_64 is excluded) are slices of ordinary builds whose
/// arm64 half works. `hooks_runner` forwards a hook's stderr at SEVERE, so a
/// notice there would print a red error for every such app.
String? missingArchiveNotice({
  required String packageName,
  required String dirName,
  required String archiveName,
}) {
  if (dirName != _windowsArm64) return null;
  return '[$packageName] no LiteRT-LM native archive is published for '
      '$dirName ($archiveName), so `.litertlm` inference cannot run in a '
      'native Windows ARM64 process. The build continues for apps that use '
      'another engine. Upstream LiteRT-LM does not build for Windows ARM64, '
      'MediaPipe has no desktop engine, and the ONNX engine is Windows x64 '
      'only for now. Until that changes, build the app for x64, which runs '
      'under Windows x64 emulation. '
      'See https://github.com/DenisovAV/flutter_edge_ai/issues/326';
}
