// The web has no file system for this package; its API refuses earlier.
String absolutePath(String path) => path;

void ensureDirectory(String path) =>
    throw UnsupportedError('flutter_edge_ai_any: no file system on the web');

bool fileExists(String path) => false;
