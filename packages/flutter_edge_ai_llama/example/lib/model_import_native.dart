import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Copies a picker-granted file into durable app-owned storage without reading
/// the entire model into Dart memory. Failed copies leave no partial model.
Future<String> importModel(String path) async {
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
    return (await partial.rename(target.path)).path;
  } catch (_) {
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
}
