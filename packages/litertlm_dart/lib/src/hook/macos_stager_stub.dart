// The no-op that replaces the macOS companion stager (litertlm_dart 0.20.0).
//
// Up to 0.19.1+4 the hook put `stage_macos_companions.sh` in
// `~/Library/Caches/flutter_gemma/native/macos_arm64/`, and the Podfile block
// apps pasted ("[flutter_gemma] Setup LiteRT-LM macOS") runs it from there,
// failing the build when the file is missing. From native-v0.20.0-a there is
// no macOS companion to stage, and an old stager left on a machine would copy
// an older release's companions into the app and rewrite its LiteRtLm. So the
// hook writes this stub at that path: it accepts the same arguments, says the
// block can go, and exits 0. It replaces only a stager of ours (any release's)
// or an earlier stub, never another file.

import 'dart:io';

/// The stub's file name, the one the pasted Podfile block runs.
const macOSStagerFileName = 'stage_macos_companions.sh';

/// The line that marks a file as this stub.
const macOSStagerStubMarker = '# litertlm_dart: no-op macOS companion stager';

/// The stub for litertlm_dart [version].
String macOSStagerStub(String version) =>
    '''#!/bin/sh
$macOSStagerStubMarker
# Written by litertlm_dart's build hook in place of the macOS companion stager
# of litertlm_dart 0.19.1+4 and earlier. LiteRT-LM needs no companion library
# on macOS any more; this accepts the old arguments and does nothing.
echo "litertlm_dart $version: macOS no longer needs this build phase; you can remove the '[flutter_gemma] Setup LiteRT-LM macOS' block from your Podfile"
exit 0
''';

/// Whether [content] is a file the hook may replace: a stager of any earlier
/// release (each names the Gemma constraint provider in its COMPANIONS list)
/// or a stub.
bool isOurMacOSStager(String content) =>
    content.contains(macOSStagerStubMarker) ||
    content.contains('COMPANIONS="GemmaModelConstraintProvider');

/// Writes the stub for [version] as [file] when it is absent, ours and
/// different, and returns whether [file] now holds it. A file that is not
/// ours is left alone (false).
bool writeMacOSStagerStub(File file, String version) {
  final stub = macOSStagerStub(version);
  if (file.existsSync()) {
    final String current;
    try {
      current = file.readAsStringSync();
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
    if (current == stub) return true;
    if (!isOurMacOSStager(current)) return false;
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(stub);
  // The block runs it with `sh`, but a stager was executable too.
  Process.runSync('chmod', ['755', file.path]);
  return true;
}
