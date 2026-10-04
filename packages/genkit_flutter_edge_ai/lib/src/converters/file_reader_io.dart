import 'dart:io';
import 'dart:typed_data';

import 'package:genkit/plugin.dart';

/// Reads file bytes from the local filesystem.
///
/// Throws [GenkitException] with appropriate status codes on failure.
Future<Uint8List> readFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException catch (e) {
    final status = e.osError?.errorCode == 2 // ENOENT
        ? StatusCodes.NOT_FOUND
        : StatusCodes.INTERNAL;
    throw GenkitException(
      'Failed to read media file $path: $e',
      status: status,
    );
  }
}
