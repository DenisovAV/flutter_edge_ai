// The few file-system facts the provider needs, on dart:io.
import 'dart:io';

/// [path] made absolute, without `.`/`..` segments.
String absolutePath(String path) {
  final p = File(path).absolute.uri.normalizePath().toFilePath();
  return p.length > 1 && p.endsWith(Platform.pathSeparator)
      ? p.substring(0, p.length - 1)
      : p;
}

void ensureDirectory(String path) =>
    Directory(path).createSync(recursive: true);

bool fileExists(String path) => File(path).existsSync();
