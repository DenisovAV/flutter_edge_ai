import 'package:flutter_gemma/core/model_response.dart';

/// Base class for all chat events
abstract class ChatEvent {}

/// Event emitted when a function call is detected
class FunctionCallEvent extends ChatEvent {
  final FunctionCallResponse call;

  FunctionCallEvent(this.call);

  @override
  String toString() => 'FunctionCallEvent(call: $call)';
}

/// Event emitted for each text token in streaming mode
class TextTokenEvent extends ChatEvent {
  final String token;

  TextTokenEvent(this.token);

  @override
  String toString() => 'TextTokenEvent(token: "$token")';
}

/// Event emitted when text response is complete (sync mode)
class TextCompleteEvent extends ChatEvent {
  final String fullText;

  TextCompleteEvent(this.fullText);

  @override
  String toString() => 'TextCompleteEvent(fullText: "$fullText")';
}

/// Event emitted when an error occurs
class ErrorEvent extends ChatEvent {
  final String error;

  ErrorEvent(this.error);

  @override
  String toString() => 'ErrorEvent(error: "$error")';
}
