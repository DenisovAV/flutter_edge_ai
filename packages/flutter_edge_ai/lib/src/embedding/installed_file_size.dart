// The size of an installed model file, for the embedding-space id a decider
// pins its artifact to. Native: the file's size on disk. The web arm is
// `installed_file_size_web.dart`.

import 'dart:io';

/// The size in bytes of the regular file at [path], or null when there is no
/// regular file there (a directory, a missing path).
Future<int?> installedFileSize(String path) async {
  final stat = await FileStat.stat(path);
  return stat.type == FileSystemEntityType.file ? stat.size : null;
}
