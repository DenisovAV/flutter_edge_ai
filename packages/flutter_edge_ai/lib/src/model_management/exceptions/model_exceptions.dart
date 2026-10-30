part of '../model_specs.dart';

/// Base exception for model management operations
abstract class ModelException implements Exception {
  final String message;
  final dynamic cause;

  const ModelException(this.message, [this.cause]);

  @override
  String toString() =>
      'ModelException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when model download fails
class ModelDownloadException extends ModelException {
  final String? url;
  final String? filename;

  const ModelDownloadException(
    super.message, [
    super.cause,
    this.url,
    this.filename,
  ]);

  @override
  String toString() {
    final location = url ?? filename ?? 'unknown';
    return 'ModelDownloadException: $message (location: $location)${cause != null ? ' (caused by: $cause)' : ''}';
  }
}

/// An installed model file is not what it should be: smaller than a model
/// can be, or not the size the install asked for (`expectedSize` on the
/// builders, and the size of every `fromCatalog` install; not checked on the
/// web). A file that fails the size check is not made active, and is deleted
/// with its record so the next install downloads it again — unless an
/// active model reads it, or the delete fails, which the message says.
class ModelValidationException extends ModelException {
  /// The file checked.
  final String? filePath;

  /// Its size in bytes.
  final int? actualSize;

  /// The least size a model file can have, when that is what failed.
  final int? expectedMinSize;

  /// The exact size the install expected, when that is what failed.
  final int? expectedSize;

  const ModelValidationException(
    super.message, [
    super.cause,
    this.filePath,
    this.actualSize,
    this.expectedMinSize,
  ]) : expectedSize = null;

  /// [filePath] is not the file the install expected: [actualSize] bytes
  /// where [expectedSize] were expected, or no file at all.
  @internal
  const ModelValidationException.mismatch(
    String message, {
    this.filePath,
    this.actualSize,
    this.expectedSize,
    Object? cause,
  }) : expectedMinSize = null,
       super(message, cause);

  @override
  String toString() {
    var details = filePath ?? 'unknown file';
    if (actualSize != null && expectedMinSize != null) {
      details +=
          ' (size: $actualSize bytes, expected: >=$expectedMinSize bytes)';
    }
    if (actualSize != null && expectedSize != null) {
      details += ' (size: $actualSize bytes, expected: $expectedSize bytes)';
    }
    return 'ModelValidationException: $message ($details)${cause != null ? ' (caused by: $cause)' : ''}';
  }
}

/// Exception thrown when model storage operations fail
class ModelStorageException extends ModelException {
  final String? operation;

  const ModelStorageException(super.message, [super.cause, this.operation]);

  @override
  String toString() {
    final op = operation != null ? ' during $operation' : '';
    return 'ModelStorageException: $message$op${cause != null ? ' (caused by: $cause)' : ''}';
  }
}
