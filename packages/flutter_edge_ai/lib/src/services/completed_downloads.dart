/// Downloads that finished while the app was not running (#873).
///
/// A background download can finish while the app is dead. The file is then at
/// its target path, but core never recorded the model as installed: that
/// happens in Dart once the download returns. Without this the next install
/// downloads the whole file again.
///
/// Internal to core: the network handler asks it before downloading. Only
/// Android answers; elsewhere there is no evidence and nothing changes.
abstract interface class CompletedDownloads {
  /// Evidence that the file at [targetPath] was downloaded from [url]'s source
  /// while the app was not running, or null when there is none.
  ///
  /// Otherwise the size of the whole file, as the download's final response
  /// stated it — null when it did not say. Reusing the file still needs its
  /// size to match; that is the caller's check.
  Future<({int? totalBytes})?> completedWhileAway(
    String url,
    String targetPath,
  );
}
