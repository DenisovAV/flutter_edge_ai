import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Copies a picker-granted file into durable app-owned storage without reading
/// the entire model into Dart memory. Failed copies leave no partial model.
Future<String> importModel(
  String path, {
  bool cleanupPickerInbox = false,
}) async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/gguf_lab');
  await directory.create(recursive: true);
  final filename = File(path).uri.pathSegments.last;
  if (!filename.toLowerCase().endsWith('.gguf')) {
    throw ArgumentError('Choose a GGUF model.');
  }
  final target = File(
    '${directory.path}/${DateTime.now().microsecondsSinceEpoch}_$filename',
  );
  // iOS's import picker already made an app-owned temporary copy. Move it
  // atomically into durable storage instead of allocating a second model copy.
  if (cleanupPickerInbox && await _isPickerInboxCopy(path)) {
    try {
      return (await File(path).rename(target.path)).path;
    } on FileSystemException {
      // Different volume/provider: retain the checked copy-and-cleanup path.
    }
  }
  final partial = File('${target.path}.partial');
  try {
    await File(path).copy(partial.path);
    final imported = (await partial.rename(target.path)).path;
    if (cleanupPickerInbox) {
      try {
        await removePickerInboxCopy(path);
      } on FileSystemException {
        // Import already succeeded; keep the durable model if cleanup fails.
      }
    }
    return imported;
  } catch (_) {
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
}

/// Removes only copies owned by this example, after a replacement loads.
Future<void> pruneImportedModels(String keepPath) async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/gguf_lab');
  final kept = File(keepPath).absolute.path;
  if (!kept.startsWith('${directory.absolute.path}${Platform.pathSeparator}') ||
      !await directory.exists()) {
    return;
  }
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File &&
        entry.absolute.path != kept &&
        entry.path.toLowerCase().endsWith('.gguf')) {
      await entry.delete();
    }
  }
}

/// Removes only a regular picker copy in this app's temporary or Documents Inbox.
/// External provider files and symlinks are never removed.
Future<void> removePickerInboxCopy(String path) async {
  if (await _isPickerInboxCopy(path)) {
    await File(path).delete();
  }
}

Future<bool> _isPickerInboxCopy(String path) async {
  final source = File(path);
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return false;
  }
  final parent = await source.parent.resolveSymbolicLinks();
  final documents = await getApplicationDocumentsDirectory();
  final inbox = Directory('${documents.path}/Inbox');
  if (await FileSystemEntity.type(inbox.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      parent == await inbox.resolveSymbolicLinks()) {
    return true;
  }
  // file_selector_ios uses UIDocumentPickerModeImport, which produces
  // tmp/<bundle-id>-Inbox/<file>. Only a direct child of our own tmp is owned.
  final temporary = await getTemporaryDirectory();
  final directory = source.parent;
  return directory.uri.pathSegments
          .where((p) => p.isNotEmpty)
          .last
          .endsWith('-Inbox') &&
      await directory.parent.resolveSymbolicLinks() ==
          await temporary.resolveSymbolicLinks() &&
      await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.directory;
}
