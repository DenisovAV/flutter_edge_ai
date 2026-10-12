/// Files on disk, for the install rule and the restores: whether two paths
/// are one file, where an app's file is in this run, and a file's stamp.
/// The web build gets `local_file_web.dart` instead, which has no files.
library;

import 'dart:io';

import 'package:flutter_edge_ai/core/model_management/utils/app_container_path.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Whether [a] and [b] are one file on disk, however each is spelled: the
/// same string, a symbolic link to it, a directory link on the way (iOS
/// `/var` and `/private/var`), a bind mount (Android `/data/user/0` and
/// `/data/data`), a hard link, or another case on a case-insensitive volume.
///
/// False only when they are known to differ — one of them is not there, or
/// both are and are different files. When it cannot be told, it answers true:
/// every caller keeps a file it might otherwise delete or overwrite.
Future<bool> isSameFile(String a, String b) async {
  if (path.equals(a, b)) return true;
  try {
    if (!await File(a).exists() || !await File(b).exists()) return false;
    final resolvedA = await File(a).resolveSymbolicLinks();
    final resolvedB = await File(b).resolveSymbolicLinks();
    if (path.equals(resolvedA, resolvedB)) return true;
    return await FileSystemEntity.identical(resolvedA, resolvedB);
  } on FileSystemException catch (e) {
    edgeAiLog('[LocalFile] cannot tell whether $a is $b ($e); taking it so');
    return true;
  }
}

/// Where a file the app recorded with `fromFile` is in this run: on iOS a
/// path inside the app's container is moved into the current container,
/// which an update or a restore from a backup can relocate.
Future<String> appFileLocationNow(String recordedPath) async {
  if (!Platform.isIOS) return recordedPath;
  final container = path.dirname(
    (await getApplicationDocumentsDirectory()).path,
  );
  final now = rebaseIntoAppContainer(recordedPath, container);
  // `/private/var/…` from a file picker is this container, not a move.
  if (now != recordedPath && !recordedPath.contains(path.basename(container))) {
    edgeAiLog(
      '[ModelManager] $recordedPath was recorded in an earlier app '
      'container; using $now',
    );
  }
  return now;
}

/// Whether a bundled resource is copied into core's model directory (Android
/// copies it out of the APK) rather than read in place (the iOS bundle).
bool get bundledResourcesAreCopies => Platform.isAndroid;

/// The size and modification time of the file at [filePath], or null when
/// nothing is there — enough to tell that a file was not replaced since.
Future<({int size, int modifiedMs})?> fileStamp(String filePath) async {
  final stat = await File(filePath).stat();
  if (stat.type != FileSystemEntityType.file) return null;
  return (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch);
}
