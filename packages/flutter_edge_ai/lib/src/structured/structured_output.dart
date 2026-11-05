import 'package:flutter_edge_ai/src/interface.dart' show TurnEnd;

import 'response_format.dart';

/// Base of the typed-response failures. Sealed: apps catch these, engines
/// never subclass them, and a fourth kind is a deliberate break.
sealed class StructuredOutputException implements Exception {
  const StructuredOutputException(this.message);
  final String message;
}

/// The format is refused: by this engine, platform or backend, or a schema
/// keyword at [schemaPath] the engine cannot enforce. Thrown by
/// `openSession`/`openChat` before the engine is called, and returned (not
/// thrown) by `InferenceModel.refusalFor`. On LiteRT-LM a schema the native
/// compiler rejects is first seen at the first send; it is thrown from that
/// turn, and the session is closed.
final class ResponseFormatUnsupportedException
    extends StructuredOutputException {
  const ResponseFormatUnsupportedException(super.message, {this.schemaPath});

  /// JSON Pointer of the refused keyword (`/properties/code/pattern`), or
  /// null when the whole format is refused.
  final String? schemaPath;

  @override
  String toString() =>
      'ResponseFormatUnsupportedException: $message'
      '${schemaPath == null ? '' : ' (at $schemaPath)'}';
}

/// The turn ended before the value was complete: [end] is
/// [TurnEnd.outputLimit], [TurnEnd.contextLimit], [TurnEnd.stopped] or
/// [TurnEnd.closed]. [partialText] is what was generated; in an
/// `InferenceChat` it is also in the chat's history, except for a turn
/// stopped before any text, which the chat takes back, its user message
/// included. A stop is incomplete even when [partialText] parses.
final class IncompleteStructuredOutputException
    extends StructuredOutputException {
  const IncompleteStructuredOutputException(
    super.message, {
    required this.end,
    required this.partialText,
  });
  final TurnEnd end;
  final String partialText;

  @override
  String toString() =>
      'IncompleteStructuredOutputException: $message (end: ${end.name})';
}

/// The turn ended normally but [text] is not a value of the format (not
/// JSON, trailing text, or a dialect keyword violated at [schemaPath]): an
/// engine accepted a format it did not enforce. An engine bug.
final class NonConformingStructuredOutputException
    extends StructuredOutputException {
  const NonConformingStructuredOutputException(
    super.message, {
    required this.text,
    this.schemaPath,
  });
  final String text;
  final String? schemaPath;

  @override
  String toString() =>
      'NonConformingStructuredOutputException: $message'
      '${schemaPath == null ? '' : ' (at $schemaPath)'}';
}

/// How a structured reply reaches the consumer.
enum StructuredDelivery {
  /// Chunks as they are decoded.
  incremental,

  /// One chunk when the reply is complete (built-in AI).
  buffered,
}

/// What a loaded model can enforce: engine, platform and the backend it was
/// loaded on. Read it on `InferenceModel.structuredOutputSupport`.
final class StructuredOutputSupport {
  /// Nothing: every format is refused with [reason].
  const StructuredOutputSupport.none(String this.reason)
    : keywords = const {},
      delivery = StructuredDelivery.incremental;

  /// The engine enforces [keywords] (a subset of [ResponseFormat.dialect];
  /// annotations need not be listed). Core checks the subset when it reads
  /// the engine's value and throws [StateError] naming the engine otherwise.
  const StructuredOutputSupport({
    required this.keywords,
    this.delivery = StructuredDelivery.incremental,
  }) : reason = null;

  /// Whether any format can be accepted: false for [StructuredOutputSupport.none].
  bool get isSupported => reason == null;

  /// Why every format is refused, or null when [isSupported].
  final String? reason;

  /// The schema keywords the engine enforces; empty for
  /// [StructuredOutputSupport.none].
  final Set<String> keywords;

  /// How a structured reply arrives.
  final StructuredDelivery delivery;

  @override
  String toString() => isSupported
      ? 'StructuredOutputSupport(keywords: $keywords, delivery: ${delivery.name})'
      : 'StructuredOutputSupport.none($reason)';
}
