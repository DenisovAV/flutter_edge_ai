/// Runs [install], a catalog install. Core refuses one that would write over
/// the file the active model reads — a model installed earlier under the
/// catalog's name from another source (`/resolve/main/`, an older pin) — so
/// the file is never left wrong under a model in use. The example then
/// uninstalls that model with [uninstall] and installs again; an app could
/// as well ask the user first.
Future<T> installFromCatalogReplacingActive<T>(
  Future<T> Function() install, {
  required Future<void> Function() uninstall,
}) async {
  try {
    return await install();
  } on StateError catch (e) {
    if (!e.message.contains('over the file the active model')) rethrow;
    await uninstall();
    return install();
  }
}
