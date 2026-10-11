/// Where a path an iOS app recorded in an earlier run is now, split out so the
/// mapping is a pure, unit-testable function.
///
/// iOS can give an app's data container a new directory — on an update, or a
/// restore from a backup — so an absolute path recorded before that names a
/// container that is gone. A file the app keeps inside its container is at
/// the same place in the current one.
library;

/// `…/Containers/Data/Application/<UUID>`, the data container of one app.
final RegExp _appContainer = RegExp(
  r'^.*/Containers/Data/Application/'
  r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
  r'(?=/|$)',
);

/// [recordedPath] moved into [currentContainer] when it lies inside an app
/// data container; [recordedPath] unchanged when it does not, or when
/// [currentContainer] is not an app data container itself.
String rebaseIntoAppContainer(String recordedPath, String currentContainer) {
  final current = _appContainer.matchAsPrefix(currentContainer);
  if (current == null || current.end != currentContainer.length) {
    return recordedPath;
  }
  final recorded = _appContainer.matchAsPrefix(recordedPath);
  if (recorded == null) return recordedPath;
  return currentContainer + recordedPath.substring(recorded.end);
}
