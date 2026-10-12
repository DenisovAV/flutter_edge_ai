// How a failure crosses from an embedding host to the facade (R5 §4.7).
//
// The isolate host never sends exception objects — their `cause` may not be
// sendable — so it encodes them as an [EmbeddingFailure] and the main side
// rebuilds the typed exception. The inline host runs the same encoding, so a
// pass that throws gets the same exception type and message on web as on
// native. Pure Dart.

import 'embedding_exceptions.dart';

/// The four kinds of failure a host reports.
enum EmbeddingFailureKind {
  /// The request never ran: the model closed first.
  closed,

  /// The input exceeded the model's limit.
  tooLong,

  /// The engine failed while embedding.
  engine,

  /// The engine failed to load or refused the configuration.
  load,
}

/// A sendable description of an embedding failure.
final class EmbeddingFailure {
  const EmbeddingFailure({
    required this.kind,
    required this.message,
    required this.engine,
    this.nativeCode,
    this.maxInputTokens,
    this.actualTokens,
    this.stack,
  });

  /// The host's own "this request never ran": the model closed before the
  /// request started. The only way to the `closed` kind — a pass that throws
  /// `EmbedderClosedException` ran, and is reported as an engine failure.
  const EmbeddingFailure.closedBeforeRun({required this.engine})
    : kind = EmbeddingFailureKind.closed,
      message = 'The embedding model was closed before this request ran.',
      nativeCode = null,
      maxInputTokens = null,
      actualTokens = null,
      stack = null;

  /// Encodes [error] thrown by an engine's pass.
  ///
  /// While [loading], every error is a `load` failure (an engine's own code
  /// and name kept). While embedding: `EmbeddingInputTooLongException` stays
  /// `tooLong` with its counts; everything else — `EmbeddingEngineException`,
  /// and also an `EmbedderClosedException` or `EmbeddingLoadException` a pass
  /// throws mid-request (the request did run), any other
  /// `EmbeddingException` subtype, and any non-embedding error — is an
  /// `engine` failure. The `closed` kind is the host's alone
  /// ([EmbeddingFailure.closedBeforeRun]).
  ///
  /// An exception's `cause` may not be sendable, so with [causeInMessage]
  /// (the isolate host) its text is appended to the message — `<message>
  /// (cause: <cause>)`, the line `EmbeddingException.toString` prints anyway.
  /// The inline host passes false and attaches the cause object itself
  /// (`toException(cause:)`), so both print the same. An `EmbeddingException`
  /// subtype that has no kind of its own is named in the message.
  factory EmbeddingFailure.fromError(
    Object error, {
    required String engine,
    bool loading = false,
    bool causeInMessage = true,
    StackTrace? stack,
  }) {
    final stackText = stack?.toString();
    String described(EmbeddingException e) {
      final cause = e.cause;
      return causeInMessage && cause != null
          ? '${e.message} (cause: $cause)'
          : e.message;
    }

    if (!loading && error is EmbeddingInputTooLongException) {
      return EmbeddingFailure(
        kind: EmbeddingFailureKind.tooLong,
        message: described(error),
        engine: engine,
        maxInputTokens: error.maxInputTokens,
        actualTokens: error.actualTokens,
        stack: stackText,
      );
    }
    final kind = loading
        ? EmbeddingFailureKind.load
        : EmbeddingFailureKind.engine;
    return switch (error) {
      EmbeddingEngineException(engine: final reported, :final nativeCode) =>
        EmbeddingFailure(
          kind: kind,
          message: described(error),
          engine: reported,
          nativeCode: nativeCode,
          stack: stackText,
        ),
      EmbeddingLoadException(engine: final reported, :final nativeCode) =>
        EmbeddingFailure(
          kind: kind,
          message: described(error),
          engine: reported,
          nativeCode: nativeCode,
          stack: stackText,
        ),
      EmbeddingException() => EmbeddingFailure(
        kind: kind,
        message: '${error.runtimeType}: ${described(error)}',
        engine: engine,
        stack: stackText,
      ),
      _ => EmbeddingFailure(
        kind: kind,
        message: '$error',
        engine: engine,
        stack: stackText,
      ),
    };
  }

  final EmbeddingFailureKind kind;
  final String message;
  final String engine;
  final int? nativeCode;
  final int? maxInputTokens;
  final int? actualTokens;

  /// The pass's stack where it threw, as text (a `StackTrace` is not
  /// sendable). The host completes the request with it, so the caller sees
  /// where the engine failed, not where the reply arrived.
  final String? stack;

  /// [stack] as a `StackTrace`, or null.
  StackTrace? get stackTrace {
    final text = stack;
    return text == null ? null : StackTrace.fromString(text);
  }

  /// The typed exception this failure stands for. [cause] is attached where
  /// the original error is still at hand (the inline host); across the
  /// isolate boundary it is not.
  EmbeddingException toException({Object? cause}) => switch (kind) {
    EmbeddingFailureKind.closed => EmbedderClosedException(message),
    EmbeddingFailureKind.tooLong => EmbeddingInputTooLongException(
      message,
      // Never null for this kind: fromError copies it from the exception.
      maxInputTokens: maxInputTokens ?? 0,
      actualTokens: actualTokens,
    ),
    EmbeddingFailureKind.engine => EmbeddingEngineException(
      message,
      engine: engine,
      nativeCode: nativeCode,
      cause: cause,
    ),
    EmbeddingFailureKind.load => EmbeddingLoadException(
      message,
      engine: engine,
      nativeCode: nativeCode,
      cause: cause,
    ),
  };
}
