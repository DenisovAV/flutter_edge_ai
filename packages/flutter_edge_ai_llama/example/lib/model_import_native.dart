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

/// Removes only a regular file directly inside this app's Documents/Inbox.
/// External provider files and symlinks are never removed.
Future<void> removePickerInboxCopy(String path) async {
  final documents = await getApplicationDocumentsDirectory();
  final inbox = Directory('${documents.path}/Inbox');
  final source = File(path);
  if (!await inbox.exists() ||
      await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await source.parent.resolveSymbolicLinks() !=
          await inbox.resolveSymbolicLinks()) {
    return;
  }
  await source.delete();
}
