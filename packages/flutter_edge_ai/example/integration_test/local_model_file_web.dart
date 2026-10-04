/// Web arm of the local-model lookup: there is no filesystem to push a model
/// onto, so every web run installs from the network — cached afterwards by
/// `WebStorageMode.cacheApi`, so only the first one pays for the download.
library;

/// Always null on web. [fileName] is accepted so the two arms share a
/// signature.
String? localModelFile(String fileName) => null;
