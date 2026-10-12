/// The web side of `local_file_io.dart`: a model there is a URL, never a file
/// the app owns on disk, so there is nothing to compare, move or stamp.
library;

/// Two URLs are the same model only when they are the same string.
Future<bool> isSameFile(String a, String b) async => a == b;

/// A URL does not move.
Future<String> appFileLocationNow(String recordedPath) async => recordedPath;

/// There are no bundled resources to copy.
bool get bundledResourcesAreCopies => false;

/// There is no file to stamp.
Future<({int size, int modifiedMs})?> fileStamp(String filePath) async => null;
