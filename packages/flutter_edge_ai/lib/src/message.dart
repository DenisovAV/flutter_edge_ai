import 'dart:convert';
import 'dart:typed_data';

import 'model_response.dart';

enum MessageType {
  text,
  toolResponse,
  toolCall,
  systemInfo, // For function call indicators
  thinking, // For thinking mode content
}

class Message {
  const Message({
    required this.text,
    this.isUser = false,
    this.imageBytes,
    this.images = const [],
    this.audioBytes,
    this.type = MessageType.text,
    this.toolName,
    this.toolCalls = const [],
    this.toolCallId,
  });

  final String text;
  final bool isUser;
  final Uint8List? imageBytes;
  final List<Uint8List> images;
  final Uint8List? audioBytes;
  final MessageType type;
  final String? toolName;

  /// The calls a [MessageType.toolCall] message carries, or empty when it was
  /// built from [text] alone. An engine reads them through `toolCallsOf`
  /// (`package:flutter_edge_ai/engine.dart`), which also parses [text] for a
  /// message saved before these fields existed.
  final List<FunctionCallResponse> toolCalls;

  /// The [FunctionCallResponse.id] a [MessageType.toolResponse] answers, or
  /// null when the result is paired with its call by [toolName].
  final String? toolCallId;

  bool get hasImage => imageBytes != null || images.isNotEmpty;
  bool get hasAudio => audioBytes != null;

  Message copyWith({
    String? text,
    bool? isUser,
    Uint8List? imageBytes,
    List<Uint8List>? images,
    Uint8List? audioBytes,
    MessageType? type,
    String? toolName,
    List<FunctionCallResponse>? toolCalls,
    String? toolCallId,
  }) {
    return Message(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      imageBytes: imageBytes ?? this.imageBytes,
      images: images ?? this.images,
      audioBytes: audioBytes ?? this.audioBytes,
      type: type ?? this.type,
      toolName: toolName ?? this.toolName,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
    );
  }

  factory Message.text({required String text, bool isUser = false}) {
    return Message(text: text, isUser: isUser);
  }

  factory Message.withImage({
    required String text,
    required Uint8List imageBytes,
    bool isUser = false,
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes,
      images: [imageBytes],
      isUser: isUser,
    );
  }

  factory Message.withImages({
    required String text,
    required List<Uint8List> imageBytes,
    bool isUser = false,
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes.isNotEmpty ? imageBytes.first : null,
      images: List<Uint8List>.from(imageBytes),
      isUser: isUser,
    );
  }

  factory Message.imageOnly({
    required Uint8List imageBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes,
      images: [imageBytes],
      isUser: isUser,
    );
  }

  factory Message.imagesOnly({
    required List<Uint8List> imageBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes.isNotEmpty ? imageBytes.first : null,
      images: List<Uint8List>.from(imageBytes),
      isUser: isUser,
    );
  }

  factory Message.withAudio({
    required String text,
    required Uint8List audioBytes,
    bool isUser = false,
  }) {
    return Message(text: text, audioBytes: audioBytes, isUser: isUser);
  }

  factory Message.audioOnly({
    required Uint8List audioBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(text: text, audioBytes: audioBytes, isUser: isUser);
  }

  /// A tool result. [toolCallId] names the call it answers when that call had
  /// an id; without one, engines pair the result with its call by [toolName].
  factory Message.toolResponse({
    required String toolName,
    required Map<String, dynamic> response,
    String? toolCallId,
  }) {
    // Tool responses are sent from the user's side.
    return Message(
      text: jsonEncode(response),
      toolName: toolName,
      type: MessageType.toolResponse,
      isUser: true,
      toolCallId: toolCallId,
    );
  }

  /// The model's tool call(s) in a history.
  ///
  /// [calls] are the calls themselves. [text] is what the model wrote, kept
  /// verbatim for engines that replay the model's own words; when it is null,
  /// it is `{"tool_calls":[{"id","name","arguments"}]}` built from [calls]
  /// (an `id` only for a call that has one). Give at least one of the two.
  factory Message.toolCall({
    String? text,
    List<FunctionCallResponse> calls = const [],
  }) {
    if (text == null && calls.isEmpty) {
      throw ArgumentError('Message.toolCall needs text or at least one call.');
    }
    // Tool calls are from the model.
    return Message(
      text: text ?? _toolCallsJson(calls),
      type: MessageType.toolCall,
      isUser: false,
      toolCalls: List.unmodifiable(calls),
    );
  }

  factory Message.systemInfo({required String text, String? icon}) {
    return Message(
      text: text,
      type: MessageType.systemInfo,
      isUser: false,
      toolName: icon, // Reuse toolName field for icon
    );
  }

  factory Message.thinking({required String text}) {
    return Message(text: text, type: MessageType.thinking, isUser: false);
  }

  @override
  String toString() {
    final calls = toolCalls.isEmpty ? '' : ', toolCalls: $toolCalls';
    final callId = toolCallId == null ? '' : ', toolCallId: $toolCallId';
    return 'Message(text: $text, isUser: $isUser, imageCount: ${images.isNotEmpty ? images.length : (imageBytes == null ? 0 : 1)}, hasAudio: $hasAudio, type: $type, toolName: $toolName$calls$callId)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Message &&
        other.text == text &&
        other.isUser == isUser &&
        _listEquals(other.imageBytes, imageBytes) &&
        _listEquals(other.images, images) &&
        _listEquals(other.audioBytes, audioBytes) &&
        other.type == type &&
        other.toolName == toolName &&
        _listEquals(other.toolCalls, toolCalls) &&
        other.toolCallId == toolCallId;
  }

  @override
  int get hashCode =>
      text.hashCode ^
      isUser.hashCode ^
      imageBytes.hashCode ^
      Object.hashAll(images) ^
      audioBytes.hashCode ^
      type.hashCode ^
      toolName.hashCode ^
      Object.hashAll(toolCalls) ^
      toolCallId.hashCode;

  bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

String _toolCallsJson(List<FunctionCallResponse> calls) => jsonEncode({
  'tool_calls': [
    for (final call in calls)
      {
        if (call.id != null) 'id': call.id,
        'name': call.name,
        'arguments': call.args,
      },
  ],
});
