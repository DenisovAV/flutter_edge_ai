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

/// Exception thrown when model file validation fails
class ModelValidationException extends ModelException {
  final String? filePath;
  final int? actualSize;
  final int? expectedMinSize;

  const ModelValidationException(
    super.message, [
    super.cause,
    this.filePath,
    this.actualSize,
    this.expectedMinSize,
  ]);

  @override
  String toString() {
    var details = filePath ?? 'unknown file';
    if (actualSize != null && expectedMinSize != null) {
      details +=
          ' (size: $actualSize bytes, expected: >=$expectedMinSize bytes)';
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
