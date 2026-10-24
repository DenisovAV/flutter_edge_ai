import 'package:llamadart/llamadart.dart' as llama;

/// Standard error categories consumed by core and Genkit, with the SDK cause.
Object runtimeError(Object error) => switch (error) {
  llama.LlamaUnsupportedException() => RuntimeUnsupportedError(error),
  llama.LlamaArgumentException() ||
  llama.LlamaModelFormatException() => RuntimeArgumentError(error),
  llama.LlamaException() => RuntimeStateError(error),
  _ => error,
};

// These implementations are internal; callers catch standard Dart errors.
/// Unsupported runtime operation, retaining its original cause.
class RuntimeUnsupportedError extends UnsupportedError {
  /// Wraps the SDK error without replacing its stack.
  RuntimeUnsupportedError(this.cause) : super(cause.toString());

  /// Original SDK exception.
  final Object cause;
}

/// Invalid SDK input or model format, retaining its original cause.
class RuntimeArgumentError extends ArgumentError {
  /// Wraps the SDK error without replacing its stack.
  RuntimeArgumentError(this.cause) : super.value(cause, null, cause.toString());

  /// Original SDK exception.
  final Object cause;
}

/// SDK runtime operation failure, retaining its original cause.
class RuntimeStateError extends StateError {
  /// Wraps the SDK error without replacing its stack.
  RuntimeStateError(this.cause) : super(cause.toString());

  /// Original SDK exception.
  final Object cause;
}
