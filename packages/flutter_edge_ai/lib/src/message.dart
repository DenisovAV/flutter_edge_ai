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

/// One message of a conversation: text, media, or a tool call or result.
///
/// Equality is structural: `==` and [hashCode] compare every field, and the
/// media by content, so two messages built from the same bytes in different
/// buffers are equal. [imageBytes] and [images] are compared as separate
/// fields. Both read every media byte on each call and cache nothing, so key
/// widgets by an id of your own or by `ObjectKey(message)`, not by
/// `ValueKey(message)`.
///
/// A message keeps what it is given: [copyWith] and the factories do not copy
/// the media bytes, and the constructor keeps the caller's [images] and
/// [toolCalls] lists. Do not change them while the message is a `Set` member
/// or a `Map` key.
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
  /// built from [text] alone; ignored on any other type. An engine reads them
  /// through `toolCallsOf` (`package:flutter_edge_ai/engine.dart`), which also
  /// parses [text] for a message saved with text alone. One model turn may be
  /// several consecutive toolCall messages (genai writes one per call, and a
  /// streamed text call is recorded as it completes); an engine that replays
  /// calls merges such a run into one turn.
  final List<FunctionCallResponse> toolCalls;

  /// The [FunctionCallResponse.id] a [MessageType.toolResponse] answers, or
  /// null when its call had none; ignored on any other type. Only
  /// `flutter_edge_ai_llama` reads it; the other engines pair a result with its
  /// call by [toolName], in order.
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
  /// an id. Only `flutter_edge_ai_llama` reads it; the other engines pair the
  /// result with its call by [toolName], in order.
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
  /// [calls] are the calls themselves, stored as a frozen copy. [text] is what
  /// text engines replay: the model's output as the engine returned it (for a
  /// LiteRT-LM call, its `tool_calls` objects without the text written before
  /// them), or the JSON a converter wrote. When it is null, it is
  /// `{"tool_calls":[{"id","name","arguments"}]}` built from [calls] (an `id`
  /// only for a call that has one), which the text formats also read back.
  /// Give at least one of the two.
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
      toolCalls: List.unmodifiable([
        for (final call in calls)
          FunctionCallResponse(
            name: call.name,
            args: Map<String, dynamic>.unmodifiable({
              for (final e in call.args.entries) e.key: _frozen(e.value),
            }),
            id: call.id,
          ),
      ]),
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
        _bytesEqual(other.imageBytes, imageBytes) &&
        _imagesEqual(other.images, images) &&
        _bytesEqual(other.audioBytes, audioBytes) &&
        other.type == type &&
        other.toolName == toolName &&
        _listEquals(other.toolCalls, toolCalls) &&
        other.toolCallId == toolCallId;
  }

  /// Media is hashed by content, as `==` compares it: the same bytes in
  /// different buffers, or in views at different offsets, hash alike (#823).
  /// See [Message] for the cost and for mutation.
  @override
  int get hashCode => Object.hash(
    text,
    isUser,
    _bytesHash(imageBytes),
    Object.hashAll(images.map(_bytesHash)),
    _bytesHash(audioBytes),
    type,
    toolName,
    Object.hashAll(toolCalls),
    toolCallId,
  );

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _imagesEqual(List<Uint8List> a, List<Uint8List> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_bytesEqual(a[i], b[i])) return false;
    }
    return true;
  }

  /// Every visible byte, read through the view, so a view at an offset hashes
  /// like a copy of the same bytes.
  static int _bytesHash(Uint8List? bytes) =>
      bytes == null ? null.hashCode : Object.hashAll(bytes);

  bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// A deep copy that cannot be changed: a history keeps the arguments the call
/// had, whatever the app later does to the map it received.
Object? _frozen(Object? value) => switch (value) {
  Map() => Map<Object?, Object?>.unmodifiable({
    for (final e in value.entries) e.key: _frozen(e.value),
  }),
  List() => List<Object?>.unmodifiable([for (final v in value) _frozen(v)]),
  _ => value,
};

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
