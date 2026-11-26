// The no-op that replaces the macOS companion stager (litertlm_dart 0.20.0).
//
// Up to 0.19.1+4 the hook put `stage_macos_companions.sh` in
// `~/Library/Caches/flutter_gemma/native/macos_arm64/`, and the Podfile block
// apps pasted ("[flutter_gemma] Setup LiteRT-LM macOS") runs it from there,
// failing the build when the file is missing. From native-v0.20.0 there is
// no macOS companion to stage, and an old stager left on a machine would copy
// an older release's companions into the app and rewrite its LiteRtLm. So the
// hook writes this stub at that path: it accepts the same arguments, says the
// block can go, and exits 0. It replaces only a stager of ours (any release's)
// or an earlier stub, never another file, and fails the build when a stager
// of ours is there and cannot be replaced.

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

/// What [writeMacOSStagerStub] found and did.
enum MacOSStagerStubOutcome {
  /// The file now holds the stub: it was absent, a stager of ours or an
  /// earlier stub.
  written,

  /// The file already held this stub.
  current,

  /// The file is not ours, and was left alone.
  notOurs,

  /// The file is there but could not be read, so whose it is is unknown; it
  /// was left alone.
  unreadable,
}

/// Writes the stub for [version] as [file] when it is absent, ours and
/// different. The stub is written beside it and renamed over it, so the
/// Podfile block never runs a half-written file.
///
/// A file that is not ours, or cannot be read, is left alone. A stager of
/// an earlier release that cannot be replaced is a [StateError] naming the
/// path: left there, the block would stage that release's companions into
/// the app. An absent file, or an earlier stub, that cannot be written is
/// the [FileSystemException] of the write (the stub only serves apps that
/// still carry the block, and an earlier stub does nothing either).
MacOSStagerStubOutcome writeMacOSStagerStub(File file, String version) {
  final stub = macOSStagerStub(version);
  // A stager of an earlier release, not a stub: only it would stage old
  // companions if left there.
  var stager = false;
  if (file.existsSync()) {
    final String current;
    try {
      current = file.readAsStringSync();
    } on FileSystemException {
      return MacOSStagerStubOutcome.unreadable;
    } on FormatException {
      // Not text: no stager of ours.
      return MacOSStagerStubOutcome.notOurs;
    }
    if (current == stub) return MacOSStagerStubOutcome.current;
    if (!isOurMacOSStager(current)) return MacOSStagerStubOutcome.notOurs;
    stager = !current.contains(macOSStagerStubMarker);
  }
  final temp = File('${file.path}.$pid.tmp');
  try {
    file.parent.createSync(recursive: true);
    temp.writeAsStringSync(stub, flush: true);
    // The block runs it with `sh`, but a stager was executable too.
    Process.runSync('chmod', ['755', temp.path]);
    temp.renameSync(file.path);
  } on FileSystemException catch (e) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Nothing more to do: the rename's failure is what is reported.
    }
    if (!stager) rethrow;
    throw StateError(
      '${file.path} is the macOS companion stager of an earlier '
      'litertlm_dart, and it could not be replaced (${e.message}'
      '${e.osError == null ? '' : ': ${e.osError!.message}'}). Left there, '
      "the Podfile's '[flutter_gemma] Setup LiteRT-LM macOS' block would copy "
      "that release's companions into the app. Delete the file, or remove "
      'the block from your Podfile.',
    );
  }
  return MacOSStagerStubOutcome.written;
}
