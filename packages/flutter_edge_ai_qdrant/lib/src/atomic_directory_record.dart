import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Failure to read or publish an immutable filesystem record.
class AtomicDirectoryRecordException implements Exception {
  const AtomicDirectoryRecordException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AtomicDirectoryRecordException: $message'
      '${cause == null ? '' : '\nCause: $cause'}';
}

/// Lock-free compare-and-set records shared by isolates and processes.
///
/// A record is a fixed non-empty directory containing `record.json`. Writers
/// build and flush a unique directory in the same parent, then rename it to
/// the fixed path. Same-filesystem directory rename is the publication point.
/// On POSIX, `rename(2)` cannot replace a non-empty destination directory; on
/// Windows, the directory move likewise fails when the destination exists.
/// Therefore exactly one concurrent publisher wins and no winner is
/// overwritten. A crash before rename leaves only an ignored unique temp
/// directory; after rename the complete record is visible.
class AtomicDirectoryRecord {
  const AtomicDirectoryRecord._();

  static const fileName = 'record.json';

  static Future<Map<String, dynamic>?> read({
    required String directoryPath,
    required String schema,
    required int version,
    required Set<String> expectedKeys,
  }) async {
    Object? cause;
    try {
      final type = await FileSystemEntity.type(
        directoryPath,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) {
        throw const FormatException('record path is not a directory');
      }
      final decoded = jsonDecode(
        await File(p.join(directoryPath, fileName)).readAsString(),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded.length != expectedKeys.length ||
          !decoded.keys.toSet().containsAll(expectedKeys) ||
          decoded['schema'] != schema ||
          decoded['version'] != version) {
        throw const FormatException('unexpected record JSON schema');
      }
      return decoded;
    } on FileSystemException catch (error) {
      cause = error;
    } on FormatException catch (error) {
      cause = error;
    }
    throw AtomicDirectoryRecordException(
      'Record at $directoryPath is corrupt or unreadable.',
      cause,
    );
  }

  static Future<void> publish({
    required String parentDirectory,
    required String finalDirectory,
    required String tempPrefix,
    required Map<String, Object> json,
  }) async {
    Directory? temporary;
    RandomAccessFile? output;
    try {
      final parent = Directory(parentDirectory);
      await parent.create(recursive: true);
      temporary = await parent.createTemp(tempPrefix);
      output = await File(
        p.join(temporary.path, fileName),
      ).open(mode: FileMode.writeOnly);
      await output.writeString(jsonEncode(json));
      await output.flush();
      await output.close();
      output = null;
      try {
        await temporary.rename(finalDirectory);
        temporary = null;
      } on FileSystemException {
        if (!await Directory(finalDirectory).exists()) rethrow;
      }
    } on FileSystemException catch (error) {
      throw AtomicDirectoryRecordException(
        'Failed to publish record at $finalDirectory.',
        error,
      );
    } finally {
      if (output != null) {
        try {
          await output.close();
        } on FileSystemException {
          // The original write/publish result is more useful to the caller.
        }
      }
      if (temporary != null) {
        try {
          if (await temporary.exists()) {
            await temporary.delete(recursive: true);
          }
        } on FileSystemException {
          // Both the existence check and delete are cleanup only. Neither may
          // replace the original publish result or error. A uniquely named
          // orphan is ignored by readers and future writers.
        }
      }
    }
  }
}
