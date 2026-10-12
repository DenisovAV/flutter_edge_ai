/// The web side of `local_file_io.dart`: a model there is a URL, never a file
/// the app owns on disk, so there is nothing to compare, move or stamp.
library;

/// Whether two paths are one file: on web, two URLs are one model only when
/// they are the same string.
enum FileIdentity { same, different, unknown }

/// Two URLs are the same model only when they are the same string.
Future<FileIdentity> compareFiles(String a, String b) async =>
    a == b ? FileIdentity.same : FileIdentity.different;

/// A URL does not move.
Future<String> appFileLocationNow(String recordedPath) async => recordedPath;

/// There are no bundled resources to copy.
bool get bundledResourcesAreCopies => false;

/// There is no file to stamp.
Future<({int size, int modifiedMs})?> fileStamp(String filePath) async => null;
