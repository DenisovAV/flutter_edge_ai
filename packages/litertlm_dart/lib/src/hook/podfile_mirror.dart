// The macOS companions mirrored into the flat cache directory the Podfile
// stager reads (`flutter_gemma/native/macos_arm64`), the one place the block
// apps pasted before this package existed looks. Used by hook/build.dart.

import 'dart:io';

/// Copies each of [companionFiles] from [prebuiltDir] into [legacyDir] when
/// it differs, and returns the copies.
///
/// An older hook (flutter_edge_ai_litertlm 1.20.x and before) does not watch
/// the companions, but it does watch its own libLiteRtLm here
/// ([legacyMainFile]): removing it makes that hook run again and fetch its
/// own release's files, companions included, before its app's stager reads
/// them. The flat cache's version marker is left alone: an older hook trusts
/// it for every platform directory it holds, and this mirror refreshes only
/// macOS, so writing this release's version there would let an older hook
/// bundle another platform's files from an older release as current.
List<Uri> mirrorForPodfileStager({
  required List<String> companionFiles,
  required String legacyMainFile,
  required Uri prebuiltDir,
  required Directory legacyDir,
}) {
  legacyDir.createSync(recursive: true);
  final copies = <Uri>[];
  for (final fileName in companionFiles) {
    final src = File.fromUri(prebuiltDir.resolve(fileName));
    if (!src.existsSync()) continue;
    final dst = File('${legacyDir.path}/$fileName');
    if (!dst.existsSync() || !_sameBytes(src, dst)) src.copySync(dst.path);
    copies.add(dst.uri);
  }
  final legacyMain = File('${legacyDir.path}/$legacyMainFile');
  if (legacyMain.existsSync()) legacyMain.deleteSync();
  return copies;
}

bool _sameBytes(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) return false;
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
