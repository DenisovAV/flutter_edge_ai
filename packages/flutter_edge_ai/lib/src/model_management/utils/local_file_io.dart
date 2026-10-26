/// Files on disk, for the install rule and the restores: whether two paths
/// are one file, where an app's file is in this run, and a file's stamp.
/// The web build gets `local_file_web.dart` instead, which has no files.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/src/model_management/utils/app_container_path.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Whether two paths are one file on disk: [compareFiles]' answer.
enum FileIdentity {
  /// One file, however each path spells it.
  same,

  /// Two files, or one of the paths names nothing.
  different,

  /// Both are there, but which they are could not be found out.
  unknown,
}

/// Whether [a] and [b] are one file on disk, however each is spelled: a
/// symbolic link to it, a directory link on the way (iOS `/var` and
/// `/private/var`), a bind mount (Android `/data/user/0` and `/data/data`), a
/// hard link, or another case on a case-insensitive volume. A path that names
/// nothing is a different file from any other, even one spelled the same.
///
/// [FileIdentity.unknown] when both are there and the file system would not
/// say; each caller then takes the answer that never loses a file.
Future<FileIdentity> compareFiles(String a, String b) async {
  try {
    if (!await File(a).exists() || !await File(b).exists()) {
      return FileIdentity.different;
    }
    if (path.equals(a, b)) return FileIdentity.same;
    final resolvedA = await File(a).resolveSymbolicLinks();
    final resolvedB = await File(b).resolveSymbolicLinks();
    if (path.equals(resolvedA, resolvedB) ||
        await FileSystemEntity.identical(resolvedA, resolvedB)) {
      return FileIdentity.same;
    }
    return FileIdentity.different;
  } on FileSystemException catch (e) {
    edgeAiLog('[LocalFile] cannot tell whether $a is $b: $e');
    return FileIdentity.unknown;
  }
}

/// Where a file the app recorded with `fromFile` is in this run: on iOS a
/// path inside the app's container is moved into the current container,
/// which an update or a restore from a backup can relocate.
Future<String> appFileLocationNow(String recordedPath) async {
  if (!(debugAppContainerCanMove ?? Platform.isIOS)) return recordedPath;
  final container = path.dirname(
    (await getApplicationDocumentsDirectory()).path,
  );
  final now = rebaseIntoAppContainer(recordedPath, container);
  // `/private/var/…` from a file picker is this container, not a move.
  if (now != recordedPath && !recordedPath.contains(path.basename(container))) {
    edgeAiLog(
      '[LocalFile] $recordedPath was recorded in an earlier app container; '
      'using $now',
    );
  }
  return now;
}

/// Stands in for "this run is on iOS" in [appFileLocationNow], so a test on
/// a desktop host can move the app's container. Null outside tests.
@visibleForTesting
bool? debugAppContainerCanMove;

/// Whether a bundled resource is copied into core's model directory (Android
/// copies it out of the APK) rather than read in place (the iOS bundle).
bool get bundledResourcesAreCopies =>
    debugBundledResourcesAreCopies ?? Platform.isAndroid;

/// Stands in for "this run is on Android" in [bundledResourcesAreCopies], so a
/// test on a desktop host can take the Android path. Null outside tests.
@visibleForTesting
bool? debugBundledResourcesAreCopies;

/// The size and modification time of the file at [filePath], or null when
/// nothing is there — enough to tell that a file was not replaced since.
Future<({int size, int modifiedMs})?> fileStamp(String filePath) async {
  final stat = await File(filePath).stat();
  if (stat.type != FileSystemEntityType.file) return null;
  return (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch);
}
